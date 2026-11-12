"""Private JSON-lines bridge for the macOS app; uses only the Python standard library."""

from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


class ServiceController:
    def __init__(
        self,
        repo: Path,
        log_file: Path,
        port: int = 8222,
        graceful_timeout: float = 8,
        terminate_timeout: float = 4,
    ):
        self.repo = repo.resolve()
        self.log_file = log_file
        self.port = port
        self.url = f"http://127.0.0.1:{port}"
        self.process: subprocess.Popen | None = None
        self.state = "stopped"
        self.message = "已停止"
        self.can_open = False
        self.model = "medium"
        self.graceful_timeout = graceful_timeout
        self.terminate_timeout = terminate_timeout
        self._stop_deadline = 0.0
        self._stop_stage = 0
        self._next_probe = 0.0
        # Ignore system HTTP proxies for loopback health checks.
        self._http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def status(self) -> dict:
        return {
            "state": self.state,
            "message": self.message,
            "can_open": self.can_open,
            "owned": self.process is not None,
            "model": self.model,
            "url": self.url,
            "log_file": str(self.log_file),
        }

    def _json_endpoint(self, path: str) -> dict:
        with self._http.open(self.url + path, timeout=0.3) as response:
            if response.status != 200:
                return {}
            value = json.load(response)
            return value if isinstance(value, dict) else {}

    def _healthy(self) -> bool:
        try:
            return self._json_endpoint("/health").get("status") == "ok"
        except (OSError, ValueError, urllib.error.URLError):
            return False

    def _external_is_muscriptor(self) -> bool:
        try:
            return (
                self._healthy()
                and self._json_endpoint("/openapi.json").get("info", {}).get("title")
                == "muscriptor"
            )
        except (OSError, ValueError, urllib.error.URLError):
            return False

    def start(self, model: str, cache_dir: str = "") -> None:
        if self.process is not None:
            return
        if model not in {"small", "medium", "large"}:
            self.state, self.message = "error", "请选择 small、medium 或 large 模型。"
            return
        self.can_open = False
        python = self.repo / ".venv/bin/python"
        if not python.is_file() or not (self.repo / "muscriptor/__main__.py").is_file():
            self.state = "error"
            self.message = "找不到项目 Python 环境，请选择正确的项目文件夹并执行 uv sync --frozen。"
            return
        if not (self.repo / "muscriptor/web_dist/index.html").is_file():
            self.state = "error"
            self.message = "网页尚未构建，请先在 web 目录完成 pnpm run build。"
            return
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", self.port))
        except OSError:
            self.state = "external"
            self.can_open = self._external_is_muscriptor()
            self.message = (
                "已有 MuScriptor 服务。请先在原终端按 Control+C 停止，再从本应用启动。"
                if self.can_open
                else f"端口 {self.port} 已被占用，请停止原服务后重试。"
            )
            return

        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
        env.pop("HF_HUB_CACHE", None)
        try:
            if cache_dir:
                cache = Path(cache_dir).expanduser()
                if not cache.is_absolute():
                    raise ValueError("模型缓存必须使用绝对路径。")
                if cache.parts[:2] == ("/", "Volumes") and len(cache.parts) >= 3:
                    volume = Path(*cache.parts[:3])
                    if not volume.is_mount():
                        raise ValueError("外置磁盘未挂载，请连接磁盘后重试。")
                cache.mkdir(parents=True, exist_ok=True)
                env["HF_HUB_CACHE"] = str(cache)
            self.log_file.parent.mkdir(parents=True, exist_ok=True)
            command = [
                str(python),
                "-m",
                "muscriptor",
                "serve",
                "--model",
                model,
                "--device",
                "mps",
                "--host",
                "127.0.0.1",
                "--port",
                str(self.port),
            ]
            with self.log_file.open("ab", buffering=0) as log:
                stamp = datetime.datetime.now().isoformat(timespec="seconds")
                log.write(f"\n[{stamp}] Starting MuScriptor ({model}, MPS)\n".encode())
                self.process = subprocess.Popen(
                    command,
                    cwd=self.repo,
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    # A private session lets us stop this service and its own
                    # render subprocesses, without targeting processes by name/port.
                    start_new_session=True,
                )
        except (OSError, ValueError) as error:
            self.state, self.message = "error", f"无法启动：{error}"
            return
        self.model = model
        self.state = "starting"
        self.message = "正在加载模型，首次使用可能需要下载。可打开日志查看进度。"
        self._next_probe = 0

    def _signal_group(self, sig: int) -> None:
        if self.process is not None and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, sig)
            except ProcessLookupError:
                pass

    def stop(self) -> None:
        if self.process is None or self.state == "stopping":
            return
        self.state, self.message = "stopping", "正在停止服务…"
        self.can_open = False
        self._stop_stage = 0
        self._stop_deadline = time.monotonic() + self.graceful_timeout
        self._signal_group(signal.SIGINT)

    def tick(self) -> None:
        if self.process is None:
            return
        return_code = self.process.poll()
        if return_code is not None:
            expected = self.state == "stopping"
            self.process = None
            self.can_open = False
            self.state = "stopped" if expected else "error"
            self.message = (
                "已停止"
                if expected
                else f"服务已退出（退出码 {return_code}），请打开日志查看原因。"
            )
            return
        now = time.monotonic()
        if self.state == "stopping" and now >= self._stop_deadline:
            self._signal_group(
                signal.SIGTERM if self._stop_stage == 0 else signal.SIGKILL
            )
            self._stop_stage += 1
            self._stop_deadline = now + self.terminate_timeout
        elif self.state == "starting" and now >= self._next_probe:
            self._next_probe = now + 1
            if self._healthy():
                self.state, self.message = "running", "运行中"
                self.can_open = True

    def shutdown(self) -> None:
        self.stop()
        while self.process is not None:
            self.tick()
            if self.process is not None:
                time.sleep(0.05)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--log-file", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8222)
    args = parser.parse_args()
    controller = ServiceController(args.repo, args.log_file, args.port)
    active = True

    def request_shutdown(_sig, _frame):
        nonlocal active
        active = False

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)
    selector = selectors.DefaultSelector()
    selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
    buffer = b""
    previous = None

    def emit() -> None:
        nonlocal previous
        current = controller.status()
        if current != previous:
            print(json.dumps(current, ensure_ascii=False), flush=True)
            previous = current

    try:
        while active:
            controller.tick()
            emit()
            if not selector.select(timeout=0.2):
                continue
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            if len(buffer) > 65536:
                raise ValueError("Control message too large")
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    command = json.loads(line)
                    action = command["action"]
                    if action == "start":
                        controller.start(
                            command.get("model", "medium"), command.get("cache_dir", "")
                        )
                    elif action == "stop":
                        controller.stop()
                    elif action == "quit":
                        active = False
                        break
                    elif action != "status":
                        raise ValueError("Unknown action")
                except (KeyError, TypeError, ValueError) as error:
                    print(
                        f"Invalid control command: {error}", file=sys.stderr, flush=True
                    )
                emit()
    except BrokenPipeError:
        pass
    finally:
        selector.close()
        controller.shutdown()


if __name__ == "__main__":
    main()
