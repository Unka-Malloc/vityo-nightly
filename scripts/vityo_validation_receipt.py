"""Build and atomically persist current-invocation validation reports."""

from __future__ import annotations

import json
import os
import pathlib
import tempfile
from collections.abc import Mapping, Sequence


REQUIRED_IDE_REQUIREMENTS = tuple(
    f"REQ-IDE-{index:03d}" for index in range(1, 9)
)
SUPPORTED_HOST_PLATFORMS = ("windows", "macos", "linux")
MAX_REPORT_BYTES = 256 * 1024


class ValidationReportError(ValueError):
    """Stable, safe error raised while building a validation report."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code


def validate_full_suite_plan(plan: Sequence[Mapping[str, object]]) -> None:
    requirements: list[str] = []
    suites: list[str] = []
    runners: list[str] = []
    for item in plan:
        requirement = item.get("requirement")
        suite = item.get("suite")
        runner = item.get("runner")
        if not all(isinstance(value, str) for value in (requirement, suite, runner)):
            raise ValidationReportError(
                "invalid_requirement_mapping",
                "each full-suite entry requires requirement, suite, and runner names",
            )
        requirements.append(requirement)
        suites.append(suite)
        runners.append(runner)
    if (
        tuple(requirements) != REQUIRED_IDE_REQUIREMENTS
        or len(set(suites)) != len(suites)
        or len(set(runners)) != len(runners)
        or any(not value.strip() for value in (*suites, *runners))
    ):
        raise ValidationReportError(
            "invalid_requirement_mapping",
            "full-suite mapping must contain each IDE requirement once",
        )


def _validate_ide_outcomes(
    outcomes: Mapping[str, Mapping[str, object]],
) -> None:
    if tuple(outcomes) != REQUIRED_IDE_REQUIREMENTS:
        raise ValidationReportError(
            "missing_requirement_outcome",
            "report must contain every IDE requirement in canonical order",
        )
    for requirement, outcome in outcomes.items():
        if outcome.get("status") not in {"passed", "failed", "not-run"}:
            raise ValidationReportError(
                "invalid_requirement_outcome",
                f"{requirement} has no truthful execution status",
            )
        for key in ("suite", "runner"):
            value = outcome.get(key)
            if not isinstance(value, str) or not value.strip():
                raise ValidationReportError(
                    "invalid_requirement_outcome",
                    f"{requirement} has no {key} reference",
                )
        duration = outcome.get("duration_ms")
        if type(duration) is not int or duration < 0:
            raise ValidationReportError(
                "invalid_requirement_outcome",
                f"{requirement} has no valid execution duration",
            )


def build_ide_report(
    *,
    platform: str,
    outcomes: Mapping[str, Mapping[str, object]],
    failure_code: str | None = None,
) -> dict[str, object]:
    if not isinstance(platform, str) or not platform.strip():
        raise ValidationReportError("invalid_platform", "host platform is missing")
    _validate_ide_outcomes(outcomes)
    passed = all(outcome["status"] == "passed" for outcome in outcomes.values())
    if not passed and failure_code is None:
        failure_code = next(
            (
                str(outcome["failure_code"])
                for outcome in outcomes.values()
                if outcome.get("failure_code")
            ),
            "suite_failed",
        )
    return {
        "schema_version": 1,
        "product": "vityo",
        "suite": "full",
        "status": "passed" if passed else "failed",
        "failure_code": None if passed else failure_code,
        "platform": platform,
        "requirements": {
            requirement: dict(outcome)
            for requirement, outcome in outcomes.items()
        },
    }


def write_report_atomic(
    destination: pathlib.Path,
    payload: Mapping[str, object],
) -> None:
    encoded = (
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
    )
    if len(encoded) > MAX_REPORT_BYTES:
        raise ValidationReportError(
            "report_too_large",
            "validation report exceeds the bounded artifact size",
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: pathlib.Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as handle:
            temporary_path = pathlib.Path(handle.name)
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, destination)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()
