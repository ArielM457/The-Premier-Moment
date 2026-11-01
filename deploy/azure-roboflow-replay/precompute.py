#!/usr/bin/env python3
"""Procesa vídeos fijos contra Roboflow y crea un catálogo reproducible."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
from hashlib import sha256
from http.client import HTTPException
import json
import mimetypes
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from uuid import uuid4

from fingerprint import attach_foreground, encode_fingerprint, foreground_frame

MODELS = {"player", "ball", "pitch"}
# Un lote son cientos de peticiones: un corte aislado de la red o de la
# ingress de Azure no debe obligar a repetir todos los vídeos.
PREDICT_ATTEMPTS = 5
RETRYABLE_STATUS = {429, 500, 502, 503, 504}


def file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_video(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("Use VIDEO_ID=/ruta/video.mp4")
    video_id, raw_path = value.split("=", 1)
    path = Path(raw_path).expanduser().resolve()
    if not video_id or not path.is_file():
        raise argparse.ArgumentTypeError(f"Vídeo inválido: {value}")
    return video_id, path


def multipart_image(content: bytes, filename: str) -> tuple[bytes, str]:
    boundary = f"prime-{uuid4().hex}"
    media_type = mimetypes.guess_type(filename)[0] or "image/jpeg"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="image"; filename="{filename}"\r\n'
        f"Content-Type: {media_type}\r\n\r\n"
    ).encode() + content + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def predict(endpoint: str, api_key: str, frame: Path, timeout: float, sleep=time.sleep) -> dict:
    """Reintenta errores de red y respuestas 429/5xx; los demás errores fallan enseguida."""
    for attempt in range(1, PREDICT_ATTEMPTS + 1):
        try:
            return predict_once(endpoint, api_key, frame, timeout)
        except HTTPError as error:
            if error.code not in RETRYABLE_STATUS or attempt == PREDICT_ATTEMPTS:
                raise
            reason = f"HTTP {error.code}"
        except (OSError, HTTPException) as error:
            if attempt == PREDICT_ATTEMPTS:
                raise
            reason = f"{type(error).__name__}: {error}"
        delay = 2 ** attempt
        print(f"{frame.name}: {reason}; reintento {attempt}/{PREDICT_ATTEMPTS - 1} en {delay} s", flush=True)
        sleep(delay)
    raise AssertionError("predict agotó los intentos sin devolver ni fallar")


def predict_once(endpoint: str, api_key: str, frame: Path, timeout: float) -> dict:
    content = frame.read_bytes()
    body, content_type = multipart_image(content, frame.name)
    request = Request(
        f"{endpoint.rstrip('/')}/v1/predict?{urlencode({'models': 'all'})}",
        data=body,
        headers={"Content-Type": content_type, "X-API-Key": api_key},
        method="POST",
    )
    with urlopen(request, timeout=timeout) as response:  # noqa: S310 - endpoint explícito del operador
        payload = json.loads(response.read())
    results = payload.get("results")
    returned = {item.get("model") for item in results or [] if isinstance(item, dict)}
    if returned != MODELS:
        raise RuntimeError(f"Respuesta incompleta para {frame}: {sorted(returned)}")
    return payload


def extract_frames(video: Path, directory: Path, interval_ms: int) -> list[Path]:
    fps = 1000 / interval_ms
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(video),
            "-vf", f"fps={fps:.12g}", "-q:v", "2", str(directory / "frame-%06d.jpg"),
        ],
        check=True,
    )
    frames = sorted(directory.glob("frame-*.jpg"))
    if not frames:
        raise RuntimeError(f"ffmpeg no extrajo fotogramas de {video}")
    return frames


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", action="append", required=True, type=parse_video)
    parser.add_argument("--endpoint", default=os.getenv("ROBOFLOW_SUITE_ENDPOINT"))
    parser.add_argument("--api-key", default=os.getenv("ROBOFLOW_SUITE_API_KEY"))
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "data" / "catalog.json")
    parser.add_argument("--interval-ms", type=int, default=1000)
    parser.add_argument("--timeout-seconds", type=float, default=120)
    parser.add_argument("--expected-videos", type=int, default=3)
    args = parser.parse_args()
    if not args.endpoint or not args.api_key:
        parser.error("Defina --endpoint/--api-key o ROBOFLOW_SUITE_ENDPOINT/ROBOFLOW_SUITE_API_KEY")
    if args.interval_ms <= 0:
        parser.error("--interval-ms debe ser positivo")
    if len(args.video) != args.expected_videos:
        parser.error(f"Se esperaban {args.expected_videos} vídeos y se recibieron {len(args.video)}")
    ids = [video_id for video_id, _ in args.video]
    if len(set(ids)) != len(ids):
        parser.error("Cada VIDEO_ID debe ser único")
    if shutil.which("ffmpeg") is None:
        parser.error("Falta ffmpeg")

    records = []
    videos = []
    foreground = []
    with tempfile.TemporaryDirectory(prefix="prime-roboflow-") as raw_temp:
        temp = Path(raw_temp)
        for video_id, video_path in args.video:
            video_hash = file_sha256(video_path)
            frame_dir = temp / video_id
            frame_dir.mkdir()
            frames = extract_frames(video_path, frame_dir, args.interval_ms)
            videos.append({
                "video_id": video_id,
                "filename": video_path.name,
                "sha256": video_hash,
                "frames": len(frames),
            })
            for index, frame in enumerate(frames):
                content = frame.read_bytes()
                response = predict(args.endpoint, args.api_key, frame, args.timeout_seconds)
                records.append({
                    "video_id": video_id,
                    "video_sha256": video_hash,
                    "video_time_ms": index * args.interval_ms,
                    "frame_sha256": sha256(content).hexdigest(),
                    "fingerprint_rgb32x18_b64": encode_fingerprint(content),
                    "response": response,
                })
                foreground.append(foreground_frame(content))
                print(f"{video_id}: {index + 1}/{len(frames)}", flush=True)

    catalog = {
        "schema_version": "roboflow-precomputed-v1",
        "generated_at": datetime.now(UTC).isoformat(),
        "interval_ms": args.interval_ms,
        "source": "roboflow-suite-gpu",
        "videos": videos,
        "records": records,
    }
    attach_foreground(catalog, foreground)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".tmp")
    temporary.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    temporary.replace(args.output)
    print(f"Catálogo creado: {args.output.resolve()}")
    print(f"Vídeos: {len(videos)}; registros: {len(records)}")


if __name__ == "__main__":
    main()
