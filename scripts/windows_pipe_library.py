"""Build and explicitly select the app-owned Windows pipe test library.

Production packaging uses the app's CMake install target. Test processes use a
compile-time absolute path instead of changing DLL search paths or copying into
the Dart/Flutter SDK. No build or define is needed on other platforms.
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path, PureWindowsPath
import shutil
import subprocess
import sys

LIBRARY_NAME = "vityo_windows_pipe.dll"
DEFINE = "VITYO_WINDOWS_PIPE_LIBRARY"


def library_path(root: Path) -> Path:
    return root.resolve() / "build/windows-pipe-native/Release" / LIBRARY_NAME


def require_library(path: Path) -> Path:
    if not path.is_absolute():
        raise ValueError("Windows pipe test library must be an absolute path")
    resolved = path.resolve()
    if resolved.name != LIBRARY_NAME or not resolved.is_file():
        raise ValueError("Windows pipe test DLL is missing; run scripts/build-windows-pipe-library.py")
    return resolved


def build_library(root: Path) -> Path:
    """Bounded, standalone MSVC x64 build. Never install into an SDK or system."""
    if sys.platform != "win32":
        raise ValueError("Windows pipe library requires native Windows and MSVC x64")
    root = root.resolve()
    source = root / "products/vityo_app/native/windows_pipe"
    if not (source / "CMakeLists.txt").is_file():
        raise ValueError("Windows pipe CMake source is missing")
    cmake = shutil.which("cmake")
    if cmake is None:
        raise ValueError("CMake and Visual Studio 2022 C++ x64 tools are required")
    output = root / "build/windows-pipe-native"
    commands = (
        [cmake, "-S", str(source), "-B", str(output),
         "-G", "Visual Studio 17 2022", "-A", "x64"],
        [cmake, "--build", str(output), "--config", "Release",
         "--target", "vityo_windows_pipe"],
    )
    for command in commands:
        try:
            subprocess.run(command, cwd=root, check=True, timeout=120)
        except (OSError, subprocess.SubprocessError) as error:
            raise ValueError("Windows pipe native build failed") from error
    return require_library(library_path(root))


@lru_cache(maxsize=None)
def _prepared_library(root: Path) -> Path:
    # CMake checks source freshness once per runner; all its test commands reuse
    # this same output. A stale DLL from a different revision is never trusted.
    return build_library(root)


def dart_define(library: Path) -> str:
    return f"-D{DEFINE}={require_library(library)}"


def test_command(command: list[str], *, root: Path) -> list[str]:
    """Supply the shim only to Dart execution / Flutter test commands."""
    result = list(command)
    if sys.platform != "win32" or len(result) < 2:
        return result
    executable = PureWindowsPath(result[0]).stem.lower()
    if executable == "flutter" and result[1] == "test":
        flag = "--dart-define="
        index = 2
    # package:test compiles kernels separately and drops VM -D declarations.
    # The existing bare Dart test suites do not exercise Windows native pipes;
    # real pipe unit suites run through Flutter, standalone probes through Dart.
    elif executable == "dart" and (
        result[1].startswith("--packages=")
        or result[1].endswith(".dart")
    ):
        flag = "-D"
        index = 1
    else:
        return result
    library = require_library(_prepared_library(root.resolve()))
    result.insert(index, f"{flag}{DEFINE}={library}")
    return result
