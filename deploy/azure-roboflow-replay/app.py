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
import numpy as np

from fingerprint import (
    FOREGROUND_BLUR,
    FOREGROUND_HEIGHT,
    FOREGROUND_WIDTH,
    decode_fingerprint,
    decode_foreground,
    fingerprint_array,
    foreground_frame,
    foreground_scores,
    visual_scores,
)

MODELS = ("player", "ball", "pitch")
CATALOG_PATH = Path(os.getenv("MENTOX_PRECOMPUTED_CATALOG", "/app/data/catalog.json"))
API_KEY = os.getenv("MENTOX_MODEL_API_KEY", "")
MAX_IMAGE_BYTES = int(os.getenv("MENTOX_MAX_IMAGE_BYTES", str(15 * 1024 * 1024)))
MAX_VISUAL_SCORE = float(os.getenv("MENTOX_REPLAY_MAX_VISUAL_SCORE", "0.10"))
MIN_SCORE_MARGIN = float(os.getenv("MENTOX_REPLAY_MIN_SCORE_MARGIN", "0.002"))
# Calibrados con 120 capturas JPEG 0.82 tomadas en instantes al azar de los
# tres vídeos MESSI clean: la peor coincidencia correcta fue 0.000037 y el
# primer candidato de otro vídeo u otro momento quedó al menos 1.22 veces lejos.
MAX_FOREGROUND_SCORE = float(os.getenv("MENTOX_REPLAY_MAX_FOREGROUND_SCORE", "0.0001"))
MIN_FOREGROUND_RATIO = float(os.getenv("MENTOX_REPLAY_MIN_FOREGROUND_RATIO", "1.1"))
# Registros del mismo vídeo a esta distancia describen el mismo momento.
NEIGHBOR_WINDOW_MS = 2_000


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


def load_foreground(payload: dict[str, Any], records: list[dict[str, Any]]) -> tuple[np.ndarray, np.ndarray] | None:
    """Fondo y primeros planos con el fondo ya restado; None si el catálogo no los trae."""
    settings = payload.get("foreground")
    if settings is None:
        return None
    if (settings.get("width"), settings.get("height"), settings.get("blur")) != (
        FOREGROUND_WIDTH, FOREGROUND_HEIGHT, FOREGROUND_BLUR,
    ):
        raise RuntimeError("La huella de primer plano del catálogo usa otros parámetros")
    if any("foreground_rgb_b64" not in record for record in records):
        raise RuntimeError("Un registro no contiene su huella de primer plano")
    background = decode_foreground(settings["background_rgb_b64"]).astype(np.float32)
    frames = np.stack([decode_foreground(record["foreground_rgb_b64"]) for record in records])
    references = ((frames.astype(np.float32) - background) / 255.0).reshape(len(records), -1)
    return background, references


@asynccontextmanager
async def lifespan(app: FastAPI):
    if not API_KEY:
        raise RuntimeError("MENTOX_MODEL_API_KEY es obligatoria")
    catalog, records, references = load_catalog(CATALOG_PATH)
    app.state.catalog = catalog
    app.state.records = records
    app.state.references = references
    app.state.foreground = load_foreground(catalog, records)
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
        "visual_match": "foreground" if app.state.foreground is not None else "thumbnail",
    }


def same_results(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return left.get("results") == right.get("results")


def match_foreground(content: bytes) -> tuple[dict[str, Any], float]:
    try:
        query = foreground_frame(content)
    except Exception as error:
        raise HTTPException(status_code=422, detail="El archivo no es una imagen válida") from error
    background, references = app.state.foreground
    scores = foreground_scores(query, background, references)
    order = scores.argsort()
    best_index = int(order[0])
    best_score = float(scores[best_index])
    if best_score > MAX_FOREGROUND_SCORE:
        raise HTTPException(
            status_code=422,
            detail=f"El fotograma no pertenece al catálogo precalculado (score={best_score:.6f})",
        )
    best = app.state.records[best_index]
    # Una captura entre dos segundos se parece a ambos: eso no es ambigüedad.
    # Sí lo es otro vídeo u otro momento con un puntaje casi igual.
    limit = best_score * MIN_FOREGROUND_RATIO + 1e-12
    for index in order[1:]:
        if float(scores[index]) > limit:
            break
        candidate = app.state.records[int(index)]
        if (candidate["video_id"] == best["video_id"]
                and abs(candidate["video_time_ms"] - best["video_time_ms"]) <= NEIGHBOR_WINDOW_MS):
            continue
        if not same_results(best["response"], candidate["response"]):
            raise HTTPException(
                status_code=409,
                detail="El fotograma coincide de forma ambigua con más de un registro",
            )
    return best, best_score


def match_record(content: bytes) -> tuple[dict[str, Any], float]:
    if app.state.foreground is not None:
        return match_foreground(content)
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
