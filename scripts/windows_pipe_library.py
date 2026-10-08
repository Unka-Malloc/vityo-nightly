"""Build and explicitly select the app-owned Windows pipe test library.

Production packaging uses the app's CMake install target. Test processes use a
compile-time absolute path instead of changing DLL search paths or copying into
the Dart/Flutter SDK. No build or define is needed on other platforms.
"""
from __future__ import annotations

from functools import lru_cache
import json
import os
import re
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


def _select_visual_studio(instances: object, capabilities: object,
                          requested: str | None) -> tuple[str, str]:
    if not isinstance(instances, list) or not isinstance(capabilities, dict):
        raise ValueError("Invalid Visual Studio/CMake discovery metadata")
    generators = capabilities.get("generators")
    if not isinstance(generators, list):
        raise ValueError("CMake did not report its available generators")
    supported = {}
    for generator in generators:
        if not isinstance(generator, dict):
            continue
        match = re.fullmatch(r"Visual Studio (\d+) \d{4}", str(generator.get("name", "")))
        platforms = generator.get("supportedPlatforms")
        if (match and generator.get("platformSupport") is True
                and ("supportedPlatforms" not in generator
                     or (isinstance(platforms, list) and "x64" in platforms))):
            major = int(match[1])
            if major in supported:
                raise ValueError("CMake reported ambiguous Visual Studio generators")
            supported[major] = generator["name"]
    candidates = []
    for instance in instances:
        if not isinstance(instance, dict):
            continue
        path = instance.get("installationPath")
        version = instance.get("installationVersion")
        if (not isinstance(path, str) or not PureWindowsPath(path).is_absolute()
                or not isinstance(version, str)
                or re.fullmatch(r"\d+(?:\.\d+){1,3}", version) is None
                or instance.get("isComplete") is not True
                or instance.get("isLaunchable") is not True):
            continue
        if requested and PureWindowsPath(path) != PureWindowsPath(requested):
            continue
        candidates.append((tuple(int(part) for part in version.split(".")), path))
    if not candidates:
        raise ValueError("No installed MSVC x64 instance matches VSINSTALLDIR" if requested
                         else "No installed MSVC x64 instance was found")
    for version, path in sorted(candidates, reverse=True):
        if version[0] in supported:
            return supported[version[0]], path
    raise ValueError("The selected Visual Studio version has no matching x64 generator "
                     "in this CMake; use a compatible installed CMake")


def visual_studio_generator(cmake: str, root: Path) -> tuple[str, str]:
    # Honor the instance already selected by CI's DIA/LLVM discovery. The folder
    # name is not version evidence: query the installed VS installer metadata.
    program_files = os.environ.get("ProgramFiles(x86)") or os.environ.get("ProgramFiles")
    vswhere = (Path(program_files) / "Microsoft Visual Studio/Installer/vswhere.exe"
               if program_files else None)
    if vswhere is None or not vswhere.is_file():
        raise ValueError("The installed Visual Studio vswhere.exe is required")
    commands = (
        [str(vswhere), "-products", "*", "-requires",
         "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-format", "json", "-utf8"],
        [cmake, "-E", "capabilities"],
    )
    results = []
    try:
        for command in commands:
            completed = subprocess.run(command, cwd=root, check=True, timeout=15,
                                       capture_output=True, text=True, encoding="utf-8-sig")
            results.append(json.loads(completed.stdout))
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise ValueError("Visual Studio/CMake capability discovery failed") from error
    return _select_visual_studio(results[0], results[1], os.environ.get("VSINSTALLDIR"))


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
        raise ValueError("CMake and installed Visual Studio C++ x64 tools are required")
    generator, instance = visual_studio_generator(cmake, root)
    output = root / "build/windows-pipe-native"
    cache = output / "CMakeCache.txt"
    if cache.is_file():
        values = {}
        for line in cache.read_text(encoding="utf-8").splitlines():
            match = re.match(r"(CMAKE_GENERATOR(?:_INSTANCE|_PLATFORM)?):[^=]+=(.*)", line)
            if match:
                values[match[1]] = match[2]
        if (values.get("CMAKE_GENERATOR") != generator
                or values.get("CMAKE_GENERATOR_PLATFORM") != "x64"
                or PureWindowsPath(values.get("CMAKE_GENERATOR_INSTANCE", ""))
                   != PureWindowsPath(instance)):
            raise ValueError("Existing pipe build cache selects a different toolchain; "
                             "a fresh build directory is required")
    commands = (
        [cmake, "-S", str(source), "-B", str(output),
         "-G", generator, "-A", "x64", f"-DCMAKE_GENERATOR_INSTANCE={instance}"],
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
