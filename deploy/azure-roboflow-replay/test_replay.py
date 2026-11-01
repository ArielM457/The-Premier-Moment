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
