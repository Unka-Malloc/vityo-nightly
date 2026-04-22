#!/usr/bin/env python3
from __future__ import annotations

import argparse
import codecs
import fnmatch
import subprocess
import sys
from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MAX_FILE_BYTES = 20 * 1024 * 1024

FORBIDDEN_PATH_PARTS = {
    ".artifacts",
    ".dart_tool",
    ".gradle",
    ".next",
    ".nuxt",
    ".pytest_cache",
    ".ruff_cache",
    ".turbo",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "node_modules",
}

FORBIDDEN_FILE_SUFFIXES = (
    ".a",
    ".aar",
    ".apk",
    ".app",
    ".bin",
    ".class",
    ".dll",
    ".dmg",
    ".dylib",
    ".egg",
    ".exe",
    ".gz",
    ".ipa",
    ".jar",
    ".lib",
    ".nar",
    ".o",
    ".obj",
    ".out",
    ".pdb",
    ".pyc",
    ".pyo",
    ".rar",
    ".so",
    ".tar",
    ".tgz",
    ".war",
    ".whl",
    ".zip",
    ".7z",
)

ALLOWED_BINARY_GLOBS = (
    "docs/assets/*.gif",
    "docs/assets/*.jpeg",
    "docs/assets/*.jpg",
    "docs/assets/*.png",
    "docs/assets/*.svg",
    "docs/assets/*.webp",
    "docs/assets/**/*.gif",
    "docs/assets/**/*.jpeg",
    "docs/assets/**/*.jpg",
    "docs/assets/**/*.png",
    "docs/assets/**/*.svg",
    "docs/assets/**/*.webp",
    "frontend/styio_view_app/android/app/src/main/res/**/*.png",
    "frontend/styio_view_app/ios/Runner/Assets.xcassets/**/*.png",
    "frontend/styio_view_app/macos/Runner/Assets.xcassets/**/*.png",
    "frontend/styio_view_app/web/*.png",
    "frontend/styio_view_app/web/**/*.png",
    "frontend/styio_view_app/windows/runner/resources/*.ico",
)

REQUIRED_GITIGNORE_PATTERNS = (
    ".DS_Store",
    ".cursor/",
    ".idea/",
    ".vscode/",
    ".cache/",
    "__pycache__/",
    ".pytest_cache/",
    ".mypy_cache/",
    ".ruff_cache/",
    ".venv/",
    "venv/",
    "node_modules/",
    "build/",
    "build-*/",
    "tmp/",
    "*.tmp",
    "*.log",
    "docs/audit/defects/",
    "!docs/**/build/",
    "!docs/**/build/**",
    "!docs/**/build-*/",
    "!docs/**/build-*/**",
    "!docs/**/tmp/",
    "!docs/**/tmp/**",
    "!docs/**/*.tmp",
    "!docs/**/*.log",
    "!frontend/styio_view_app/test/**/build/",
    "!frontend/styio_view_app/test/**/build/**",
    "!frontend/styio_view_app/test/**/build-*/",
    "!frontend/styio_view_app/test/**/build-*/**",
    "!frontend/styio_view_app/test/**/tmp/",
    "!frontend/styio_view_app/test/**/tmp/**",
    "!frontend/styio_view_app/test/**/*.tmp",
    "!frontend/styio_view_app/test/**/*.log",
)

REQUIRED_DOC_REFERENCES = {
    Path("docs/README.md"): (
        "scripts/docs-index.py",
        "scripts/docs-lifecycle.py",
        "scripts/docs-audit.py",
    ),
    Path("docs/assets/workflow/REPO-HYGIENE.md"): (
        "scripts/repo-hygiene-gate.py",
        "scripts/delivery-gate.sh",
    ),
    Path("docs/teams/DOCS-DELIVERY-RUNBOOK.md"): (
        "scripts/repo-hygiene-gate.py",
        "scripts/docs-gate.sh",
        "scripts/delivery-gate.sh",
    ),
}


def run_git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
    )


def tracked_files() -> list[str]:
    proc = run_git("ls-files", "-z")
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "git ls-files failed")
    return [path for path in proc.stdout.split("\0") if path]


def staged_files() -> list[str]:
    proc = run_git("diff", "--cached", "--name-only", "--diff-filter=ACMR")
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "git diff --cached failed")
    return [line for line in proc.stdout.splitlines() if line]


def default_push_range() -> str:
    proc = run_git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    if proc.returncode == 0:
        return "@{upstream}..HEAD"
    return "HEAD"


def has_forbidden_path_part(rel_path: str) -> bool:
    return any(part in FORBIDDEN_PATH_PARTS for part in PurePosixPath(rel_path).parts)


def has_forbidden_file_suffix(rel_path: str) -> bool:
    return rel_path.lower().endswith(FORBIDDEN_FILE_SUFFIXES)


def is_allowed_binary(rel_path: str) -> bool:
    return any(fnmatch.fnmatchcase(rel_path, pattern) for pattern in ALLOWED_BINARY_GLOBS)


def is_binary_file(rel_path: str) -> bool:
    file_path = REPO_ROOT / rel_path
    sample = file_path.read_bytes()[:8192]
    if not sample:
        return False
    if b"\0" in sample:
        return True
    try:
        text = codecs.getincrementaldecoder("utf-8")().decode(sample, final=False)
    except UnicodeDecodeError:
        return True
    return any(ord(char) < 32 and char not in "\n\r\t\f\b" for char in text)


def check_gitignore() -> list[str]:
    gitignore = REPO_ROOT / ".gitignore"
    if not gitignore.exists():
        return [".gitignore is missing"]
    patterns = {
        line.strip()
        for line in gitignore.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    return [f".gitignore must include: {required}" for required in REQUIRED_GITIGNORE_PATTERNS if required not in patterns]


def check_doc_references() -> list[str]:
    errors: list[str] = []
    for relative_path, needles in REQUIRED_DOC_REFERENCES.items():
        path = REPO_ROOT / relative_path
        if not path.exists():
            errors.append(f"required documentation file is missing: {relative_path.as_posix()}")
            continue
        text = path.read_text(encoding="utf-8")
        for needle in needles:
            if needle not in text:
                errors.append(f"{relative_path.as_posix()} must document {needle}")
    return errors


def check_worktree_files(files: list[str], max_file_bytes: int) -> list[str]:
    errors: list[str] = []
    for rel_path in files:
        path = REPO_ROOT / rel_path
        if not path.exists():
            continue
        if rel_path.startswith("docs/audit/defects/"):
            errors.append(f"{rel_path}: active audit defect records must stay untracked")
            continue
        if has_forbidden_path_part(rel_path):
            errors.append(f"{rel_path}: contains forbidden generated/dependency path part")
            continue
        if has_forbidden_file_suffix(rel_path):
            errors.append(f"{rel_path}: uses forbidden generated/binary suffix")
            continue
        if path.is_file() and path.stat().st_size > max_file_bytes:
            errors.append(f"{rel_path}: file size {path.stat().st_size} bytes exceeds soft limit {max_file_bytes} bytes")
            continue
        if path.is_file() and is_binary_file(rel_path) and not is_allowed_binary(rel_path):
            errors.append(f"{rel_path}: unexpected binary file; add a narrow allowlist only if intentional")
    return errors


def check_push_history(rev_range: str, max_file_bytes: int) -> list[str]:
    rev_list = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "rev-list", "--objects", rev_range],
        check=True,
        text=True,
        capture_output=True,
    )
    if not rev_list.stdout.strip():
        return []
    batch = subprocess.run(
        [
            "git",
            "-C",
            str(REPO_ROOT),
            "cat-file",
            "--batch-check=%(objecttype) %(objectname) %(objectsize) %(rest)",
        ],
        input=rev_list.stdout,
        check=True,
        text=True,
        capture_output=True,
    )
    errors: list[str] = []
    for line in batch.stdout.splitlines():
        parts = line.split(" ", 3)
        if len(parts) != 4:
            continue
        object_type, _oid, object_size, rel_path = parts
        if object_type != "blob" or not rel_path:
            continue
        if rel_path.startswith("docs/audit/defects/"):
            errors.append(f"{rel_path}: appears in pushed history range {rev_range}; active audit defect records must stay untracked")
        if has_forbidden_path_part(rel_path):
            errors.append(f"{rel_path}: appears in pushed history range {rev_range} and contains a forbidden generated/dependency path part")
        if has_forbidden_file_suffix(rel_path):
            errors.append(f"{rel_path}: appears in pushed history range {rev_range} with a forbidden generated/binary suffix")
        try:
            size = int(object_size)
        except ValueError:
            continue
        if size > max_file_bytes:
            errors.append(f"{rel_path}: blob size {size} bytes in pushed history range {rev_range} exceeds soft limit {max_file_bytes} bytes")
    return errors


def print_report(header: str, errors: list[str]) -> int:
    if not errors:
        print(f"[repo-hygiene] {header}: OK")
        return 0
    print(f"[repo-hygiene] {header}: FAILED", file=sys.stderr)
    for error in sorted(set(errors)):
        print(f"  - {error}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Styio View repository hygiene gate")
    parser.add_argument("--mode", choices=("tracked", "staged", "push"), default="staged")
    parser.add_argument("--range", dest="rev_range", help="Explicit revision range for --mode push")
    parser.add_argument("--max-file-bytes", type=int, default=DEFAULT_MAX_FILE_BYTES)
    args = parser.parse_args()

    errors = check_gitignore()
    errors.extend(check_doc_references())

    if args.mode == "push":
        rev_range = args.rev_range or default_push_range()
        errors.extend(check_push_history(rev_range, args.max_file_bytes))
        return print_report(f"push range {rev_range}", errors)

    files = staged_files() if args.mode == "staged" else tracked_files()
    if not files:
        print(f"[repo-hygiene] {args.mode}: nothing to check")
        return 0
    errors.extend(check_worktree_files(files, args.max_file_bytes))
    return print_report(args.mode, errors)


if __name__ == "__main__":
    raise SystemExit(main())
