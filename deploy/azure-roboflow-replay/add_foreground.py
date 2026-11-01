#!/usr/bin/env python3
"""Agrega la huella de primer plano a un catálogo existente sin volver a usar la GPU."""

from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path
import tempfile

from fingerprint import attach_foreground, foreground_frame
from precompute import extract_frames, file_sha256, parse_video


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--video", action="append", required=True, type=parse_video)
    args = parser.parse_args()

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    interval_ms = catalog["interval_ms"]
    expected = {video["video_id"]: video for video in catalog["videos"]}
    paths = dict(args.video)
    if set(paths) != set(expected):
        parser.error(f"Se esperaban los vídeos {sorted(expected)} y se recibieron {sorted(paths)}")

    frames: dict[str, list[bytes]] = {}
    with tempfile.TemporaryDirectory(prefix="prime-foreground-") as raw_temp:
        for video_id, path in paths.items():
            if file_sha256(path) != expected[video_id]["sha256"]:
                raise SystemExit(f"{video_id}: el MP4 no es el que se procesó con Roboflow")
            folder = Path(raw_temp) / video_id
            folder.mkdir()
            frames[video_id] = [frame.read_bytes() for frame in extract_frames(path, folder, interval_ms)]

    foreground = []
    for record in catalog["records"]:
        # La extracción debe dar los mismos bytes que vio Roboflow; si no, la huella no sirve.
        content = frames[record["video_id"]][record["video_time_ms"] // interval_ms]
        if sha256(content).hexdigest() != record["frame_sha256"]:
            raise SystemExit(f"{record['video_id']} {record['video_time_ms']} ms: el fotograma no coincide")
        foreground.append(foreground_frame(content))

    attach_foreground(catalog, foreground)
    temporary = args.catalog.with_suffix(".tmp")
    temporary.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    temporary.replace(args.catalog)
    print(f"Huella de primer plano agregada a {len(foreground)} registros: {args.catalog.resolve()}")


if __name__ == "__main__":
    main()
