#!/usr/bin/env python3
"""One stage-oriented local and CI delivery path for Vityo."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Callable, Iterable, Sequence


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
from vityo_toolchains import ToolchainError, provision, validate_executable


FLUTTER_DIR = Path("products/vityo_app")
VITYOD_MANIFEST = FLUTTER_DIR / "native/vityod/Cargo.toml"
AGENT_MANIFEST = Path("products/vityo_coding_agent/Cargo.toml")
DELIVERY_STAGES = (
    "privacy",
    "architecture",
    "test",
    "coverage",
    "build",
    "install",
    "launch",
)
PORTABLE_IDE_SUITES = (
    "daemon-core",
    "workspace-transactions",
    "developer-loop",
    "agent-client-protocol",
    "mcp-host",
    "ide-security",
    "agent-workbench",
    "quality-runtime",
    "recovery-isolation",
)
PLATFORM_BUILD_COMMANDS = {
    "linux": ("build", "linux", "--release"),
    "windows": ("build", "windows", "--release"),
    "macos": ("build", "macos", "--release"),
}
PACKAGE_SUFFIXES = {"linux": ".deb", "windows": ".zip", "macos": ".dmg"}
PACKAGE_EXECUTABLES = {
    "linux": Path("opt/vityo/vityo_app"),
    "windows": Path("vityo_app.exe"),
    "macos": Path("Contents/MacOS/Vityo"),
}
AGENT_PACKAGE_PATHS = {
    "linux": Path("components/vityo-coding-agent"),
    "windows": Path("components/vityo-coding-agent.exe"),
    "macos": Path("Contents/Helpers/vityo-coding-agent"),
}
DAEMON_PACKAGE_PATHS = {
    "linux": Path("components/vityod"),
    "windows": Path("components/vityod.exe"),
    "macos": Path("Contents/Helpers/vityod"),
}
RUST_COVERAGE_CLI_VERSION = "0.9.0"


@dataclasses.dataclass(frozen=True)
class DeliveryOptions:
    mode: str = "local"
    platform: str = ""
    base: str | None = None
    revision_range: str | None = None
    flutter_dir: Path = FLUTTER_DIR
    styio_bin: str | None = None
    pafio_bin: str | None = None
    output_dir: Path = Path("build/nightly")
    evidence_dir: Path = Path("build/evidence")
    artifact: Path | None = None
    install_root: Path | None = None
    scope: str = "full"
    notices_validated: bool = False


@dataclasses.dataclass(frozen=True)
class Command:
    label: str
    argv: tuple[str, ...]
    cwd: Path = ROOT
    environment: dict[str, str] | None = None


Runner = Callable[[Sequence[str], Path, dict[str, str] | None], int]


def host_platform() -> str:
    if sys.platform == "darwin":
        return "macos"
    if sys.platform == "win32":
        return "windows"
    return "linux"


def require_rust_toolchain() -> bool:
    rustc = shutil.which("rustc")
    if rustc is None or shutil.which("cargo") is None:
        print("[vityo] Rust 1.88.0 or newer (rustc and cargo) is required", file=sys.stderr)
        return False
    result = subprocess.run(
        [rustc, "--version"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    match = re.search(r"\brustc (\d+)\.(\d+)(?:\.(\d+))?", result.stdout)
    if result.returncode != 0 or match is None:
        print("[vityo] unable to identify the installed Rust compiler version", file=sys.stderr)
        return False
    version = tuple(int(part or 0) for part in match.groups())
    if version < (1, 88, 0):
        print("[vityo] Rust 1.88.0 or newer is required by the locked Agent dependencies", file=sys.stderr)
        return False
    if sys.platform.startswith("linux"):
        pkg_config = shutil.which("pkg-config")
        if pkg_config is None or subprocess.run(
            [pkg_config, "--exists", "openssl"],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode != 0:
            print(
                "[vityo] Linux Rust builds require OpenSSL development files and pkg-config (for example, libssl-dev and pkg-config)",
                file=sys.stderr,
            )
            return False
    return True


def _rust_coverage_cli_is_pinned(cargo: str) -> bool:
    result = subprocess.run(
        [cargo, "llvm-cov", "--version"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return (
        result.returncode == 0
        and result.stdout.strip() == f"cargo-llvm-cov {RUST_COVERAGE_CLI_VERSION}"
    )


def ensure_rust_coverage_tools(*, runner: Runner | None = None) -> bool:
    run = runner or run_command
    rustup = shutil.which("rustup")
    cargo = shutil.which("cargo")
    if rustup is None or cargo is None:
        print(
            "[vityo] Rust coverage requires rustup and Cargo for the selected Rust toolchain",
            file=sys.stderr,
        )
        return False

    print("[vityo] prepare pinned Rust coverage tools", flush=True)
    if run((rustup, "component", "add", "llvm-tools-preview"), ROOT, None) != 0:
        print(
            "[vityo] installing llvm-tools-preview for the selected Rust toolchain failed",
            file=sys.stderr,
        )
        return False

    executable = shutil.which("cargo-llvm-cov")
    if executable is not None and _rust_coverage_cli_is_pinned(cargo):
        return True

    install = (
        cargo,
        "install",
        "--locked",
        "--version",
        RUST_COVERAGE_CLI_VERSION,
        "--force",
        "cargo-llvm-cov",
    )
    if run(install, ROOT, None) != 0:
        print(
            f"[vityo] installing cargo-llvm-cov {RUST_COVERAGE_CLI_VERSION} failed",
            file=sys.stderr,
        )
        return False

    executable = shutil.which("cargo-llvm-cov")
    if executable is None or not _rust_coverage_cli_is_pinned(cargo):
        print(
            f"[vityo] cargo-llvm-cov {RUST_COVERAGE_CLI_VERSION} is unavailable after installation",
            file=sys.stderr,
        )
        return False
    return True


def run_command(
    argv: Sequence[str],
    cwd: Path = ROOT,
    environment: dict[str, str] | None = None,
) -> int:
    return subprocess.run(
        list(argv),
        cwd=cwd,
        env=environment,
        check=False,
    ).returncode


def run_commands(
    commands: Iterable[Command],
    *,
    runner: Runner = run_command,
) -> int:
    for command in commands:
        print(f"[vityo] {command.label}", flush=True)
        code = runner(command.argv, command.cwd, command.environment)
        if code != 0:
            return code
    return 0


def _python(script: str, *args: str) -> tuple[str, ...]:
    return (sys.executable, script, *args)


def _artifact_path(options: DeliveryOptions) -> Path:
    if options.artifact is not None:
        return options.artifact if options.artifact.is_absolute() else ROOT / options.artifact
    platform = options.platform or host_platform()
    versions_path = ROOT / "packaging/release-versions.json"
    versions = json.loads(versions_path.read_text(encoding="utf-8"))
    version = versions["platform_adapters"][platform]
    suffix = PACKAGE_SUFFIXES[platform]
    return ROOT / options.output_dir / f"vityo-nightly-{platform}-{version}{suffix}"


def _package_sidecar_path(artifact: Path) -> Path:
    return artifact.with_suffix(artifact.suffix + ".json")


def _load_package_candidate(path: Path, platform: str) -> dict[str, object]:
    if not path.is_file():
        raise ValueError("the built package candidate is missing")
    sidecar = _package_sidecar_path(path)
    if not sidecar.is_file():
        raise ValueError("the package candidate metadata is missing")
    payload = json.loads(sidecar.read_text(encoding="utf-8"))
    if (
        not isinstance(payload, dict)
        or payload.get("schema_version") != 1
        or payload.get("platform") != platform
        or payload.get("artifact") != path.name
    ):
        raise ValueError("the package candidate metadata does not match the artifact")
    return payload


def _product_matrix_commit(product: str) -> str:
    matrix = json.loads((ROOT / "toolchain/product-matrix.json").read_text(encoding="utf-8"))
    repositories = matrix.get("repositories")
    expected = repositories.get(product) if isinstance(repositories, dict) else None
    if not isinstance(expected, str) or len(expected) != 40:
        raise ValueError(f"the pinned {product} revision is unavailable")
    return expected


def _git_root(path: Path) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return Path(result.stdout.strip()).resolve()


def _git_head(path: Path) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def resolve_pinned_cli(
    product: str,
    explicit: str | None = None,
    *,
    environment: dict[str, str] | None = None,
) -> Path:
    env = os.environ if environment is None else environment
    checkout = (ROOT.parent / f"{product}-nightly").resolve()
    configured = explicit or env.get(f"VITYO_{product.upper()}_BIN") or env.get(product.upper())
    if configured:
        raw = Path(configured).expanduser()
        configured_path = raw if raw.is_absolute() else ROOT / raw
        if configured_path.is_file():
            candidate = configured_path.resolve()
        else:
            found = shutil.which(configured)
            if not found:
                raise ValueError(f"the configured {product} executable is unavailable")
            candidate = Path(found).resolve()
        if not validate_executable(product, candidate):
            raise ValueError(f"the configured {product} executable is not built from the pinned product-matrix revision")
        return candidate

    candidates = [
        checkout / "build/default/bin" / product,
        checkout / "build/default" / product,
        checkout / "build/bin" / product,
    ]
    if os.name == "nt":
        candidates.extend(
            (
                checkout / "build/default/bin" / f"{product}.exe",
                checkout / "build/default" / f"{product}.exe",
                checkout / "build/bin" / f"{product}.exe",
            )
        )
    build_root = checkout / "build/default"
    if build_root.is_dir():
        names = {product, f"{product}.exe"} if os.name == "nt" else {product}
        candidates.extend(
            sorted(
                (path.resolve() for path in build_root.rglob("*") if path.is_file() and path.name in names),
                key=lambda path: path.as_posix(),
            )
        )
    for candidate in candidates:
        if validate_executable(product, candidate):
            return candidate
    try:
        return provision(product)
    except ToolchainError as error:
        raise ValueError(str(error)) from error


def _git_mode_commands(options: DeliveryOptions) -> tuple[list[str], list[str]]:
    if options.mode == "ci":
        if not options.base or not options.revision_range:
            raise ValueError("CI delivery requires --base and --range from the event ref resolver")
        hygiene = _python(
            "scripts/repo-hygiene-gate.py",
            "--mode",
            "push",
            "--range",
            options.revision_range,
        )
        docs = ("bash", "scripts/docs-gate.sh", "--mode", "push", "--base", options.base)
    else:
        hygiene = _python("scripts/repo-hygiene-gate.py", "--mode", "tracked")
        docs = ("bash", "scripts/docs-gate.sh", "--mode", "worktree")
    return list(hygiene), list(docs)


def run_privacy_stage(options: DeliveryOptions, *, runner: Runner = run_command) -> int:
    try:
        hygiene, _ = _git_mode_commands(options)
    except ValueError as error:
        print(f"[vityo] privacy stage: {error}", file=sys.stderr)
        return 2
    return run_commands(
        (
            Command(
                "privacy scan",
                _python("scripts/vityo_privacy.py", "--report", "build/evidence/privacy.json"),
            ),
            Command("repository hygiene", tuple(hygiene)),
        ),
        runner=runner,
    )


def run_architecture_stage(options: DeliveryOptions, *, runner: Runner = run_command) -> int:
    try:
        _, docs = _git_mode_commands(options)
    except ValueError as error:
        print(f"[vityo] architecture stage: {error}", file=sys.stderr)
        return 2
    if not require_rust_toolchain():
        return 2
    commands = (
        Command("architecture model and generated views", _python("scripts/vityo_architecture.py", "--check")),
        Command("documentation and contributor contracts", tuple(docs)),
        Command("security baseline", _python("scripts/check_security_baseline.py")),
        Command("license policy", _python("scripts/check_license_policy.py")),
        Command("architecture boundaries", _python("scripts/check_architecture_boundaries.py")),
        Command("product boundaries", _python("scripts/check_product_line_boundaries.py")),
        Command("import boundaries", _python("scripts/import-boundary-gate.py")),
        Command("dependency policy", _python("scripts/dependency-policy-gate.py")),
        Command("supply-chain governance", _python("scripts/supply-chain-governance-gate.py")),
        Command(
            "release readiness static checks",
            _python("scripts/release-readiness-gate.py", "--flutter-dir", str(options.flutter_dir), "--skip-build"),
        ),
    )
    return run_commands(commands, runner=runner)


def _project_coverage_command(options: DeliveryOptions, *, collect_only: bool) -> tuple[str, ...]:
    evidence = options.evidence_dir
    evidence = evidence if evidence.is_absolute() else ROOT / evidence
    try:
        evidence_relative = evidence.resolve().relative_to(ROOT.resolve())
    except ValueError as error:
        raise ValueError("coverage evidence must stay inside the repository") from error
    args = [
        "scripts/project-coverage-gate.py",
        "--python-fail-under",
        "95",
        "--flutter-fail-under",
        "85",
        "--flutter-dir",
        str(options.flutter_dir),
        "--rust-coverage-dir",
        (evidence_relative / "rust-coverage").as_posix(),
        "--agent-receipt",
        (evidence_relative / "vityo-coding-agent-full.json").as_posix(),
        "--collect-only" if collect_only else "--report-only",
    ]
    return _python(*args)


def _run_language_fixture_gate(options: DeliveryOptions) -> int:
    try:
        styio = resolve_pinned_cli("styio", options.styio_bin)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"[vityo] language fixture stage: {error}", file=sys.stderr)
        return 2
    command = [
        "dart",
        "run",
        "tool/language_fixture_gate.dart",
        "--styio",
        str(styio),
        "--root",
        "test/fixtures/language_service",
        "--root",
        "test/fixtures/styio_language/syntax_contract",
    ]
    return run_command(command, ROOT / options.flutter_dir)


def _run_quality_suite(product: str, suite: str, *, receipt: str | None = None) -> int:
    args = ["scripts/vityo_quality.py", "--product", product, "--suite", suite]
    if receipt is not None:
        args.extend(("--receipt", receipt))
    return run_command(_python(*args))


def _run_product_acceptance(options: DeliveryOptions, styio: Path, pafio: Path) -> int:
    platform = options.platform
    evidence = options.evidence_dir / f"product-gate-{platform}.json"
    command = _python(
        "scripts/ecosystem-product-gate.py",
        "--platform",
        platform,
        "--styio-bin",
        str(styio),
        "--pafio-bin",
        str(pafio),
        "--output",
        str(evidence),
        "--require-real-matrix",
        "--json",
    )
    code = run_command(command)
    if code != 0:
        return code
    code = run_command(
        (
            "dart",
            "run",
            "tests/acceptance/vityo_app/trusted_desktop_styio_loop_acceptance_test.dart",
            "--report",
            str(evidence),
            "--platform",
            platform,
        ),
        ROOT,
    )
    if code != 0:
        return code

    pty_report = options.evidence_dir / f"native-pty-{platform}.json"
    code = run_command(
        _python(
            "scripts/run-native-pty-matrix.py",
            "--platform",
            platform,
            "--output",
            str(pty_report),
        )
    )
    if code != 0:
        return code

    try:
        styio_root = _git_root(resolve_pinned_cli("styio", options.styio_bin).parent)
        pafio_root = _git_root(resolve_pinned_cli("pafio", options.pafio_bin).parent)
        if styio_root is None or pafio_root is None:
            raise ValueError("product matrix checkouts are unavailable")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"[vityo] product matrix evidence: {error}", file=sys.stderr)
        return 2
    return run_command(
        _python(
            "scripts/record-product-matrix-evidence.py",
            "--platform",
            platform,
            "--vityo",
            ".",
            "--styio",
            str(styio_root),
            "--pafio",
            str(pafio_root),
            "--matrix",
            "toolchain/product-matrix.json",
            "--gate-report",
            str(evidence),
            "--pty-report",
            str(pty_report),
            "--output",
            str(options.evidence_dir / f"product-matrix-{platform}.json"),
        )
    )


def run_test_stage(options: DeliveryOptions, *, runner: Runner = run_command) -> int:
    platform = options.platform or host_platform()
    if platform not in PACKAGE_SUFFIXES:
        print("[vityo] test stage: unsupported host platform", file=sys.stderr)
        return 2
    if options.scope == "coverage":
        if not require_rust_toolchain():
            return 2
        if not ensure_rust_coverage_tools(runner=runner):
            return 2
        return runner(
            _project_coverage_command(options, collect_only=True),
            ROOT,
            None,
        )
    try:
        styio = resolve_pinned_cli("styio", options.styio_bin)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"[vityo] test stage: {error}", file=sys.stderr)
        return 2

    if not require_rust_toolchain():
        return 2
    if not ensure_rust_coverage_tools(runner=runner):
        return 2

    flutter = shutil.which("flutter")
    if flutter is None:
        print("[vityo] test stage: Flutter is not available", file=sys.stderr)
        return 2
    commands: list[Command] = [
        Command("Flutter analysis", (flutter, "analyze"), ROOT / options.flutter_dir),
        Command("Python, Flutter, Agent, and daemon test/coverage collection", _project_coverage_command(options, collect_only=True)),
    ]
    for suite in PORTABLE_IDE_SUITES:
        commands.append(
            Command(
                f"portable IDE suite: {suite}",
                tuple(_python("scripts/vityo_quality.py", "--product", "ide", "--suite", suite)),
            )
        )
    commands.extend(
        (
            Command("pinned Styio language fixtures", ("<language-fixtures>",)),
            Command("prototype governance", ("npm", "run", "governance"), ROOT / "prototype"),
            Command(
                "prototype editor self-test",
                ("npm", "run", "selftest:editor"),
                ROOT / "prototype",
                {**os.environ, "PYTHON_BIN": sys.executable, "VITYO_EDITOR_URL": "http://127.0.0.1:4180/editor"},
            ),
        )
    )
    if options.mode == "ci":
        if platform in {"linux", "macos"}:
            prefix: tuple[str, ...] = ("xvfb-run", "-a") if platform == "linux" else ()
            commands.append(
                Command(
                    f"native desktop integration: {platform}",
                    (*prefix, *_python("scripts/vityo_quality.py", "--product", "ide", "--suite", "native-desktop")),
                )
            )
        if platform == "macos":
            commands.append(
                Command(
                    "macOS native UI integration",
                    tuple(_python("scripts/vityo_quality.py", "--product", "ide", "--suite", "macos-native-ui")),
                )
            )

    code = run_commands(commands, runner=runner)
    if code != 0:
        return code
    code = _run_language_fixture_gate(options)
    if code != 0:
        return code

    product_gate_required = options.mode == "ci" or any(
        value in {"1", "true", "yes", "on"}
        for value in (os.environ.get("CI", "").lower(), os.environ.get("GITHUB_ACTIONS", "").lower(), os.environ.get("VITYO_PRODUCT_GATE", "").lower())
    )
    if product_gate_required:
        try:
            pafio = resolve_pinned_cli("pafio", options.pafio_bin)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            print(f"[vityo] test stage: {error}", file=sys.stderr)
            return 2
        return _run_product_acceptance(dataclasses.replace(options, platform=platform), styio, pafio)
    return 0


def run_coverage_stage(options: DeliveryOptions, *, runner: Runner = run_command) -> int:
    return runner(
        _project_coverage_command(options, collect_only=False),
        ROOT,
        None,
    )


def _current_target(platform: str) -> bool:
    return platform == host_platform()


def run_build_stage(options: DeliveryOptions, *, runner: Runner = run_command) -> int:
    platform = options.platform or host_platform()
    if not _current_target(platform):
        print(f"[vityo] build stage: {platform} packages require a matching host", file=sys.stderr)
        return 2
    if not require_rust_toolchain():
        return 2
    if not options.notices_validated:
        code = runner(_python("scripts/check_license_policy.py"), ROOT, None)
        if code != 0:
            return code
    flutter = shutil.which("flutter")
    if flutter is None:
        print("[vityo] build stage: Flutter is not available", file=sys.stderr)
        return 2
    app_dir = ROOT / options.flutter_dir
    code = runner((flutter, *PLATFORM_BUILD_COMMANDS[platform]), app_dir, None)
    if code != 0:
        return code
    code = runner(
        _python("scripts/package-nightly.py", "--platform", platform, "--output-dir", str(options.output_dir)),
        ROOT,
        None,
    )
    if code != 0:
        return code
    artifact = _artifact_path(dataclasses.replace(options, platform=platform))
    try:
        _load_package_candidate(artifact, platform)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"[vityo] build stage: {error}", file=sys.stderr)
        return 2
    return 0


def default_install_root(platform: str, mode: str) -> Path:
    if mode == "ci":
        raise ValueError("CI installation requires an explicit isolated --install-root")
    if platform == "windows":
        local_app_data = os.environ.get("LOCALAPPDATA")
        if not local_app_data:
            raise ValueError("LOCALAPPDATA is unavailable for the per-user Windows installation")
        return Path(local_app_data) / "Programs" / "Vityo-Nightly"
    if platform == "macos":
        return Path.home() / "Applications" / "Vityo.app"
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    return data_home / "vityo-nightly"


def application_root(install_root: Path, platform: str) -> Path:
    if platform == "linux":
        return install_root / "opt/vityo"
    return install_root


def _replace_install_tree(staged: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    rollback = destination.with_name(destination.name + ".rollback")
    if rollback.exists():
        raise ValueError("a prior install transaction needs manual recovery")
    moved_previous = False
    activated = False
    try:
        if destination.exists():
            destination.replace(rollback)
            moved_previous = True
        staged.replace(destination)
        activated = True
        if moved_previous:
            shutil.rmtree(rollback)
    except Exception:
        if activated and destination.exists():
            shutil.rmtree(destination)
        if moved_previous and rollback.exists():
            rollback.replace(destination)
        raise


def _install_linux(artifact: Path, install_root: Path) -> None:
    if shutil.which("dpkg-deb") is None:
        raise ValueError("dpkg-deb is required to install the Linux package per-user")
    install_root = install_root.expanduser().resolve()
    with tempfile.TemporaryDirectory(prefix="vityo-install-") as temporary:
        temp_root = Path(temporary)
        extracted = temp_root / "package-root"
        extracted.mkdir()
        result = subprocess.run(
            ["dpkg-deb", "--extract", str(artifact), str(extracted)],
            cwd=ROOT,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError("dpkg-deb could not extract the package candidate")
        if not (extracted / "opt/vityo/vityo_app").is_file():
            raise ValueError("the Linux package does not contain the Vityo application")
        staged = install_root.with_name(install_root.name + ".installing")
        if staged.exists():
            raise ValueError("a prior install transaction needs manual recovery")
        shutil.copytree(extracted, staged)
        _replace_install_tree(staged, install_root)


def _install_windows(artifact: Path, install_root: Path) -> None:
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if powershell is None:
        raise ValueError("PowerShell is required to install the Windows package")
    with tempfile.TemporaryDirectory(prefix="vityo-install-") as temporary:
        stage = Path(temporary) / "package"
        stage.mkdir()
        with zipfile.ZipFile(artifact) as package:
            package.extractall(stage)
        installer = stage / "Vityo-Nightly" / "install.ps1"
        if not installer.is_file():
            raise ValueError("the Windows package installer is missing")
        result = subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-File",
                str(installer),
                "-Source",
                str(installer.parent),
                "-Destination",
                str(install_root),
            ],
            cwd=ROOT,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError("the Windows package installer failed")


def _install_macos(artifact: Path, install_root: Path) -> None:
    if shutil.which("hdiutil") is None:
        raise ValueError("hdiutil is required to install the macOS package")
    with tempfile.TemporaryDirectory(prefix="vityo-dmg-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        result = subprocess.run(
            ["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(artifact)],
            cwd=ROOT,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError("the macOS disk image could not be mounted")
        try:
            apps = list(mount.glob("*.app"))
            if len(apps) != 1:
                raise ValueError("the macOS disk image must contain one application bundle")
            install_root = install_root.expanduser().resolve()
            staged = install_root.with_name(install_root.name + ".installing")
            if staged.exists():
                raise ValueError("a prior install transaction needs manual recovery")
            shutil.copytree(apps[0], staged)
            _replace_install_tree(staged, install_root)
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], cwd=ROOT, check=False)


def run_install_stage(options: DeliveryOptions) -> int:
    platform = options.platform or host_platform()
    if not _current_target(platform):
        print(f"[vityo] install stage: {platform} packages require a matching host", file=sys.stderr)
        return 2
    artifact = _artifact_path(dataclasses.replace(options, platform=platform))
    try:
        _load_package_candidate(artifact, platform)
        install_root = options.install_root or default_install_root(platform, options.mode)
        if platform == "linux":
            _install_linux(artifact, install_root)
        elif platform == "windows":
            _install_windows(artifact, install_root)
        else:
            _install_macos(artifact, install_root)
        app_root = application_root(install_root, platform)
        executable = app_root / PACKAGE_EXECUTABLES[platform]
        agent = app_root / AGENT_PACKAGE_PATHS[platform]
        daemon = app_root / DAEMON_PACKAGE_PATHS[platform]
        if not executable.is_file() or not agent.is_file() or not daemon.is_file():
            raise ValueError("the installed package is missing a required executable component")
        if platform != "windows" and any(
            not os.access(component, os.X_OK) for component in (agent, daemon)
        ):
            raise ValueError("an installed Rust executable component is not executable")
        if options.mode == "ci":
            code = run_command(
                _python(
                    "scripts/vityod-desktop-matrix-gate.py",
                    "--platform",
                    platform,
                    "--application-root",
                    str(app_root),
                )
            )
            if code != 0:
                return code
        agent_version = subprocess.run(
            [str(agent), "--version"],
            cwd=app_root,
            check=False,
        )
        if agent_version.returncode != 0:
            raise RuntimeError("the installed Coding Agent executable could not report its version")
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"[vityo] install stage: {error}", file=sys.stderr)
        return 2


def _startup_evidence_path(options: DeliveryOptions) -> Path:
    return ROOT / options.evidence_dir / f"startup-{options.platform}.json"


def _validate_startup_evidence(path: Path, *, platform: str, candidate: str) -> None:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or set(payload) != {
        "schema_version",
        "candidate",
        "platform",
        "launched",
        "first_frame",
    }:
        raise ValueError("startup probe returned an invalid report shape")
    if payload.get("schema_version") != 1:
        raise ValueError("startup probe schema is unsupported")
    if payload.get("candidate") != candidate or payload.get("platform") != platform:
        raise ValueError("startup probe does not identify the installed candidate")
    if payload.get("launched") is not True or payload.get("first_frame") is not True:
        raise ValueError("the installed client did not complete startup")


def _run_ci_startup_probe(
    options: DeliveryOptions,
    *,
    app_root: Path,
    candidate: str,
) -> int:
    executable = app_root / PACKAGE_EXECUTABLES[options.platform]
    evidence = _startup_evidence_path(options)
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.unlink(missing_ok=True)
    arguments = (
        "--vityo-startup-probe",
        "--vityo-candidate",
        candidate,
        "--vityo-evidence-file",
        str(evidence),
    )
    if options.platform == "linux":
        xvfb = shutil.which("xvfb-run")
        if xvfb is None:
            print("[vityo] launch stage: xvfb-run is required for the Linux CI startup probe", file=sys.stderr)
            return 2
        command = [xvfb, "-a", str(executable), *arguments]
    elif options.platform == "macos":
        opener = shutil.which("open")
        if opener is None:
            print("[vityo] launch stage: macOS open is unavailable", file=sys.stderr)
            return 2
        command = [opener, "-W", str(app_root), "--args", *arguments]
    else:
        command = [str(executable), *arguments]
    code = run_command(command, app_root, None)
    if code != 0:
        return code
    try:
        _validate_startup_evidence(evidence, platform=options.platform, candidate=candidate)
        from importlib.util import module_from_spec, spec_from_file_location

        path = ROOT / "packaging/vityo/desktop_delivery.py"
        spec = spec_from_file_location("vityo_desktop_delivery", path)
        if spec is None or spec.loader is None:
            raise ValueError("desktop delivery evidence checker is unavailable")
        module = module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        lane = module.evaluate_lane(
            platform=options.platform,
            host_platform=host_platform(),
            expected_candidate=candidate,
            evidence=json.loads(evidence.read_text(encoding="utf-8")),
        )
        if lane.status != "passed":
            raise ValueError(lane.reason)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"[vityo] launch stage: {error}", file=sys.stderr)
        return 2
    return 0


def run_launch_stage(options: DeliveryOptions) -> int:
    platform = options.platform or host_platform()
    if not _current_target(platform):
        print(f"[vityo] launch stage: {platform} candidates require a matching host", file=sys.stderr)
        return 2
    try:
        install_root = options.install_root or default_install_root(platform, options.mode)
    except ValueError as error:
        print(f"[vityo] launch stage: {error}", file=sys.stderr)
        return 2
    app_root = application_root(install_root.expanduser(), platform)
    executable = app_root / PACKAGE_EXECUTABLES[platform]
    if not executable.is_file():
        print("[vityo] launch stage: the installed Vityo executable is missing", file=sys.stderr)
        return 2
    candidate_path = _artifact_path(dataclasses.replace(options, platform=platform))
    try:
        _load_package_candidate(candidate_path, platform)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"[vityo] launch stage: {error}", file=sys.stderr)
        return 2
    if options.mode == "ci":
        return _run_ci_startup_probe(
            dataclasses.replace(options, platform=platform),
            app_root=app_root,
            candidate=candidate_path.name,
        )
    try:
        if platform == "macos":
            opener = shutil.which("open")
            if opener is None:
                raise ValueError("macOS open is unavailable")
            subprocess.Popen([opener, "-a", str(install_root.expanduser())], cwd=ROOT)
        else:
            subprocess.Popen([str(executable)], cwd=app_root)
    except (OSError, ValueError) as error:
        print(f"[vityo] launch stage: {error}", file=sys.stderr)
        return 2
    print("[vityo] opened installed candidate")
    return 0


def run_stage(stage: str, options: DeliveryOptions) -> int:
    handlers = {
        "privacy": run_privacy_stage,
        "architecture": run_architecture_stage,
        "test": run_test_stage,
        "coverage": run_coverage_stage,
        "build": run_build_stage,
        "install": run_install_stage,
        "launch": run_launch_stage,
    }
    try:
        return handlers[stage](options)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"[vityo] {stage} stage: {error}", file=sys.stderr)
        return 2


def run_delivery(
    options: DeliveryOptions,
    *,
    stage_runner: Callable[[str, DeliveryOptions], int] = run_stage,
) -> int:
    stage_options = options
    for stage in DELIVERY_STAGES:
        print(f"[vityo] stage: {stage}", flush=True)
        code = stage_runner(stage, stage_options)
        if code != 0:
            print(f"[vityo] delivery stopped at {stage} (exit {code})", file=sys.stderr)
            return code
        if stage == "architecture":
            stage_options = dataclasses.replace(stage_options, notices_validated=True)
    return 0


def _add_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--mode", choices=("local", "ci"), default="local")
    parser.add_argument("--platform", choices=("linux", "windows", "macos"))
    parser.add_argument("--base", help="Resolved target ref for CI documentation checks")
    parser.add_argument("--range", dest="revision_range", help="Resolved source revision range for CI hygiene")
    parser.add_argument("--flutter-dir", type=Path, default=FLUTTER_DIR)
    parser.add_argument("--styio-bin")
    parser.add_argument("--pafio-bin")
    parser.add_argument("--output-dir", type=Path, default=Path("build/nightly"))
    parser.add_argument("--evidence-dir", type=Path, default=Path("build/evidence"))
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--install-root", type=Path)
    parser.add_argument("--scope", choices=("full", "coverage"), default="full")


def options_from_args(args: argparse.Namespace) -> DeliveryOptions:
    return DeliveryOptions(
        mode=args.mode,
        platform=args.platform or host_platform(),
        base=args.base,
        revision_range=args.revision_range,
        flutter_dir=args.flutter_dir,
        styio_bin=args.styio_bin,
        pafio_bin=args.pafio_bin,
        output_dir=args.output_dir,
        evidence_dir=args.evidence_dir,
        artifact=args.artifact,
        install_root=args.install_root,
        scope=args.scope,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build, install, and launch Vityo through one tested delivery path.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in (*DELIVERY_STAGES, "deliver"):
        child = subparsers.add_parser(name)
        _add_options(child)
    args = parser.parse_args(argv)
    options = options_from_args(args)
    if args.command == "deliver":
        return run_delivery(options)
    return run_stage(args.command, options)


if __name__ == "__main__":
    raise SystemExit(main())
