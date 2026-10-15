#!/usr/bin/env python3
"""Execute scripts emitted by DaemonStartupTests in their disposable fixture directory.

No real native service is registered. The daemon fixture provides health/update leases;
the production runner, installer, locks, recovery and native registration scripts execute.
"""
import base64
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.request

root = Path(sys.argv[1]).resolve()
config = json.loads((root / "fixture.json").read_text())
directory = Path(config["directory"]).resolve()
assert root in directory.parents and directory.name == ".mindwire"
port = int(config["port"])
environment = dict(os.environ, HOME=str(directory.parent))
base = f"http://127.0.0.1:{port}"


def execute(name, check=True, env=None):
    result = subprocess.run(["/bin/bash", str(root / name)], env=env or environment,
                            capture_output=True, text=True, timeout=75)
    if check and (result.returncode or "DAEMON_OK" not in result.stdout):
        raise AssertionError(f"{name}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def health():
    request = urllib.request.Request(base + "/healthz", headers={"Authorization": "Bearer fixture-token"})
    try:
        with urllib.request.urlopen(request, timeout=0.5) as response:
            return json.load(response)
    except Exception:
        return None


def wait_health(version=None, different_pid=None):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        value = health()
        if value and (not version or value["version"] == version) and value["pid"] != different_pid:
            return value
        time.sleep(0.1)
    raise AssertionError("Service did not recover: " + (directory / "mindwire.log").read_text()[-2000:])


def daemon(version):
    return f'''#!{sys.executable}
import http.server, json, os, signal
from pathlib import Path
directory = Path(__file__).parent
version = {version!r}
with (directory / 'launches').open('a') as output: output.write(str(os.getpid()) + '\\n')
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self, *args): pass
 def reply(self, status, value):
  data = json.dumps(value, separators=(',', ':')).encode()
  self.send_response(status); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
 def do_GET(self):
  if self.headers.get('Authorization') != 'Bearer fixture-token': return self.reply(401, {{}})
  self.reply(200, {{'ok': True, 'version': version, 'pid': os.getpid()}})
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length', 0)))
  if (directory / 'busy').exists(): return self.reply(409, {{'code': 'service_busy'}})
  self.reply(201, {{'id': 'fixturelease', 'pid': os.getpid()}})
 def do_DELETE(self): self.reply(200, {{}})
class Server(http.server.HTTPServer): allow_reuse_address = True
signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
Server(('127.0.0.1', {port}), Handler).serve_forever()
'''


def scoped_processes():
    result = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
    paths = [str(folder / name) for folder in {directory, Path(config["directory"])}
             for name in ["service-runner.sh", "mindwired"]]
    return [int(line.strip().split(None, 1)[0]) for line in result.splitlines()
            if any(path in line for path in paths)]


def stop_fixture():
    for pid in scoped_processes():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.4)
    for pid in scoped_processes():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


legacy = None
try:
    assert health() is None, "Fixture port must be unused"
    for script in root.glob("*.sh"):
        subprocess.run(["/bin/bash", "-n", str(script)], check=True, capture_output=True)
    missing = execute("configure-existing.sh", check=False)
    assert "DAEMON_NOT_INSTALLED" in missing.stdout
    assert not (directory / "service.env").exists()
    empty = execute("configure-empty.sh", check=False)
    assert empty.returncode != 0 and "credential is missing" in empty.stdout
    assert not (directory / "daemon.token").exists()
    execute("configure.sh")
    assert (directory / "daemon.token").stat().st_mode & 0o777 == 0o600
    assert (directory / "service-runner.sh").stat().st_mode & 0o777 == 0o700
    token = (directory / "daemon.token").read_bytes()
    state = directory / "agent-state.json"
    state.write_text('{"sentinel":"project/chat state survives"}')
    binary = directory / "mindwired"
    binary.write_text(daemon("0.1.38"))
    binary.chmod(0o700)

    # Migration must not interrupt a legacy daemon or steal its port.
    legacy = subprocess.Popen([str(binary)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
    initial = wait_health("0.1.38")
    execute("background.sh")
    time.sleep(2.5)
    assert health()["pid"] == initial["pid"]
    assert len((directory / "launches").read_text().splitlines()) == 1
    legacy.terminate()
    legacy.wait(timeout=5)
    recovered = wait_health("0.1.38", different_pid=initial["pid"])
    print("PASS legacy adoption leaves work running, then recovers its first exit", flush=True)

    # Repeated starts/registers must not create duplicate daemons or guardians.
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(execute, ["background.sh", "start.sh", "configure.sh", "background.sh", "start.sh", "start.sh"]))
    time.sleep(0.5)
    assert health()["pid"] == recovered["pid"]
    assert len((directory / "launches").read_text().splitlines()) == 2
    assert len(scoped_processes()) == 2, "Expected one guardian and one daemon"
    print("PASS concurrent registration/start is a single service", flush=True)

    # Restart policy cannot race the installer's activation gate.
    with (directory / "daemon-activation.lock").open("w") as gate:
        fcntl.flock(gate, fcntl.LOCK_EX)
        os.kill(recovered["pid"], signal.SIGKILL)
        time.sleep(3)
        assert health() is None
        assert len((directory / "launches").read_text().splitlines()) == 2
    recovered = wait_health("0.1.38", different_pid=recovered["pid"])
    print("PASS crash restart waits for atomic activation", flush=True)

    payload = base64.b64encode(daemon("0.1.39").encode())
    (root / "binary.b64").write_bytes(payload)
    (directory / "busy").touch()
    denied = execute("install.sh", check=False)
    assert "DAEMON_BUSY" in denied.stdout
    assert health()["pid"] == recovered["pid"]
    assert "0.1.38" in binary.read_text()
    (directory / "busy").unlink()
    (root / "binary.b64").write_bytes(payload)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(execute, ["install.sh", "install.sh", "start.sh"]))
    updated = wait_health("0.1.39")
    assert updated["pid"] != recovered["pid"]
    assert (directory / "daemon.token").read_bytes() == token
    assert json.loads(state.read_text())["sentinel"] == "project/chat state survives"
    assert len(scoped_processes()) == 2
    print("PASS busy updates are refused; duplicate updates replace once and preserve state", flush=True)

    # Native macOS registration: execute with a fake launchctl, never touch the real manager.
    if sys.platform == "darwin":
        shim = root / "commands"
        shim.mkdir(exist_ok=True)
        (shim / "sudo").write_text("#!/bin/sh\nexit 1\n")
        (shim / "launchctl").write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HOME/launchctl.calls\"\nexit 0\n")
        for path in shim.iterdir():
            path.chmod(0o700)
        native_env = dict(environment, PATH=str(shim) + ":" + environment["PATH"])
        execute("native.sh", env=native_env)
        plists = list((directory.parent / "Library/LaunchAgents").glob("sh.mindwire.workspace.*.plist"))
        assert len(plists) == 1
        import plistlib
        plan = plistlib.loads(plists[0].read_bytes())
        assert plan["ProgramArguments"][0] == "/bin/bash"
        assert Path(plan["ProgramArguments"][1]).resolve() == directory / "service-runner.sh"
        assert plan["KeepAlive"] is True and plan["RunAtLoad"] is True
        assert "-k" not in (directory.parent / "launchctl.calls").read_text()
        print("PASS native launchd plan preserves special paths and never force-restarts", flush=True)

    stop_fixture()
    assert health() is None
    execute("background.sh")
    wait_health("0.1.39")
    assert (directory / "daemon.token").read_bytes() == token
    assert json.loads(state.read_text())["sentinel"] == "project/chat state survives"
    print("PASS relaunch keeps the installed version, credentials and workspace data", flush=True)
finally:
    stop_fixture()
    if legacy and legacy.poll() is None:
        legacy.kill()
        legacy.wait(timeout=5)
