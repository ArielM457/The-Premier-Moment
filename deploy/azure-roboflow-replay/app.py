"""API compatible que reproduce resultados Roboflow precalculados."""

from __future__ import annotations

from contextlib import asynccontextmanager
from hmac import compare_digest
import json
import os
from pathlib import Path
from time import perf_counter
from typing import Annotated, Any

from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, UploadFile

from fingerprint import decode_fingerprint, fingerprint_array, visual_scores

MODELS = ("player", "ball", "pitch")
CATALOG_PATH = Path(os.getenv("MENTOX_PRECOMPUTED_CATALOG", "/app/data/catalog.json"))
API_KEY = os.getenv("MENTOX_MODEL_API_KEY", "")
MAX_IMAGE_BYTES = int(os.getenv("MENTOX_MAX_IMAGE_BYTES", str(15 * 1024 * 1024)))
MAX_VISUAL_SCORE = float(os.getenv("MENTOX_REPLAY_MAX_VISUAL_SCORE", "0.10"))
MIN_SCORE_MARGIN = float(os.getenv("MENTOX_REPLAY_MIN_SCORE_MARGIN", "0.002"))


def require_api_key(
    supplied: Annotated[str | None, Header(alias="X-API-Key")] = None,
) -> None:
    if not API_KEY:
        raise HTTPException(status_code=503, detail="MENTOX_MODEL_API_KEY no está configurada")
    if supplied is None or not compare_digest(supplied, API_KEY):
        raise HTTPException(status_code=401, detail="Credencial de inferencia inválida")


def load_catalog(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]], list[Any]]:
    if not path.is_file():
        raise RuntimeError(f"No existe el catálogo precalculado: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != "roboflow-precomputed-v1":
        raise RuntimeError("El catálogo usa una versión incompatible")
    records = payload.get("records")
    if not isinstance(records, list) or not records:
        raise RuntimeError("El catálogo no contiene predicciones")
    references = []
    for record in records:
        results = record.get("response", {}).get("results")
        returned = {item.get("model") for item in results or [] if isinstance(item, dict)}
        if returned != set(MODELS):
            raise RuntimeError("Un registro no contiene player, ball y pitch")
        references.append(decode_fingerprint(record["fingerprint_rgb32x18_b64"]))
    return payload, records, references


@asynccontextmanager
async def lifespan(app: FastAPI):
    if not API_KEY:
        raise RuntimeError("MENTOX_MODEL_API_KEY es obligatoria")
    catalog, records, references = load_catalog(CATALOG_PATH)
    app.state.catalog = catalog
    app.state.records = records
    app.state.references = references
    yield


app = FastAPI(
    title="The Prime Moment Roboflow Precomputed Replay",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health/live")
def health_live() -> dict[str, str]:
    return {"status": "alive"}


@app.get("/health/ready")
def health_ready() -> dict[str, Any]:
    records = getattr(app.state, "records", None)
    if not records:
        raise HTTPException(status_code=503, detail="El catálogo todavía no está listo")
    return {
        "status": "ready",
        "models": list(MODELS),
        "device": "precomputed-cpu",
        "execution_mode": "precomputed_video_lookup",
        "videos": len(app.state.catalog.get("videos", [])),
        "records": len(records),
    }


def same_results(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return left.get("results") == right.get("results")


def match_record(content: bytes) -> tuple[dict[str, Any], float]:
    try:
        query = fingerprint_array(content)
    except Exception as error:
        raise HTTPException(status_code=422, detail="El archivo no es una imagen válida") from error
    scores = visual_scores(query, app.state.references)
    order = scores.argsort()
    best_index = int(order[0])
    best_score = float(scores[best_index])
    if best_score > MAX_VISUAL_SCORE:
        raise HTTPException(
            status_code=422,
            detail=f"El fotograma no pertenece al catálogo precalculado (score={best_score:.6f})",
        )
    if len(order) > 1:
        second_index = int(order[1])
        margin = float(scores[second_index] - best_score)
        if margin < MIN_SCORE_MARGIN and not same_results(
            app.state.records[best_index]["response"],
            app.state.records[second_index]["response"],
        ):
            raise HTTPException(
                status_code=409,
                detail="El fotograma coincide de forma ambigua con más de un registro",
            )
    return app.state.records[best_index], best_score


@app.post("/v1/predict", dependencies=[Depends(require_api_key)])
async def predict_image(
    image: Annotated[UploadFile, File()],
    models: Annotated[str, Query(description="player,ball,pitch o all")] = "all",
) -> dict[str, Any]:
    if image.content_type not in {"image/jpeg", "image/png", "image/webp"}:
        raise HTTPException(status_code=415, detail="Use JPEG, PNG o WebP")
    selected = list(MODELS) if models == "all" else [
        item.strip() for item in models.split(",") if item.strip()
    ]
    invalid = sorted(set(selected) - set(MODELS))
    if not selected or invalid:
        raise HTTPException(status_code=422, detail=f"Modelos inválidos: {invalid or selected}")
    content = await image.read()
    if not content:
        raise HTTPException(status_code=422, detail="La imagen está vacía")
    if len(content) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="La imagen supera el límite permitido")

    started = perf_counter()
    record, score = match_record(content)
    original = record["response"]
    results = [item for item in original["results"] if item.get("model") in selected]
    return {
        "device": "precomputed-cache",
        "image": original.get("image", record.get("image", {})),
        "inference_ms": round((perf_counter() - started) * 1000, 3),
        "results": results,
        "execution_mode": "precomputed_video_lookup",
        "source_video_id": record["video_id"],
        "source_video_sha256": record["video_sha256"],
        "source_video_time_ms": record["video_time_ms"],
        "visual_match_score": round(score, 8),
    }
