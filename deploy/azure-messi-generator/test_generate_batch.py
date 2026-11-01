from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("generate_batch.py")
SPEC = importlib.util.spec_from_file_location("mentox_messi_generate_batch", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SettingsTests(unittest.TestCase):
    def test_defaults_prepare_thirty_compressed_videos(self) -> None:
        with patch.dict(os.environ, {"MENTOX_UPLOAD_ENABLED": "0"}, clear=True):
            settings = MODULE.Settings.from_environment()

        self.assertEqual(settings.count, 30)
        self.assertEqual(settings.seconds, 180.0)
        self.assertEqual(settings.render_fps, 15.0)
        self.assertEqual(settings.state_stride, 15)
        self.assertFalse(settings.upload_enabled)

    def test_upload_requires_blob_endpoint(self) -> None:
        with patch.dict(os.environ, {"MENTOX_UPLOAD_ENABLED": "1"}, clear=True):
            with self.assertRaisesRegex(ValueError, "AZURE_BLOB_SERVICE_ENDPOINT"):
                MODULE.Settings.from_environment()

    def test_rejects_render_resampling_in_gpu_job(self) -> None:
        with patch.dict(
            os.environ,
            {
                "MENTOX_UPLOAD_ENABLED": "0",
                "MENTOX_CONTROL_FPS": "15",
                "MENTOX_RENDER_FPS": "10",
            },
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "captura completa de subpasos"):
                MODULE.Settings.from_environment()

    def test_style_pairs_never_repeat_same_team_style(self) -> None:
        pairs = [MODULE._styles(index) for index in range(30)]

        self.assertTrue(all(home != away for home, away in pairs))
        self.assertGreaterEqual(len(set(pairs)), 3)

    def test_clean_render_mode_is_accepted(self) -> None:
        with patch.dict(
            os.environ,
            {"MENTOX_UPLOAD_ENABLED": "0", "MENTOX_RENDER_MODE": "clean"},
            clear=True,
        ):
            settings = MODULE.Settings.from_environment()

        self.assertEqual(settings.render_mode, "clean")

    @patch.object(MODULE.subprocess, "run")
    def test_clean_mode_uses_rich_renderer_without_hud(self, run) -> None:
        run.return_value = SimpleNamespace(returncode=1)
        with patch.dict(
            os.environ,
            {"MENTOX_UPLOAD_ENABLED": "0", "MENTOX_RENDER_MODE": "clean"},
            clear=True,
        ):
            settings = MODULE.Settings.from_environment()

        with self.assertRaisesRegex(RuntimeError, "código 1"):
            MODULE._run_match(settings, 0, Path("/tmp/mentox-clean-render-test"))

        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--mode") + 1], "rich")
        self.assertIn("--clean-hud", command)


class CleanTests(unittest.TestCase):
    def test_clean_uses_rich_renderer_and_records_clean_provenance(self) -> None:
        with patch.dict(os.environ, {
            "MENTOX_UPLOAD_ENABLED": "0",
            "MENTOX_RENDER_MODE": "clean",
            "MENTOX_MATCH_COUNT": "3",
        }, clear=True):
            settings = MODULE.Settings.from_environment()

        with tempfile.TemporaryDirectory() as temporary:
            match_dir = Path(temporary)
            for name in ("match.mp4", "events.jsonl", "tracking.jsonl", "metadata.jsonl"):
                (match_dir / name).write_bytes(b"test")
            with patch.object(MODULE.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
                manifest = MODULE._run_match(settings, 0, match_dir)

        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--mode") + 1], "rich")
        self.assertIn("--clean-hud", command)
        self.assertEqual(settings.count, 3)
        self.assertEqual(manifest["render_mode"], "clean")
        self.assertEqual(len(manifest["artifacts"]), 4)


class GpuTests(unittest.TestCase):
    def test_gpu_is_required(self) -> None:
        fake_jax = SimpleNamespace(
            devices=lambda: [SimpleNamespace(id=0, platform="cpu", device_kind="cpu")]
        )
        with patch.dict(sys.modules, {"jax": fake_jax}):
            with self.assertRaisesRegex(RuntimeError, "requiere GPU CUDA"):
                MODULE._require_gpu()

    def test_t4_is_recorded(self) -> None:
        fake_jax = SimpleNamespace(
            devices=lambda: [
                SimpleNamespace(id=0, platform="gpu", device_kind="Tesla T4")
            ]
        )
        with patch.dict(sys.modules, {"jax": fake_jax}):
            devices = MODULE._require_gpu()

        self.assertEqual(devices[0]["kind"], "Tesla T4")


if __name__ == "__main__":
    unittest.main()
