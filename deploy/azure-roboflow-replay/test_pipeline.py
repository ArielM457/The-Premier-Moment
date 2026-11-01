"""Pruebas de orquestación con Azure, Docker y red completamente sustituidos."""

from hashlib import sha256
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "infra/azure").mkdir(parents=True)
        package = self.root / "deploy/azure-roboflow-replay"
        package.mkdir(parents=True)
        for name in ("run-messi-roboflow.sh",):
            shutil.copy(ROOT / "infra/azure" / name, self.root / "infra/azure" / name)
        shutil.copy(ROOT / "deploy/azure-roboflow-replay/verify_messi_batch.py", package)
        (package / "requirements.txt").write_text("")
        self.log = self.root / "commands.log"
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "MENTOX_AZURE_SUBSCRIPTION_ID": "11111111-1111-1111-1111-111111111111",
            "MENTOX_MODEL_API_KEY": "x" * 32,
            "MENTOX_ACCEPT_MODEL_LICENSES": "1",
            "MENTOX_BATCH_ID": "test-clean",
            "PIPELINE_TEST_LOG": str(self.log),
            "PIPELINE_TEST_ROOT": str(self.root),
        }
        self.tool("az", '''#!/usr/bin/env python3
import os,sys
a=sys.argv[1:]
with open(os.environ['PIPELINE_TEST_LOG'],'a') as f: f.write('az '+' '.join(a)+'\\n')
if a[:2]==['account','show']: print(os.environ['MENTOX_AZURE_SUBSCRIPTION_ID'])
elif a[:3]==['containerapp','job','start']: print('test-execution')
elif a[:4]==['containerapp','job','execution','list']:
    if "Running" not in ' '.join(a): print(os.environ.get('PIPELINE_TEST_JOB_STATUS','Succeeded'))
elif a[:3]==['storage','blob','exists']: print('false')
elif a[:2]==['role','assignment'] and 'list' in a: print('1')
elif a[:2]==['containerapp','show']: print('test.invalid')
elif a[:2]==['storage','account']: print('/test/storage')
elif a[:2]==['ad','signed-in-user']: print('test-user')
''')
        self.tool("bash", '''#!/bin/sh
echo "child $*" >> "$PIPELINE_TEST_LOG"
''')
        self.tool("curl", '#!/bin/sh\necho \'{"status":"ready","device":"GPU"}\'\n')
        self.tool("uv", '#!/bin/sh\nexit 0\n')
        self.tool("docker", '#!/bin/sh\nexit 0\n')
        self.tool("ffmpeg", '#!/bin/sh\nexit 0\n')
        for index in range(1, 4):
            match_id = f"messi-{index:03d}"
            match_dir = self.root / "evidencias-generadas/test-clean/messi/test-clean" / match_id
            match_dir.mkdir(parents=True)
            artifacts = []
            for name in ("match.mp4", "events.jsonl", "tracking.jsonl", "metadata.jsonl"):
                content = name.encode()
                (match_dir / name).write_bytes(content)
                artifacts.append({"name": name, "bytes": len(content), "sha256": sha256(content).hexdigest()})
            (match_dir / "manifest.json").write_text(json.dumps({
                "match_id": match_id, "render_mode": "clean", "artifacts": artifacts,
            }))
        venv_bin = self.root / "evidencias-generadas/roboflow-tools-venv/bin"
        venv_bin.mkdir(parents=True)
        fake_python = venv_bin / "python"
        fake_python.write_text('''#!/usr/bin/env python3
import os,pathlib,sys
if os.environ.get('PIPELINE_TEST_PROCESS_FAIL'): sys.exit(7)
p=pathlib.Path(sys.argv[sys.argv.index('--output')+1]);p.parent.mkdir(parents=True,exist_ok=True)
p.write_text('{"test_catalog":true}')
''')
        fake_python.chmod(0o755)

    def tool(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_stage(self, action):
        return subprocess.run(
            ["/bin/bash", str(self.root / "infra/azure/run-messi-roboflow.sh"), action],
            env=self.env, capture_output=True, text=True, timeout=15,
        )

    def test_all_runs_in_order_with_gpu_off_before_cpu(self):
        result = self.run_stage("all")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.log.read_text()
        order = [
            "child infra/azure/deploy-roboflow-suite.sh",
            "child infra/azure/deploy-messi-generator.sh",
            "az storage blob download-batch",
            "child infra/azure/stop-roboflow-gpu.sh",
            "child infra/azure/deploy-roboflow-replay.sh",
            "child infra/azure/delete-messi-generator-job.sh",
        ]
        offsets = [log.index(item) for item in order]
        self.assertEqual(offsets, sorted(offsets))
        self.assertTrue((self.root / "evidencias-generadas/test-clean/roboflow-catalog.json").is_file())

    def test_failed_processing_requests_gpu_shutdown(self):
        self.env["PIPELINE_TEST_PROCESS_FAIL"] = "1"
        result = self.run_stage("process")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("child infra/azure/stop-roboflow-gpu.sh", self.log.read_text())

    def test_failed_job_does_not_proceed_to_download(self):
        self.env["PIPELINE_TEST_JOB_STATUS"] = "Failed"
        result = self.run_stage("all")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("az storage blob download-batch", self.log.read_text())

    def test_help_never_calls_azure(self):
        result = self.run_stage("help")
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
