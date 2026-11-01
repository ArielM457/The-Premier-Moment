#!/usr/bin/env python3
"""Comprueba el paquete MESSI clean antes de borrar el job o crear el catálogo."""

import argparse
from hashlib import sha256
import json
from pathlib import Path


def verify(root: Path) -> None:
    required = {"match.mp4", "events.jsonl", "tracking.jsonl", "metadata.jsonl"}
    for index in range(1, 4):
        match_id = f"messi-{index:03d}"
        directory = root / match_id
        manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
        if manifest.get("match_id") != match_id or manifest.get("render_mode") != "clean":
            raise ValueError(f"{match_id}: manifiesto incompatible; se requiere render_mode=clean")
        artifacts = manifest["artifacts"]
        if {item["name"] for item in artifacts} != required or len(artifacts) != 4:
            raise ValueError(f"{match_id}: se requieren los cuatro artefactos esperados")
        for artifact in artifacts:
            path = directory / artifact["name"]
            digest = sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            if path.stat().st_size != artifact["bytes"] or digest.hexdigest() != artifact["sha256"]:
                raise ValueError(f"Tamaño o SHA-256 incorrecto: {path}")
        print(f"{match_id}: clean, cuatro artefactos verificados")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    verify(args.directory)
