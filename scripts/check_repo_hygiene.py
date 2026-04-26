#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CANONICAL = ROOT / "scripts" / "repo-hygiene-gate.py"


def main() -> int:
    proc = subprocess.run([sys.executable, str(CANONICAL), "--mode", "tracked"], cwd=ROOT)
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
