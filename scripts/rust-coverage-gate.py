#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = Path("build/evidence/rust-coverage")
PRODUCTS = {
    "coding-agent": {
        "manifest": Path("products/vityo_coding_agent/Cargo.toml"),
        "workspace_root": PurePosixPath("products/vityo_coding_agent"),
        "source_root": PurePosixPath("src"),
        "report": "coding-agent.lcov",
    },
    "vityod": {
        "manifest": Path("products/vityo_app/native/vityod/Cargo.toml"),
        "workspace_root": PurePosixPath("products/vityo_app/native/vityod"),
        "source_root": PurePosixPath("crates"),
        "report": "vityod.lcov",
    },
}


@dataclass(frozen=True)
class SourceCoverage:
    path: str
    found: int
    hit: int
    uncovered_lines: tuple[int, ...]


@dataclass(frozen=True)
class CoverageReport:
    sources: tuple[SourceCoverage, ...]
    found: int
    hit: int

    @property
    def percent(self) -> float:
        return 100.0 * self.hit / self.found

    @property
    def uncovered_count(self) -> int:
        return self.found - self.hit


@dataclass(frozen=True)
class RequiredModule:
    requirement: str
    source: PurePosixPath
    is_directory: bool


def report_path(product: str, output_dir: Path) -> Path:
    return output_dir / str(PRODUCTS[product]["report"])


def discard_report(path: Path) -> bool:
    try:
        path.unlink(missing_ok=True)
    except OSError:
        return False
    return True


def resolve_output_dir(raw: Path) -> Path:
    if raw.is_absolute() or ".." in raw.parts:
        raise ValueError("output directory must be a safe repository-relative path")
    output_dir = (ROOT / raw).resolve()
    try:
        output_dir.relative_to(ROOT.resolve())
    except ValueError as exc:
        raise ValueError("output directory must stay inside the repository") from exc
    return output_dir


def normalize_source_path(raw: str, product: str) -> str:
    product_info = PRODUCTS[product]
    slash_path = raw.replace("\\", "/")
    if (
        not slash_path
        or slash_path.startswith("/")
        or re.match(r"^[A-Za-z]:", slash_path)
    ):
        raise ValueError("coverage source path must be relative")

    source = PurePosixPath(slash_path)
    if ".." in source.parts or source.suffix != ".rs":
        raise ValueError("coverage source path is outside first-party Rust sources")
    parts = tuple(part for part in source.parts if part not in ("", "."))
    if not parts:
        raise ValueError("coverage source path is empty")

    workspace_root = product_info["workspace_root"]
    workspace_parts = workspace_root.parts
    if parts[: len(workspace_parts)] == workspace_parts:
        relative_parts = parts[len(workspace_parts) :]
    elif parts[0] == "products":
        raise ValueError("coverage source path belongs to another product")
    else:
        relative_parts = parts

    source_root = product_info["source_root"].parts
    if relative_parts[: len(source_root)] != source_root:
        raise ValueError("coverage source path is outside first-party Rust sources")
    normalized = PurePosixPath(*workspace_parts, *relative_parts)
    return normalized.as_posix()


def parse_module_requirement(raw: str) -> RequiredModule:
    requirement, separator, raw_source = raw.partition("=")
    if (
        not separator
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", requirement)
        or not raw_source
    ):
        raise ValueError("required module must use REQUIREMENT=src/path/ syntax")

    is_directory = raw_source.endswith("/")
    source = PurePosixPath(raw_source)
    if (
        source.is_absolute()
        or ".." in source.parts
        or source.suffix not in ("", ".rs")
        or source.parts[:1] != PRODUCTS["coding-agent"]["source_root"].parts
    ):
        raise ValueError("required module must stay under the Coding Agent src tree")
    if is_directory and source.suffix:
        raise ValueError("a required source directory must end with '/'")
    if not is_directory and source.suffix != ".rs":
        raise ValueError("a required source file must end with '.rs'")
    return RequiredModule(requirement, source, is_directory)


def _parse_nonnegative_int(value: str, *, field: str, record: int) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ValueError(
            f"LCOV {field} counter is malformed in source record {record}"
        ) from exc
    if parsed < 0:
        raise ValueError(f"LCOV {field} counter is negative in source record {record}")
    return parsed


def parse_lcov(text: str, product: str) -> tuple[CoverageReport, str]:
    if product not in PRODUCTS:
        raise ValueError("unknown Rust coverage product")

    output_lines: list[str] = []
    sources: list[SourceCoverage] = []
    seen_paths: set[str] = set()
    record: dict[str, object] | None = None
    record_number = 0

    def finish_record() -> None:
        nonlocal record, record_number
        if record is None or "source" not in record:
            raise ValueError("LCOV contains an empty or malformed source record")
        record_number += 1
        source_path = str(record["source"])
        line_hits = record["line_hits"]
        assert isinstance(line_hits, dict)
        found_value = record.get("found")
        hit_value = record.get("hit")
        if not isinstance(found_value, int) or not isinstance(hit_value, int):
            raise ValueError(f"LCOV line summary is missing in source record {record_number}")
        if found_value != len(line_hits):
            raise ValueError(f"LCOV line data is incomplete in source record {record_number}")
        actual_hits = sum(1 for hits in line_hits.values() if hits > 0)
        if hit_value != actual_hits or hit_value > found_value:
            raise ValueError(f"LCOV hit summary is inconsistent in source record {record_number}")
        if source_path in seen_paths:
            raise ValueError("LCOV contains a duplicate first-party source record")
        seen_paths.add(source_path)
        uncovered = tuple(sorted(line for line, hits in line_hits.items() if hits == 0))
        sources.append(SourceCoverage(source_path, found_value, hit_value, uncovered))
        record = None

    for line in text.splitlines():
        if line == "end_of_record":
            finish_record()
            output_lines.append(line)
        elif line.startswith("SF:"):
            if record is not None:
                raise ValueError("LCOV source record is not terminated")
            record = {"line_hits": {}}
            try:
                normalized_source = normalize_source_path(line[3:], product)
            except ValueError as exc:
                raise ValueError(
                    f"LCOV contains an unsafe source path in record {record_number + 1}"
                ) from exc
            record["source"] = normalized_source
            output_lines.append(f"SF:{normalized_source}")
        elif line.startswith("DA:"):
            if record is None:
                raise ValueError("LCOV line data appears outside a source record")
            fields = line[3:].split(",")
            if len(fields) not in (2, 3):
                raise ValueError(
                    f"LCOV line data is malformed in source record {record_number + 1}"
                )
            line_number = _parse_nonnegative_int(
                fields[0], field="DA line", record=record_number + 1
            )
            if line_number == 0:
                raise ValueError(
                    f"LCOV line number is invalid in source record {record_number + 1}"
                )
            hits = _parse_nonnegative_int(
                fields[1], field="DA hit", record=record_number + 1
            )
            line_hits = record["line_hits"]
            assert isinstance(line_hits, dict)
            if line_number in line_hits:
                raise ValueError(f"LCOV repeats a line in source record {record_number + 1}")
            line_hits[line_number] = hits
            output_lines.append(line)
        elif line.startswith("LF:") or line.startswith("LH:"):
            if record is None:
                raise ValueError("LCOV summary appears outside a source record")
            field = "found" if line.startswith("LF:") else "hit"
            if field in record:
                raise ValueError(
                    f"LCOV repeats a {field} summary in source record {record_number + 1}"
                )
            record[field] = _parse_nonnegative_int(
                line[3:], field=field, record=record_number + 1
            )
            output_lines.append(line)
        else:
            output_lines.append(line)

    if record is not None:
        raise ValueError("LCOV source record is missing end_of_record")
    if not sources:
        raise ValueError("LCOV report has no first-party Rust sources")
    found = sum(source.found for source in sources)
    hit = sum(source.hit for source in sources)
    if found <= 0:
        raise ValueError("LCOV report has no executable first-party Rust lines")
    if hit <= 0:
        raise ValueError("LCOV report has no executed first-party Rust lines")
    report = CoverageReport(tuple(sources), found, hit)
    normalized = "\n".join(output_lines)
    if text.endswith("\n"):
        normalized += "\n"
    return report, normalized


def validate_required_modules(
    report: CoverageReport,
    required_modules: list[RequiredModule],
) -> list[tuple[str, int, int, int]]:
    grouped: dict[str, list[RequiredModule]] = {}
    for module in required_modules:
        grouped.setdefault(module.requirement, []).append(module)

    results: list[tuple[str, int, int, int]] = []
    for requirement, modules in grouped.items():
        matched: dict[str, SourceCoverage] = {}
        for module in modules:
            prefix = module.source.as_posix()
            module_sources: list[SourceCoverage] = []
            for source in report.sources:
                relative = PurePosixPath(source.path).relative_to(
                    PRODUCTS["coding-agent"]["workspace_root"]
                )
                relative_text = relative.as_posix()
                if module.is_directory:
                    if relative_text.startswith(f"{prefix}/"):
                        module_sources.append(source)
                elif relative_text == prefix:
                    module_sources.append(source)
            if not module_sources:
                raise ValueError(
                    f"required module {requirement} source root is absent from the LCOV source set"
                )
            module_found = sum(source.found for source in module_sources)
            module_hit = sum(source.hit for source in module_sources)
            if module_found <= 0 or module_hit <= 0:
                raise ValueError(
                    f"required module {requirement} source root has no executed lines"
                )
            matched.update((source.path, source) for source in module_sources)
        found = sum(source.found for source in matched.values())
        hit = sum(source.hit for source in matched.values())
        uncovered = sum(len(source.uncovered_lines) for source in matched.values())
        results.append((requirement, hit, found, uncovered))
    return results


def selected_products(product: str) -> tuple[str, ...]:
    if product == "all":
        return tuple(PRODUCTS)
    return (product,)


def collect_product(
    product: str,
    output_dir: Path,
    required_modules: list[RequiredModule],
) -> int:
    info = PRODUCTS[product]
    manifest = ROOT / info["manifest"]
    lockfile = manifest.with_name("Cargo.lock")
    if not manifest.is_file() or not lockfile.is_file():
        print(
            f"Rust coverage inputs are missing for {product} "
            "(manifest and lock are required)",
            file=sys.stderr,
        )
        return 2

    if shutil.which("cargo") is None:
        print("cargo is required to collect Rust coverage", file=sys.stderr)
        return 2
    if shutil.which("cargo-llvm-cov") is None:
        print(
            "cargo-llvm-cov is required; install it through the maintained toolchain setup",
            file=sys.stderr,
        )
        return 2

    destination = report_path(product, output_dir)
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        print(f"Rust coverage output directory is unavailable for {product}", file=sys.stderr)
        return 2
    if not discard_report(destination):
        print(f"Existing Rust LCOV report cannot be replaced for {product}", file=sys.stderr)
        return 2
    command = [
        "cargo",
        "llvm-cov",
        "--manifest-path",
        info["manifest"].as_posix(),
        "--workspace",
        "--all-targets",
        "--locked",
        "--lcov",
        "--output-path",
        destination.relative_to(ROOT).as_posix(),
        "--remap-path-prefix",
    ]
    try:
        code = subprocess.run(command, cwd=ROOT, check=False).returncode
    except OSError:
        discard_report(destination)
        print(f"cargo llvm-cov could not start for {product}", file=sys.stderr)
        return 2
    if code != 0:
        discard_report(destination)
        return code

    try:
        raw_report = destination.read_text(encoding="utf-8")
        parsed, normalized = parse_lcov(raw_report, product)
        destination.write_text(normalized, encoding="utf-8")
    except OSError:
        discard_report(destination)
        print(f"Rust LCOV output is missing or unreadable for {product}", file=sys.stderr)
        return 2
    except (UnicodeError, ValueError) as exc:
        discard_report(destination)
        print(f"Rust LCOV collection failed for {product}: {exc}", file=sys.stderr)
        return 2
    try:
        module_results = (
            validate_required_modules(parsed, required_modules)
            if product == "coding-agent"
            else []
        )
    except ValueError as exc:
        print(f"Rust module coverage failed for {product}: {exc}", file=sys.stderr)
        return 2
    print_report(product, parsed, module_results=module_results)
    return 0


def evaluate_product(
    product: str,
    output_dir: Path,
    *,
    fail_under: float | None,
    required_modules: list[RequiredModule],
) -> int:
    source = report_path(product, output_dir)
    try:
        raw_report = source.read_text(encoding="utf-8")
        parsed, normalized = parse_lcov(raw_report, product)
        if raw_report != normalized:
            raise ValueError("LCOV source labels are not repository-relative")
        module_results = (
            validate_required_modules(parsed, required_modules)
            if product == "coding-agent"
            else []
        )
    except OSError:
        print(f"Rust LCOV report is missing or unreadable for {product}", file=sys.stderr)
        return 2
    except (UnicodeError, ValueError) as exc:
        print(f"Rust LCOV report is invalid for {product}: {exc}", file=sys.stderr)
        return 2

    print_report(product, parsed, module_results=module_results)
    if fail_under is not None and parsed.percent < fail_under:
        print(
            f"Rust line coverage for {product} is below the requested {fail_under:g}% floor",
            file=sys.stderr,
        )
        return 1
    return 0


def print_report(
    product: str,
    report: CoverageReport,
    *,
    module_results: list[tuple[str, int, int, int]],
) -> None:
    print(
        f"[rust-coverage] {product}: {report.percent:.2f}% lines "
        f"({report.hit}/{report.found}); {report.uncovered_count} uncovered "
        f"across {len(report.sources)} source files"
    )
    for requirement, hit, found, uncovered in module_results:
        print(
            f"[rust-coverage] {product} {requirement}: "
            f"{hit}/{found} executed lines; {uncovered} uncovered"
        )


def run_gate(
    *,
    product: str,
    output_dir: Path,
    collect: bool,
    report: bool,
    fail_under: float | None,
    required_modules: list[RequiredModule],
) -> int:
    if not collect and not report:
        print("Rust coverage collection or reporting must be selected", file=sys.stderr)
        return 2
    if fail_under is not None and not 0 < fail_under <= 100:
        print("--fail-under must be greater than 0 and at most 100", file=sys.stderr)
        return 2
    if product == "vityod" and required_modules:
        print("--require-module applies only to --product coding-agent or all", file=sys.stderr)
        return 2

    selected = selected_products(product)
    report_status = 0
    for item in selected:
        if collect:
            code = collect_product(
                item,
                output_dir,
                required_modules if item == "coding-agent" else [],
            )
            if code != 0:
                return code
        if report:
            code = evaluate_product(
                item,
                output_dir,
                fail_under=fail_under,
                required_modules=required_modules if item == "coding-agent" else [],
            )
            if code != 0 and report_status == 0:
                report_status = code
    return report_status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Collect or evaluate first-party Rust workspace line coverage."
    )
    parser.add_argument("--product", choices=("all", *PRODUCTS), default="all")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--fail-under", type=float)
    parser.add_argument(
        "--require-module",
        action="append",
        default=[],
        metavar="REQUIREMENT=SOURCE_ROOT",
        help="Require executed lines for a Coding Agent source file or directory; repeatable.",
    )
    phase = parser.add_mutually_exclusive_group(required=True)
    phase.add_argument(
        "--collect-only",
        action="store_true",
        help="Run each selected workspace test suite once and save an LCOV report.",
    )
    phase.add_argument(
        "--report-only",
        action="store_true",
        help="Evaluate existing LCOV reports without running tests.",
    )
    args = parser.parse_args(argv)

    try:
        output_dir = resolve_output_dir(args.output_dir)
        required_modules = [parse_module_requirement(value) for value in args.require_module]
    except ValueError as exc:
        parser.error(str(exc))

    return run_gate(
        product=args.product,
        output_dir=output_dir,
        collect=args.collect_only,
        report=args.report_only,
        fail_under=args.fail_under,
        required_modules=required_modules,
    )


if __name__ == "__main__":
    raise SystemExit(main())
