"""Exercise the app's actual process lifecycle with a lightweight local server.

Run without PyTorch, model weights, or macOS: python -m unittest tests.test_macos_controller -v
"""

import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "macos/service_controller.py"
spec = importlib.util.spec_from_file_location("macos_service_controller", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ServiceController = module.ServiceController

FAKE_SERVER = """
import argparse, json, os, signal, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer

args = argparse.ArgumentParser()
args.add_argument("command", choices=["serve"])
for flag in ("model", "device", "host", "port"):
    args.add_argument("--" + flag)
config = args.parse_args()
behavior = Path("behavior.txt").read_text()
if behavior == "loading":
    time.sleep(60)
if behavior == "ignore":
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
print(json.dumps({"cache": os.environ.get("HF_HUB_CACHE"), "model": config.model,
                  "device": config.device, "cwd": os.getcwd()}), flush=True)
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {"status": "ok"} if self.path == "/health" else {"info": {"title": "muscriptor"}}
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = HTTPServer((config.host, int(config.port)), Handler)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
"""


@unittest.skipUnless(
    os.name == "posix", "The macOS controller uses POSIX sessions/signals"
)
class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="muscriptor app test ")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo with spaces"
        (self.repo / ".venv/bin").mkdir(parents=True)
        (self.repo / ".venv/bin/python").symlink_to(sys.executable)
        (self.repo / "muscriptor/web_dist").mkdir(parents=True)
        (self.repo / "muscriptor/__main__.py").write_text(FAKE_SERVER)
        (self.repo / "muscriptor/web_dist/index.html").write_text("test frontend")
        (self.repo / "behavior.txt").write_text("normal")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.log = Path(self.temp.name) / "logs/server.log"
        self.controller = ServiceController(
            self.repo,
            self.log,
            self.port,
            graceful_timeout=0.15,
            terminate_timeout=0.15,
        )
        self.addCleanup(self.controller.shutdown)

    def until(self, condition, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.controller.tick()
            if condition():
                return
            time.sleep(0.02)
        self.fail(
            f"Timed out: {self.controller.status()}; log: {self.log.read_text() if self.log.exists() else ''}"
        )

    def test_start_health_stop_and_restart(self):
        self.controller.start("medium")
        self.until(lambda: self.controller.state == "running")
        self.assertTrue(self.controller.status()["can_open"])
        first = self.controller.process
        self.controller.stop()
        self.until(lambda: self.controller.process is None)
        self.assertIsNotNone(first.poll())
        self.assertEqual(self.controller.state, "stopped")
        self.controller.start("large")
        self.until(lambda: self.controller.state == "running")
        self.assertNotEqual(first.pid, self.controller.process.pid)

    def test_existing_service_is_not_stopped(self):
        self.controller.start("medium")
        self.until(lambda: self.controller.state == "running")
        other = ServiceController(self.repo, self.log, self.port)
        other.start("large")
        self.assertEqual(other.state, "external")
        self.assertTrue(other.can_open)
        self.assertIsNone(other.process)
        other.stop()
        other.shutdown()
        self.assertIsNone(self.controller.process.poll())

    def test_startup_can_be_cancelled(self):
        (self.repo / "behavior.txt").write_text("loading")
        self.controller.start("medium")
        self.controller.stop()
        self.until(lambda: self.controller.process is None)
        self.assertEqual(self.controller.state, "stopped")

    def test_unresponsive_service_is_killed(self):
        (self.repo / "behavior.txt").write_text("ignore")
        self.controller.start("medium")
        self.until(lambda: self.controller.state == "running")
        process = self.controller.process
        self.controller.stop()
        self.until(lambda: self.controller.process is None)
        self.assertEqual(process.returncode, -signal.SIGKILL)

    def test_arguments_and_external_cache_with_spaces(self):
        cache = Path(self.temp.name) / "external cache/hub"
        self.controller.start("large", str(cache))
        self.until(lambda: self.controller.state == "running")
        record = next(
            json.loads(line)
            for line in self.log.read_text().splitlines()
            if line.startswith("{")
        )
        self.assertEqual(
            record,
            {
                "cache": str(cache),
                "model": "large",
                "device": "mps",
                "cwd": str(self.repo.resolve()),
            },
        )
        self.assertTrue(cache.is_dir())

    def test_default_cache_does_not_inherit_stale_override(self):
        from unittest.mock import patch

        with patch.dict(os.environ, {"HF_HUB_CACHE": "/missing/old-drive"}):
            self.controller.start("medium")
        self.until(lambda: self.controller.state == "running")
        record = next(
            json.loads(line)
            for line in self.log.read_text().splitlines()
            if line.startswith("{")
        )
        self.assertIsNone(record["cache"])

    def test_missing_environment_and_unbuilt_frontend(self):
        python = self.repo / ".venv/bin/python"
        python.unlink()
        self.controller.start("medium")
        self.assertEqual(self.controller.state, "error")
        self.assertIsNone(self.controller.process)
        python.symlink_to(sys.executable)
        (self.repo / "muscriptor/web_dist/index.html").unlink()
        self.controller.start("medium")
        self.assertIn("网页尚未构建", self.controller.message)
        self.assertIsNone(self.controller.process)

    def test_invalid_model_and_relative_cache_are_rejected(self):
        self.controller.start("arbitrary-model")
        self.assertEqual(self.controller.state, "error")
        self.controller.start("medium", "relative/cache")
        self.assertEqual(self.controller.state, "error")
        self.assertIsNone(self.controller.process)

    def test_helper_cleans_up_on_pipe_close_and_termination(self):
        for finish in ("quit", "eof", "sigterm"):
            with self.subTest(finish=finish):
                helper = subprocess.Popen(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "--repo",
                        str(self.repo),
                        "--log-file",
                        str(self.log),
                        "--port",
                        str(self.port),
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                try:
                    helper.stdin.write(b'{"action":"start","model":"medium"}\n')
                    helper.stdin.flush()
                    selector = selectors.DefaultSelector()
                    selector.register(helper.stdout, selectors.EVENT_READ)
                    buffer = b""
                    ready = False
                    deadline = time.monotonic() + 5
                    try:
                        while not ready and time.monotonic() < deadline:
                            if selector.select(timeout=0.2):
                                chunk = os.read(helper.stdout.fileno(), 65536)
                                if not chunk:
                                    break
                                buffer += chunk
                                while b"\n" in buffer:
                                    line, buffer = buffer.split(b"\n", 1)
                                    ready |= json.loads(line)["state"] == "running"
                    finally:
                        selector.close()
                    self.assertTrue(ready)
                    if finish == "quit":
                        helper.stdin.write(b'{"action":"quit"}\n')
                        helper.stdin.flush()
                    elif finish == "eof":
                        helper.stdin.close()
                    else:
                        helper.terminate()
                    self.assertEqual(helper.wait(timeout=5), 0)
                    with socket.socket() as probe:
                        self.assertNotEqual(
                            probe.connect_ex(("127.0.0.1", self.port)), 0
                        )
                finally:
                    if helper.poll() is None:
                        helper.terminate()
                        helper.wait(timeout=15)
                    for stream in (helper.stdin, helper.stdout, helper.stderr):
                        stream.close()


if __name__ == "__main__":
    unittest.main()
