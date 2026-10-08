#!/usr/bin/env python3
"""Build the MSVC x64 Release DLL used by Windows Dart/Flutter pipe tests."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
from windows_pipe_library import build_library


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args(argv)
    try:
        library = build_library(SCRIPTS.parent)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    if args.github_output is not None:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write(f"library={library}\n")
    print(library)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
