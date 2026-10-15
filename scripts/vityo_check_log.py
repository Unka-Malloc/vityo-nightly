"""Opt-in command evidence for local engineering checks, without retries."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def run_logged(command, *, cwd, environment=None) -> int:
    env = dict(os.environ if environment is None else environment)
    root = Path(env["VITYO_CHECK_LOG_DIR"])
    root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="command-", dir=root))
    argv = list(map(str, command))
    reports = []
    # Additional reporters preserve names/skips without changing test selection.
    if Path(argv[0]).name in {"flutter", "dart"} and argv[1:2] == ["test"]:
        argv += ["--file-reporter", f"json:{directory / 'tests.jsonl'}"]
        if "--coverage" in argv:
            reports.append(Path(cwd) / "coverage/lcov.info")
    if "unittest" in argv and "discover" in argv:
        argv.append("--verbose")
    if any(Path(arg).name == "python-coverage-gate.py" for arg in argv):
        reports.append(Path(cwd) / env.get("COVERAGE_FILE", ".coverage"))
    for flag in ("--output-path", "--receipt"):
        if flag in argv:
            reports.append(Path(cwd) / argv[argv.index(flag) + 1])
    runners = {"vityo.py", "final.py", "project-coverage-gate.py", "python-coverage-gate.py",
               "rust-coverage-gate.py", "vityo_quality.py"}
    if any(Path(arg).name in runners for arg in argv):
        env["VITYO_CHECK_LOG_DIR"] = str(directory / "children")
    else:
        # Test subjects must not inherit the recorder's control variable.
        env.pop("VITYO_CHECK_LOG_DIR", None)
    record = {"argv": argv, "cwd": str(cwd), "exit_code": None,
              "started_at": datetime.now(timezone.utc).isoformat(),
              "reports": [], "child_skips": None}
    record_path = directory / "command.json"
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    code = 1
    try:
        with (directory / "stdout.log").open("wb") as stdout, \
                (directory / "stderr.log").open("wb") as stderr:
            code = subprocess.run(argv, cwd=cwd, env=env, stdout=stdout,
                                  stderr=stderr, check=False).returncode
        record["exit_code"] = code
    except OSError as error:
        record["launch_error"] = str(error)
        raise
    finally:
        record["finished_at"] = datetime.now(timezone.utc).isoformat()
        # Save the real child exit before copying reports; a retention error
        # must neither mask an existing failure nor manufacture a pass.
        record_path.write_text(json.dumps(record, indent=2) + "\n")
    try:
        for index, source in enumerate(reports):
            entry = {"source": str(source), "present": source.is_file()}
            if source.is_file():
                destination = directory / f"report-{index}-{source.name}"
                shutil.copy2(source, destination)
                entry["copy"] = destination.name
            record["reports"].append(entry)
        record["retention_exit_code"] = 0
    except OSError as error:
        record["retention_exit_code"] = 1
        record["retention_error"] = str(error)
        code = code or 1
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    # Parent logs contain this reference; complete streams stay at the leaf.
    print(f"[check-log] {directory.name}: exit={record['exit_code']}", flush=True)
    return code
