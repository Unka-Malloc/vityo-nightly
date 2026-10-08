"""Bounded supervision for the installed macOS CI first-frame probe only."""

from __future__ import annotations

import json
import os
import re
import selectors
import subprocess
import time
from pathlib import Path
from typing import Sequence

from vityo_privacy import SECRET_RULES

STARTUP_TIMEOUT_SECONDS = 120
TERMINATION_GRACE_SECONDS = 5
OUTPUT_LIMIT_BYTES = 64 * 1024
POST_EXIT_DRAIN_SECONDS = 0.2


def _redact(text: str) -> str:
    # Never serialize the environment. Mask known inherited secrets if a native
    # dependency prints one, plus the repository's credential patterns.
    for name, value in os.environ.items():
        if value and re.search(r"secret|token|password|credential|api.?key|private.?key", name, re.I):
            text = text.replace(value, "[redacted]")
    text = re.sub(
        r"-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|$)",
        "[redacted private key]", text, flags=re.S,
    )
    for _name, _category, pattern in SECRET_RULES:
        text = pattern.sub("[redacted]", text)
    return text


def run_macos_startup_probe(
    command: Sequence[str],
    cwd: Path,
    diagnostics: Path,
    *,
    timeout_seconds: float = STARTUP_TIMEOUT_SECONDS,
    grace_seconds: float = TERMINATION_GRACE_SECONDS,
) -> int:
    """Require normal probe exit; timeout never constitutes startup evidence.

    Drain nonblocking POSIX pipes while retaining only a fixed-size prefix per
    stream. There is no unbounded capture buffer or raw log file. Only the child
    PID returned by Popen is ever signalled, never a name or process group.
    """
    output = {"stdout": bytearray(), "stderr": bytearray()}
    truncated = {"stdout": False, "stderr": False}
    process = None
    timed_out = False
    killed = False
    failure = None
    started = time.monotonic()
    try:
        process = subprocess.Popen(
            list(command), cwd=cwd, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = started + timeout_seconds
        drain_deadline = None
        with selectors.DefaultSelector() as selector:
            for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            while True:
                now = time.monotonic()
                if process.poll() is not None and drain_deadline is None:
                    drain_deadline = now + POST_EXIT_DRAIN_SECONDS
                remaining = (drain_deadline if drain_deadline is not None else deadline) - now
                if remaining <= 0:
                    timed_out = process.poll() is None
                    break
                events = selector.select(min(0.1, remaining))
                for key, _mask in events:
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    name = key.data
                    available = OUTPUT_LIMIT_BYTES - len(output[name])
                    output[name].extend(chunk[:available])
                    truncated[name] |= len(chunk) > available
                # Even an actively writing descendant cannot extend the short
                # post-exit drain deadline. Only the owned PID is supervised.
                if process.poll() is not None and (not events or not selector.get_map()):
                    break
    except (OSError, ValueError) as error:
        failure = type(error).__name__
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=grace_seconds)
                except subprocess.TimeoutExpired:
                    killed = True
                    process.kill()
                    process.wait()
            else:
                process.wait()
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

    rendered = {}
    for name, data in output.items():
        # A truncated last line might contain only the prefix of a credential;
        # discard that line before redaction rather than leaking a fragment.
        if truncated[name]:
            data = data[:data.rfind(b"\n") + 1]
        rendered[name] = _redact(data.decode("utf-8", errors="replace"))
    report = {
        "schema_version": 1,
        "command": [_redact(str(part)) for part in command],
        "pid": process.pid if process is not None else None,
        "returncode": process.returncode if process is not None else None,
        "timed_out": timed_out,
        "forced_kill": killed,
        "failure": failure,
        "timeout_seconds": timeout_seconds,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "output_limit_bytes_per_stream": OUTPUT_LIMIT_BYTES,
        "truncated": truncated,
        **rendered,
    }
    diagnostics.parent.mkdir(parents=True, exist_ok=True)
    diagnostics.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if failure or timed_out or process is None:
        return 2
    return process.returncode
