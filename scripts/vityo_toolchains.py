#!/usr/bin/env python3
"""Build pinned product CLIs in Vityo's ignored toolchain cache."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Sequence


ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = {
    "styio": {
        "repository": "https://github.com/Unka-Malloc/styio-nightly.git",
        "executable": "styio.exe" if os.name == "nt" else "styio",
        "target": "styio",
    },
    "pafio": {
        "repository": "https://github.com/Unka-Malloc/pafio-nightly.git",
        "executable": "pafio.exe" if os.name == "nt" else "pafio",
        "target": "pafio",
    },
}
LLVM_CMAKE_ROOTS = (
    Path("/usr/lib/llvm-18/lib/cmake/llvm"),
    Path("/opt/homebrew/opt/llvm@18/lib/cmake/llvm"),
    Path("/usr/local/opt/llvm@18/lib/cmake/llvm"),
)

CommandRunner = Callable[[Sequence[str], Path], int]


class ToolchainError(RuntimeError):
    """Raised when a pinned source tool cannot be prepared or built."""


def _run(command: Sequence[str], cwd: Path) -> int:
    return subprocess.run(list(command), cwd=cwd, check=False).returncode


def _matrix_commit(product: str, *, root: Path) -> str:
    if product not in PRODUCTS:
        raise ToolchainError(f"unsupported pinned product tool: {product}")
    try:
        payload = json.loads((root / "toolchain/product-matrix.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ToolchainError("the product matrix could not be read") from error
    repositories = payload.get("repositories") if isinstance(payload, dict) else None
    commit = repositories.get(product) if isinstance(repositories, dict) else None
    if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ToolchainError(f"the product matrix has no valid {product} commit")
    return commit


def managed_source_root(product: str, commit: str, *, root: Path = ROOT) -> Path:
    if product not in PRODUCTS or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ToolchainError("the pinned product source identity is invalid")
    return root / "build" / "toolchains" / f"{product}-nightly" / commit


def _git_value(command: Sequence[str], *, cwd: Path) -> str:
    result = subprocess.run(
        list(command), cwd=cwd, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def _normalized_repository(url: str) -> str:
    return url.removesuffix(".git").rstrip("/")


def _checkout_matches(source: Path, product: str, commit: str) -> bool:
    if not source.is_dir():
        return False
    repository_root = _git_value(("git", "rev-parse", "--show-toplevel"), cwd=source)
    if not repository_root or Path(repository_root).resolve() != source.resolve():
        return False
    origin = _git_value(("git", "remote", "get-url", "origin"), cwd=source)
    if _normalized_repository(origin) != _normalized_repository(
        str(PRODUCTS[product]["repository"])
    ):
        return False
    return _git_value(("git", "rev-parse", "HEAD"), cwd=source) == commit


def _tracked_tree_clean(source: Path) -> bool:
    status = _git_value(
        ("git", "status", "--porcelain", "--untracked-files=no"), cwd=source
    )
    return status == ""


def ensure_pinned_checkout(
    product: str,
    *,
    root: Path = ROOT,
    runner: CommandRunner = _run,
) -> Path:
    commit = _matrix_commit(product, root=root)
    source = managed_source_root(product, commit, root=root)
    repository = str(PRODUCTS[product]["repository"])
    if source.exists():
        repository_root = _git_value(("git", "rev-parse", "--show-toplevel"), cwd=source)
        origin = _git_value(("git", "remote", "get-url", "origin"), cwd=source)
        if (
            Path(repository_root).resolve() != source.resolve()
            or origin.removesuffix(".git").rstrip("/")
            != repository.removesuffix(".git")
        ):
            raise ToolchainError(f"the managed {product} cache is not its pinned upstream checkout")
        if not _tracked_tree_clean(source):
            raise ToolchainError(f"the managed {product} source has local tracked changes")
        if not _checkout_matches(source, product, commit):
            if runner(("git", "fetch", "--depth=1", "origin", commit), source) != 0:
                raise ToolchainError(f"fetching the pinned {product} source failed")
            if runner(("git", "checkout", "--detach", commit), source) != 0:
                raise ToolchainError(f"selecting the pinned {product} source failed")
        return source

    source.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".{product}-checkout-", dir=source.parent) as temporary:
        clone = Path(temporary) / "source"
        if runner(("git", "clone", "--no-checkout", "--filter=blob:none", repository, str(clone)), root) != 0:
            raise ToolchainError(f"cloning the pinned {product} source failed")
        if runner(("git", "fetch", "--depth=1", "origin", commit), clone) != 0:
            raise ToolchainError(f"fetching the pinned {product} source failed")
        if runner(("git", "checkout", "--detach", commit), clone) != 0:
            raise ToolchainError(f"selecting the pinned {product} source failed")
        if not _checkout_matches(clone, product, commit):
            raise ToolchainError(f"the {product} source did not resolve to the product-matrix commit")
        shutil.move(str(clone), str(source))
    return source


def _llvm_cmake_dir() -> Path:
    explicit = os.environ.get("LLVM_DIR")
    discovered: list[Path] = []
    for command in ("llvm-config-18", "llvm-config"):
        executable = shutil.which(command)
        if executable is None:
            continue
        version = subprocess.run(
            [executable, "--version"], capture_output=True, text=True, check=False
        )
        if version.returncode == 0 and version.stdout.strip().split(".", 1)[0] == "18":
            configured = subprocess.run(
                [executable, "--cmakedir"], capture_output=True, text=True, check=False
            )
            if configured.returncode == 0:
                discovered.append(Path(configured.stdout.strip()))
    # An explicit LLVM_DIR is the operator's request and wins over discovery;
    # a PATH llvm-config only outranks the well-known installation roots.
    candidates: list[Path] = [Path(explicit)] if explicit else []
    candidates.extend(discovered)
    candidates.extend(LLVM_CMAKE_ROOTS)
    for candidate in candidates:
        config = candidate / "LLVMConfig.cmake"
        if not config.is_file():
            continue
        text = config.read_text(encoding="utf-8", errors="replace")
        version = re.search(r"LLVM_PACKAGE_VERSION\s+\"?(\d+)\.", text)
        if version is not None and version.group(1) == "18":
            return candidate.resolve()
    raise ToolchainError(
        "Styio requires LLVM 18 CMake development files; set LLVM_DIR to the directory containing LLVMConfig.cmake"
    )


def _build_commands(product: str, source: Path) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if shutil.which("cmake") is None:
        raise ToolchainError("CMake is required to build the pinned product CLI")
    build = source / "build/default"
    build_type = "Debug" if product == "styio" else "Release"
    configure: list[str] = [
        "cmake",
        "-S",
        str(source),
        "-B",
        str(build),
        f"-DCMAKE_BUILD_TYPE={build_type}",
    ]
    if product == "styio":
        configure.extend((f"-DLLVM_DIR={_llvm_cmake_dir()}", "-DSTYIO_NATIVE_TOOLCHAIN_MODE=auto"))
        if os.name == "nt":
            native_root = os.environ.get("STYIO_NATIVE_TOOLCHAIN_ROOT")
            if native_root:
                configure.append(f"-DSTYIO_NATIVE_TOOLCHAIN_ROOT={native_root}")
        elif sys.platform.startswith("linux"):
            if shutil.which("clang-18") and shutil.which("clang++-18"):
                configure.extend(("-DCMAKE_C_COMPILER=clang-18", "-DCMAKE_CXX_COMPILER=clang++-18"))
    else:
        configure.append("-DPAFIO_BUILD_TESTS=OFF")
    build_command = (
        "cmake",
        "--build",
        str(build),
        "--target",
        str(PRODUCTS[product]["target"]),
        "--config",
        "Debug" if product == "styio" else "Release",
        "--parallel",
        "2",
    )
    return tuple(configure), build_command


def _locate_built_cli(source: Path, executable_name: str) -> Path | None:
    """Find the built CLI, tolerating single- and multi-configuration layouts.

    Visual Studio is a multi-configuration generator and writes the binary to a
    per-configuration directory such as `bin/Debug/<name>` or `bin/Release/<name>`
    instead of straight into `bin/`. Single-configuration generators such as
    Makefiles and Ninja use the flat layout. Accept either rather than assuming
    one, and require the executable bit where the platform has one.
    """
    candidates = [source / "build/default/bin" / executable_name]
    candidates.extend(
        sorted((source / "build/default/bin").glob(f"*/{executable_name}"))
    )
    for candidate in candidates:
        if candidate.is_file() and (os.name == "nt" or os.access(candidate, os.X_OK)):
            return candidate
    return None


def provision(product: str, *, root: Path = ROOT, runner: CommandRunner = _run) -> Path:
    if product not in PRODUCTS:
        raise ToolchainError(f"unsupported pinned product tool: {product}")
    commit = _matrix_commit(product, root=root)
    source = ensure_pinned_checkout(product, root=root, runner=runner)
    executable_name = str(PRODUCTS[product]["executable"])
    executable = _locate_built_cli(source, executable_name)
    if executable is not None:
        if runner((str(executable), "--version"), source) != 0:
            raise ToolchainError(f"the pinned {product} CLI failed its version check")
        return executable
    configure, build = _build_commands(product, source)
    print(f"[vityo-toolchains] configure pinned {product} source {commit[:12]}", flush=True)
    if runner(configure, source) != 0:
        raise ToolchainError(f"configuring the pinned {product} source failed")
    print(f"[vityo-toolchains] build pinned {product} CLI", flush=True)
    if runner(build, source) != 0:
        raise ToolchainError(f"building the pinned {product} CLI failed")
    executable = _locate_built_cli(source, executable_name)
    if executable is None:
        raise ToolchainError(f"the pinned {product} build did not produce its CLI executable")
    if runner((str(executable), "--version"), source) != 0:
        raise ToolchainError(f"the pinned {product} CLI failed its version check")
    return executable


def validate_executable(product: str, executable: Path, *, root: Path = ROOT) -> bool:
    if product not in PRODUCTS or not executable.is_file():
        return False
    if os.name != "nt" and not os.access(executable, os.X_OK):
        return False
    commit = _matrix_commit(product, root=root)
    source = _git_value(("git", "rev-parse", "--show-toplevel"), cwd=executable.parent)
    return bool(source) and _checkout_matches(Path(source), product, commit)
