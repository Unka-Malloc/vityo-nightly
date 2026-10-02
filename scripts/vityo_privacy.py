#!/usr/bin/env python3
"""Scan repository text for credentials and personal home-directory paths.

Only repo-relative locations and redacted categories leave the scanner. Matched
values and source-line excerpts are never included in console or JSON output.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]

EXCLUDED_PARTS = {
    ".dart_tool",
    ".git",
    ".pytest_cache",
    ".ruff_cache",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "target",
}
EXCLUDED_PREFIXES = ("products/vityo_app/test/failures/",)
EXCLUDED_SUFFIXES = {".log", ".trace", ".jsonl"}
PLACEHOLDER_HOME_ACCOUNTS = {"example", "fixture", "username", "yourname"}
PLACEHOLDER_SECRET_VALUES = {"0", "x"}
PLACEHOLDER_MARKERS = ("example", "placeholder", "synthetic fixture")
# Intentional examples are tied to an exact source owner, detection rule, and
# semantic source marker. This preserves useful redaction/path fixtures without
# exempting an entire directory or relying on fragile line numbers.
INTENTIONAL_FIXTURE_RULES: tuple[
    tuple[str, str, re.Pattern[str], str], ...
] = (
    (
        "docs/governance/SECURITY-AND-SUPPLY-CHAIN.md",
        "Unix home-directory path",
        re.compile(r"Pattern-based redaction for:.*POSIX home paths"),
        "The security specification documents Unix path-redaction coverage.",
    ),
    (
        "docs/governance/SECURITY-AND-SUPPLY-CHAIN.md",
        "Windows user-profile path",
        re.compile(r"Pattern-based redaction for:.*Windows user paths"),
        "The security specification documents Windows path-redaction coverage.",
    ),
    (
        "products/vityo_app/test/extension_marketplace_test.dart",
        "Windows user-profile path",
        re.compile(r"homePath\s*:\s*r?['\"]C:\\Users\\[^\\]+\\"),
        "Injected platform facts use a synthetic root for marketplace behavior.",
    ),
    (
        "products/vityo_app/test/file_system_manager_test.dart",
        "Windows user-profile path",
        re.compile(r"normalizePath\(r['\"]C:\\Users\\[^\\]+\\app\\m\.styio"),
        "A synthetic Windows path exercises drive and dot-dot normalization.",
    ),
    (
        "products/vityo_app/test/foundation_test.dart",
        "Unix home-directory path",
        re.compile(r"homePath\s*:\s*['\"]/(?:home|Users)/[^/'\"]+['\"]"),
        "Injected ResourceFacts use a synthetic home root for resource mapping.",
    ),
    (
        "products/vityo_app/test/foundation_test.dart",
        "Unix home-directory path",
        re.compile(r"/\.local/share/vityo/data/platform-context"),
        "An expected app-data path in the ResourceFacts mapping fixture.",
    ),
    (
        "products/vityo_app/test/foundation_test.dart",
        "Unix home-directory path",
        re.compile(r"/\.cache/vityo/workspace-cache/workspace/demo_workspace/language-index"),
        "An expected workspace-cache path in the ResourceFacts mapping fixture.",
    ),
    (
        "products/vityo_app/test/foundation_test.dart",
        "Unix home-directory path",
        re.compile(r"ResourceFacts\.linuxDebianArm\(homePath:"),
        "Injected ResourceFacts use a synthetic home root for persistence coverage.",
    ),
    (
        "products/vityo_app/test/platform_context_test.dart",
        "Windows user-profile path",
        re.compile(r"['\"]homePath['\"]\s*:\s*r?['\"]C:\\Users\\[^\\]+"),
        "A serialized platform-context fixture contains an inert home-root field.",
    ),
    (
        "products/vityo_app/test/secret_redaction_test.dart",
        "literal authorization header",
        re.compile(r"Authorization\s*:\s*(?:Bearer|Basic)\s+"),
        "The log-redaction test supplies an inert synthetic header value.",
    ),
    (
        "products/vityo_app/test/secret_redaction_test.dart",
        "OpenAI-style API key",
        re.compile(r"OPENAI_API_KEY\s*=|isNot\(contains\(['\"]sk-"),
        "The log-redaction test supplies or checks an inert synthetic provider key.",
    ),
    (
        "products/vityo_app/test/secret_redaction_test.dart",
        "Unix home-directory path",
        re.compile(r"(?:['\"]path\s+/(?:home|Users)/|isNot\(contains\(|['\"]path['\"]\s*:)"),
        "The log-redaction test supplies or checks a synthetic Unix path field.",
    ),
    (
        "products/vityo_app/test/secret_redaction_test.dart",
        "Windows user-profile path",
        re.compile(r"windows [A-Z]:\\Users\\|isNot\(contains\(r?['\"][A-Z]:\\Users\\"),
        "The log-redaction test supplies or checks a synthetic Windows path field.",
    ),
    (
        "products/vityo_app/test/workspace_file_index_test.dart",
        "Unix home-directory path",
        re.compile(r"workspaceRoot:\s*['\"]/(?:home|Users)/[^/'\"]+['\"]"),
        "A generic virtual workspace root drives file-index fixture construction.",
    ),
    (
        "products/vityo_app/test/workspace_file_index_test.dart",
        "Unix home-directory path",
        re.compile(r"path:\s*['\"]/(?:home|Users)/[^/'\"]+/src/(?:main|utils)\.sty"),
        "A generic virtual file path drives file-index fixture construction.",
    ),
    (
        "products/vityo_app/test/system_compatibility_managers_test.dart",
        "Windows user-profile path",
        re.compile(r"['\"]USERPROFILE['\"]\s*:\s*r?['\"]C:\\Users\\[^\\]+"),
        "Injected system environment contains a synthetic user-profile path.",
    ),
    (
        "products/vityo_app/test/system_compatibility_managers_test.dart",
        "Windows user-profile path",
        re.compile(r"resource\.homePath,\s*r?['\"]C:\\Users\\[^\\]+"),
        "The expected resource model preserves the synthetic profile-root fixture.",
    ),
)
PUBLIC_LINUXBREW_TOOL_FILES = {
    "products/vityo_app/lib/src/view_ide/toolchain/native_compiler_toolchain_discovery_io.dart": {
        "clang",
        "clang++",
        "cmake",
        "ninja",
        "clangd",
        "lldb",
        "gdb",
        "clang-format",
        "clang-tidy",
        "ctest",
    },
    "products/vityo_app/lib/src/view_ide/toolchain/styio_toolchain_discovery_io.dart": {
        "styio",
    },
}

SECRET_RULES: tuple[tuple[str, str, re.Pattern[str]], ...] = (
    (
        "GitHub classic token",
        "credential",
        re.compile(r"\bghp_[A-Za-z0-9_]{30,}\b"),
    ),
    (
        "GitHub fine-grained token",
        "credential",
        re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    ),
    (
        "AWS access key identifier",
        "credential",
        re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    ),
    (
        "OpenAI-style API key",
        "credential",
        re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"),
    ),
    (
        "literal authorization header",
        "credential",
        re.compile(
            r"Authorization\s*:\s*(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{16,}",
            re.IGNORECASE,
        ),
    ),
    (
        "private key material",
        "private_key",
        re.compile(r"-----BEGIN (?:RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----"),
    ),
    (
        "provider API key assignment",
        "credential",
        re.compile(
            r"\b(?:OPENAI|ANTHROPIC)_API_KEY\s*[:=]\s*[\"']?"
            r"[A-Za-z0-9_-]{10,}",
            re.IGNORECASE,
        ),
    ),
)

HOME_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "Unix home-directory path",
        re.compile(
            r"(?<![\w.])/(?:Users|home)/(?P<account>[^/\s\\\"'<>]+)"
            r"(?=/|[\s\"'<>),;\]}]|$)"
        ),
    ),
    (
        "Windows user-profile path",
        re.compile(
            r"(?i)(?<![\w:])[A-Z]:\\Users\\(?P<account>[^\\/\s\"'<>]+)"
            r"(?=\\|[\s\"'<>),;\]}]|$)"
        ),
    ),
)
SCAN_RULES = (
    *((name, category, pattern) for name, category, pattern in SECRET_RULES),
    *((name, "home_path", pattern) for name, pattern in HOME_RULES),
)


@dataclass(frozen=True)
class PrivacyFinding:
    path: str
    line: int
    rule: str
    category: str
    context: str
    classification: str
    judgement_basis: str
    impact: str
    handling: str

    def to_json(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class PrivacyReport:
    root: Path
    scanned_files: int
    findings: tuple[PrivacyFinding, ...]
    errors: tuple[str, ...] = ()

    @property
    def ok(self) -> bool:
        return not self.errors and not any(
            finding.classification == "confirmed_exposure"
            for finding in self.findings
        )

    def to_json(self) -> dict[str, object]:
        return {
            "ok": self.ok,
            "scanned_files": self.scanned_files,
            "findings": [finding.to_json() for finding in self.findings],
            "errors": list(self.errors),
        }


def _is_excluded(relative_path: str) -> bool:
    path = Path(relative_path)
    if path.suffix.lower() in EXCLUDED_SUFFIXES:
        return True
    if any(part in EXCLUDED_PARTS for part in path.parts):
        return True
    return any(relative_path.startswith(prefix) for prefix in EXCLUDED_PREFIXES)


def _git_candidates(root: Path) -> tuple[list[str] | None, str | None]:
    try:
        repo_root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return ([], "Unable to enumerate repository candidate files.") if (
            (root / ".git").exists()
        ) else (None, None)
    if repo_root.returncode != 0:
        return ([], "Unable to enumerate repository candidate files.") if (
            (root / ".git").exists()
        ) else (None, None)
    if Path(repo_root.stdout.strip()).resolve() != root.resolve():
        return None, None

    try:
        listing = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=root,
            check=False,
            capture_output=True,
        )
    except OSError:
        return [], "Unable to enumerate repository candidate files."
    if listing.returncode != 0:
        return [], "Unable to enumerate repository candidate files."
    candidates = [os.fsdecode(item) for item in listing.stdout.split(b"\0") if item]
    return candidates, None


def iter_candidate_files(root: Path) -> tuple[list[Path], list[str]]:
    root = root.resolve()
    if not root.is_dir():
        return [], ["Privacy scan root is unavailable."]

    candidates, error = _git_candidates(root)
    if error is not None:
        return [], [error]
    if candidates is None:
        candidates = [
            path.relative_to(root).as_posix()
            for path in root.rglob("*")
            if path.is_file() and not path.is_symlink()
        ]

    files: list[Path] = []
    for relative_path in sorted(set(candidates)):
        if _is_excluded(relative_path):
            continue
        path = root / relative_path
        if path.is_symlink() or not path.is_file():
            continue
        try:
            path.resolve().relative_to(root)
        except ValueError:
            continue
        files.append(path)
    return files, []


def _placeholder_secret(match: re.Match[str], line: str) -> bool:
    value = re.split(r"[:=]", match.group(0), maxsplit=1)[-1].strip(" \t\"'")
    if value.startswith("sk-"):
        value = value[3:]
    value = value.removeprefix("proj-")
    return (
        len(value) >= 20
        and len(set(value.lower())) == 1
        and value[0].lower() in PLACEHOLDER_SECRET_VALUES
        and any(marker in line.lower() for marker in PLACEHOLDER_MARKERS)
    )


def _finding(
    *,
    path: str,
    line_number: int,
    rule: str,
    category: str,
    line: str,
    match: re.Match[str],
) -> PrivacyFinding:
    fixture_reason = next(
        (
            reason
            for fixture_path, fixture_rule, marker, reason in INTENTIONAL_FIXTURE_RULES
            if fixture_path == path and fixture_rule == rule and marker.search(line)
        ),
        None,
    )
    if fixture_reason is not None:
        fixture_category = "synthetic privacy-test/path fixture"
        return PrivacyFinding(
            path=path,
            line=line_number,
            rule=rule,
            category=fixture_category,
            context="[fixture value redacted]",
            classification="false_positive",
            judgement_basis=fixture_reason,
            impact="The value is a deterministic test input, not user or service data.",
            handling="Retain this exact fixture exception with its focused test rationale.",
        )

    if category == "home_path":
        account = match.groupdict().get("account", "").casefold()
        tool = line.rsplit("/", 1)[-1].strip(" \t\"',;)")
        if (
            path in PUBLIC_LINUXBREW_TOOL_FILES
            and account == "linuxbrew"
            and ".linuxbrew/bin/" in line
            and tool in PUBLIC_LINUXBREW_TOOL_FILES[path]
        ):
            return PrivacyFinding(
                path=path,
                line=line_number,
                rule=rule,
                category="public Linuxbrew toolchain-prefix convention",
                context="[toolchain path redacted]",
                classification="false_positive",
                judgement_basis=(
                    "This exact tool-discovery source lists the conventional "
                    "system Linuxbrew prefix for one of its known executable names."
                ),
                impact="The shared package-manager account name does not identify a user workspace.",
                handling=(
                    "Keep this narrow discovery entry; other installations remain "
                    "resolved through PATH or explicit toolchain configuration."
                ),
            )
        if account in PLACEHOLDER_HOME_ACCOUNTS:
            return PrivacyFinding(
                path=path,
                line=line_number,
                rule=rule,
                category="generic home-path placeholder",
                context="[home path redacted]",
                classification="false_positive",
                judgement_basis=(
                    "The account component is an exact generic placeholder "
                    "reserved for examples, not a local identity."
                ),
                impact="No personal account or workstation location is exposed.",
                handling="Keep the generic placeholder; do not replace it with a local path.",
            )
        return PrivacyFinding(
            path=path,
            line=line_number,
            rule=rule,
            category="personal home-directory path",
            context="[home path redacted]",
            classification="confirmed_exposure",
            judgement_basis=(
                "The source contains an absolute home path with a non-placeholder "
                "account component."
            ),
            impact="May disclose a personal account name and workstation layout.",
            handling=(
                "Replace it with a repository-relative path or explicit runtime "
                "configuration; remove the personal value from maintained source."
            ),
        )

    if _placeholder_secret(match, line):
        return PrivacyFinding(
            path=path,
            line=line_number,
            rule=rule,
            category="inert credential placeholder",
            context="[credential redacted]",
            classification="false_positive",
            judgement_basis=(
                "The matched value is a repeated-character dummy explicitly "
                "labelled as an example or fixture."
            ),
            impact="The fixture cannot authenticate to an external service.",
            handling="Keep only the inert labelled fixture; never use a real credential.",
        )
    category_label = {
        "private_key": "private-key material",
        "credential": "credential-like value",
    }.get(category, "sensitive value")
    return PrivacyFinding(
        path=path,
        line=line_number,
        rule=rule,
        category=category_label,
        context="[sensitive value redacted]",
        classification="confirmed_exposure",
        judgement_basis=(
            "The text matches a high-signal credential or private-key rule; "
            "no exact inert-placeholder rule applies."
        ),
        impact="May permit unauthorized access or expose private signing material.",
        handling=(
            "Remove the value from maintained source and rotate/revoke it if it "
            "was a real credential."
        ),
    )


def scan_text(path: str, text: str) -> list[PrivacyFinding]:
    findings: list[PrivacyFinding] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        accepted_spans: list[tuple[int, int]] = []
        for rule, category, pattern in SCAN_RULES:
            for match in pattern.finditer(line):
                if any(
                    match.start() < end and start < match.end()
                    for start, end in accepted_spans
                ):
                    continue
                accepted_spans.append(match.span())
                findings.append(
                    _finding(
                        path=path,
                        line_number=line_number,
                        rule=rule,
                        category=category,
                        line=line,
                        match=match,
                    )
                )
    return findings


def scan_repository(root: Path = REPO_ROOT) -> PrivacyReport:
    root = root.resolve()
    paths, errors = iter_candidate_files(root)
    findings: list[PrivacyFinding] = []
    scanned = 0
    for path in paths:
        try:
            data = path.read_bytes()
        except OSError:
            errors.append("A repository candidate could not be read.")
            continue
        if b"\0" in data:
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        scanned += 1
        findings.extend(scan_text(path.relative_to(root).as_posix(), text))
    return PrivacyReport(root, scanned, tuple(findings), tuple(errors))


def format_finding(finding: PrivacyFinding) -> str:
    return (
        f"{finding.path}:{finding.line}: {finding.rule}; "
        f"{finding.classification}; {finding.context}"
    )


def format_summary(report: PrivacyReport) -> str:
    if report.errors:
        return "; ".join(report.errors)
    if not report.findings:
        return f"scanned {report.scanned_files} candidate text file(s); no findings"
    return "; ".join(format_finding(finding) for finding in report.findings)


def _write_report(report: PrivacyReport, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(report.to_json(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        type=Path,
        help="Write the redacted findings JSON inside the repository.",
    )
    args = parser.parse_args(argv)

    report = scan_repository(REPO_ROOT)
    if args.report is not None:
        destination = args.report
        if not destination.is_absolute():
            destination = REPO_ROOT / destination
        try:
            destination.resolve().relative_to(REPO_ROOT)
        except ValueError:
            print("[privacy] report destination must stay inside the repository", file=sys.stderr)
            return 2
        try:
            _write_report(report, destination)
        except OSError:
            print("[privacy] unable to write the redacted report", file=sys.stderr)
            return 2

    if report.errors:
        print("[privacy] FAILED: candidate enumeration/read error", file=sys.stderr)
        for error in report.errors:
            print(f"  - {error}", file=sys.stderr)
    elif report.ok:
        print(f"[privacy] OK: {format_summary(report)}")
    else:
        print("[privacy] FAILED: sensitive source findings", file=sys.stderr)
        for finding in report.findings:
            print(f"  - {format_finding(finding)}", file=sys.stderr)
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
