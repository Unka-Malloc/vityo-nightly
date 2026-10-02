"""Acceptance for host-bound, truthful desktop startup evidence."""

from __future__ import annotations

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]


def _load_delivery_module():
    path = ROOT / "packaging" / "vityo" / "desktop_delivery.py"
    spec = importlib.util.spec_from_file_location("desktop_delivery", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> None:
    delivery = _load_delivery_module()
    expected_candidate = "vityo-nightly-linux-0.1.0.deb"
    evidence = {
        "schema_version": 1,
        "candidate": expected_candidate,
        "platform": "linux",
        "launched": True,
        "first_frame": True,
    }

    passed = delivery.evaluate_lane(
        platform="linux",
        host_platform="linux",
        expected_candidate=expected_candidate,
        evidence=evidence,
    )
    assert passed.status == "passed"

    for invalid_evidence in (
        {**evidence, "schema_version": 2},
        {**evidence, "platform": "windows"},
        {**evidence, "candidate": "another-package.deb"},
        {key: value for key, value in evidence.items() if key != "candidate"},
        {**evidence, "launched": False},
        {**evidence, "first_frame": False},
        {key: value for key, value in evidence.items() if key != "first_frame"},
    ):
        result = delivery.evaluate_lane(
            platform="linux",
            host_platform="linux",
            expected_candidate=expected_candidate,
            evidence=invalid_evidence,
        )
        assert result.status == "failed"

    wrong_host = delivery.evaluate_lane(
        platform="linux",
        host_platform="windows",
        expected_candidate=expected_candidate,
        evidence=evidence,
    )
    assert wrong_host.status == "blocked"

    workflow = (
        ROOT / ".github" / "workflows" / "local-ci-gate.yml"
    ).read_text(encoding="utf-8")
    assert workflow.count("--vityo-startup-probe") == 3
    assert workflow.count("--vityo-candidate") == 3
    assert workflow.count("--vityo-evidence-file") == 3


if __name__ == "__main__":
    main()
