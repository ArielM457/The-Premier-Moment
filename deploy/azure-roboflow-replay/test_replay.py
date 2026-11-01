from __future__ import annotations

from base64 import b64encode
from io import BytesIO
import json

from fastapi.testclient import TestClient
from PIL import Image


def jpeg(color: tuple[int, int, int]) -> bytes:
    output = BytesIO()
    Image.new("RGB", (320, 180), color).save(output, format="JPEG", quality=90)
    return output.getvalue()


def test_replay_preserves_roboflow_contract(tmp_path, monkeypatch):
    image = jpeg((40, 120, 30))
    monkeypatch.setenv("MENTOX_MODEL_API_KEY", "x" * 32)
    monkeypatch.setenv("MENTOX_PRECOMPUTED_CATALOG", str(tmp_path / "catalog.json"))

    import fingerprint

    catalog = {
        "schema_version": "roboflow-precomputed-v1",
        "videos": [{"video_id": "one"}],
        "records": [{
            "video_id": "one",
            "video_sha256": "a" * 64,
            "video_time_ms": 1000,
            "fingerprint_rgb32x18_b64": b64encode(fingerprint.image_fingerprint(image)).decode(),
            "response": {
                "image": {"width": 320, "height": 180},
                "results": [
                    {"model": "player", "detections": []},
                    {"model": "ball", "detections": []},
                    {"model": "pitch", "detections": []},
                ],
            },
        }],
    }
    (tmp_path / "catalog.json").write_text(json.dumps(catalog), encoding="utf-8")

    import importlib
    import app as replay_app
    replay_app = importlib.reload(replay_app)
    with TestClient(replay_app.app) as client:
        ready = client.get("/health/ready")
        assert ready.status_code == 200
        assert ready.json()["models"] == ["player", "ball", "pitch"]
        response = client.post(
            "/v1/predict?models=all",
            headers={"X-API-Key": "x" * 32},
            files={"image": ("frame.jpg", image, "image/jpeg")},
        )
    assert response.status_code == 200
    assert {item["model"] for item in response.json()["results"]} == {"player", "ball", "pitch"}
    assert response.json()["device"] == "precomputed-cache"


def test_replay_rejects_unknown_frame(tmp_path, monkeypatch):
    known = jpeg((10, 10, 10))
    unknown = jpeg((250, 20, 200))
    monkeypatch.setenv("MENTOX_MODEL_API_KEY", "x" * 32)
    monkeypatch.setenv("MENTOX_PRECOMPUTED_CATALOG", str(tmp_path / "catalog.json"))

    import fingerprint
    catalog = {
        "schema_version": "roboflow-precomputed-v1",
        "videos": [{"video_id": "one"}],
        "records": [{
            "video_id": "one", "video_sha256": "a" * 64, "video_time_ms": 0,
            "fingerprint_rgb32x18_b64": b64encode(fingerprint.image_fingerprint(known)).decode(),
            "response": {"results": [
                {"model": "player", "detections": []},
                {"model": "ball", "detections": []},
                {"model": "pitch", "detections": []},
            ]},
        }],
    }
    (tmp_path / "catalog.json").write_text(json.dumps(catalog), encoding="utf-8")
    import importlib
    import app as replay_app
    replay_app = importlib.reload(replay_app)
    with TestClient(replay_app.app) as client:
        response = client.post(
            "/v1/predict?models=all",
            headers={"X-API-Key": "x" * 32},
            files={"image": ("frame.jpg", unknown, "image/jpeg")},
        )
    assert response.status_code == 422


def flaky_predict_once(monkeypatch, failures):
    """Sustituye la petición real: lanza cada error de failures y luego responde."""
    import precompute

    calls = []

    def fake(endpoint, api_key, frame, timeout):
        calls.append(frame)
        if len(calls) <= len(failures):
            raise failures[len(calls) - 1]
        return {"results": []}

    monkeypatch.setattr(precompute, "predict_once", fake)
    return precompute, calls


def test_predict_retries_a_dropped_connection(tmp_path, monkeypatch):
    from urllib.error import URLError

    precompute, calls = flaky_predict_once(monkeypatch, [URLError("EOF occurred in violation of protocol")])
    delays = []
    frame = tmp_path / "frame-000031.jpg"
    assert precompute.predict("https://model", "x" * 32, frame, 5, sleep=delays.append) == {"results": []}
    assert len(calls) == 2
    assert delays == [2]


def test_predict_does_not_retry_a_rejected_key(tmp_path, monkeypatch):
    import pytest
    from urllib.error import HTTPError

    rejected = HTTPError("https://model", 401, "Unauthorized", {}, None)
    precompute, calls = flaky_predict_once(monkeypatch, [rejected])
    with pytest.raises(HTTPError):
        precompute.predict("https://model", "x" * 32, tmp_path / "frame.jpg", 5, sleep=lambda _: None)
    assert len(calls) == 1


def test_predict_gives_up_after_the_last_attempt(tmp_path, monkeypatch):
    import pytest
    from urllib.error import HTTPError

    import precompute

    busy = HTTPError("https://model", 503, "Service Unavailable", {}, None)
    precompute, calls = flaky_predict_once(monkeypatch, [busy] * precompute.PREDICT_ATTEMPTS)
    delays = []
    with pytest.raises(HTTPError):
        precompute.predict("https://model", "x" * 32, tmp_path / "frame.jpg", 5, sleep=delays.append)
    assert len(calls) == precompute.PREDICT_ATTEMPTS
    assert delays == [2, 4, 8, 16]


def oversized_png(width: int, height: int) -> bytes:
    """PNG de pocos bytes que declara dimensiones enormes, sin decodificar sus píxeles."""
    import struct
    import zlib

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"")) + chunk(b"IEND", b"")


def test_huge_declared_dimensions_are_rejected_before_decoding():
    import pytest

    import fingerprint

    bomb = oversized_png(13_000, 13_000)
    assert len(bomb) < 100
    with pytest.raises(ValueError, match="fotograma de vídeo"):
        fingerprint.fingerprint_array(bomb)
    # Un fotograma de tamaño normal sigue siendo válido.
    assert fingerprint.fingerprint_array(jpeg((10, 20, 30))).shape == (18, 32, 3)
