import json
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryFile(mode="w+") as log:
    server = subprocess.Popen(
        [repo / "rust/target/debug/ente-devserver"],
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=log,
        text=True,
    )
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(server.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=300):
                raise RuntimeError("Museum did not become ready within 300 seconds")
            line = server.stdout.readline()
        if not line:
            raise RuntimeError("Museum exited before printing its fixture")
        fixture = json.loads(line)
        result = subprocess.run(
            ["swift", "run", "--package-path", str(repo / "apple/EnteBridge"), "smoke"],
            cwd=repo,
            input=json.dumps(fixture),
            text=True,
            stdout=subprocess.PIPE,
            timeout=180,
            check=True,
        )
        actual = json.loads(result.stdout)
        expected = fixture["expected_codes"]
        if actual != expected:
            raise RuntimeError(f"Swift code mismatch\nexpected {expected!r}\nactual {actual!r}")
        print(result.stdout.strip())
        print(f"smoke: {len(actual)} codes match at {fixture['now_unix_ms']} ms; Swift login, display and cached restart before sync passed")
    except BaseException:
        log.seek(0)
        sys.stderr.write(log.read())
        raise
    finally:
        if server.poll() is None:
            server.send_signal(signal.SIGTERM)
            try:
                server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        server.stdout.close()
