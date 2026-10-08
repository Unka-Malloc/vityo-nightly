"""Truthful cross-platform delivery contract for Vityo."""

from __future__ import annotations

import argparse
import dataclasses
import json
import pathlib
import sys
from collections.abc import Mapping


PLATFORMS = ("windows", "macos", "linux")
VITYOD_TARGETS = {
    "windows": "x86_64-pc-windows-msvc",
    "macos": "native-apple-darwin",
    "linux": "x86_64-unknown-linux-gnu",
}
VITYOD_PACKAGE_PATHS = {
    "windows": "components/vityod.exe",
    "macos": "Contents/Helpers/vityod",
    "linux": "components/vityod",
}
VITYOD_SOURCE_PATHS = {
    "windows": "products/vityo_app/native/vityod/target/release/vityod.exe",
    "macos": "products/vityo_app/native/vityod/target/release/vityod",
    "linux": "products/vityo_app/native/vityod/target/release/vityod",
}
CODING_AGENT_TARGETS = {
    "windows": "x86_64-pc-windows-msvc",
    "macos": "native-apple-darwin",
    "linux": "x86_64-unknown-linux-gnu",
}
CODING_AGENT_PACKAGE_PATHS = {
    "windows": "components/vityo-coding-agent.exe",
    "macos": "Contents/Helpers/vityo-coding-agent",
    "linux": "components/vityo-coding-agent",
}
CODING_AGENT_SOURCE_PATHS = {
    "windows": "products/vityo_coding_agent/target/release/vityo-coding-agent.exe",
    "macos": "products/vityo_coding_agent/target/release/vityo-coding-agent",
    "linux": "products/vityo_coding_agent/target/release/vityo-coding-agent",
}
CODING_AGENT_RUNTIME_LIBRARIES = {
    "windows": ["vcruntime140.dll"],
    "macos": [],
    "linux": ["glibc", "libssl.so.3"],
}
PAFIO_TARGETS = {
    "windows": "x86_64-pc-windows-msvc",
    "macos": "native-apple-darwin",
    "linux": "x86_64-unknown-linux-gnu",
}
PAFIO_PACKAGE_PATHS = {
    "windows": "components/pafio.exe",
    "macos": "Contents/Helpers/pafio",
    "linux": "components/pafio",
}
PAFIO_RUNTIME_LIBRARIES = {
    "windows": ["vcruntime140.dll"],
    "macos": [],
    "linux": ["glibc"],
}
PAFIO_MANIFEST_PATHS = {
    "windows": "components/pafio-component.json",
    "macos": "Contents/Resources/pafio-component.json",
    "linux": "components/pafio-component.json",
}


@dataclasses.dataclass(frozen=True)
class DeliveryLaneResult:
    platform: str
    status: str
    reason: str

    def to_json(self) -> dict[str, object]:
        return dataclasses.asdict(self)


def load_delivery_contract(root: pathlib.Path) -> dict[str, object]:
    path = root / "packaging" / "vityo" / "desktop-delivery.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("desktop delivery contract must be an object")
    return payload


def evaluate_lane(
    *,
    platform: str,
    host_platform: str,
    expected_candidate: str,
    evidence: Mapping[str, object] | None,
) -> DeliveryLaneResult:
    if platform not in PLATFORMS:
        return DeliveryLaneResult(platform, "failed", "unsupported platform")
    if host_platform != platform:
        return DeliveryLaneResult(
            platform,
            "blocked",
            f"{platform} delivery requires a matching host platform",
        )
    if evidence is None:
        return DeliveryLaneResult(platform, "failed", "launch evidence is missing")
    expected_fields = {
        "schema_version",
        "candidate",
        "platform",
        "launched",
        "first_frame",
    }
    if platform == "windows":
        expected_fields.add("windows_pipe_abi")
    if set(evidence) != expected_fields:
        return DeliveryLaneResult(platform, "failed", "startup evidence fields are invalid")
    if type(evidence.get("schema_version")) is not int or evidence.get("schema_version") != 1:
        return DeliveryLaneResult(platform, "failed", "startup evidence schema is invalid")
    if evidence.get("platform") != platform:
        return DeliveryLaneResult(platform, "failed", "startup evidence platform is invalid")
    if not expected_candidate or evidence.get("candidate") != expected_candidate:
        return DeliveryLaneResult(platform, "failed", "startup evidence candidate is invalid")
    if evidence.get("launched") is not True:
        return DeliveryLaneResult(platform, "failed", "packaged Vityo did not launch")
    if evidence.get("first_frame") is not True:
        return DeliveryLaneResult(platform, "failed", "client did not complete its first frame")
    if platform == "windows" and (
        type(evidence.get("windows_pipe_abi")) is not int or evidence["windows_pipe_abi"] != 1
    ):
        return DeliveryLaneResult(platform, "failed", "Windows pipe library ABI was not verified")
    return DeliveryLaneResult(platform, "passed", "installed candidate reached its first frame")


def validate_repository(root: pathlib.Path) -> list[str]:
    errors: list[str] = []
    try:
        contract = load_delivery_contract(root)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return [f"desktop delivery contract is invalid: {error}"]
    if contract.get("schema_version") != 1:
        errors.append("desktop delivery schema_version must be 1")
    if contract.get("product") != "vityo":
        errors.append("desktop delivery product must be vityo")
    if set(contract.get("platforms", [])) != set(PLATFORMS):
        errors.append("desktop delivery must declare windows, macos, and linux")
    component = contract.get("component")
    if not isinstance(component, dict) or component.get("name") != "vityod":
        errors.append("desktop delivery must declare the vityod component")
    elif (
        component.get("protocol_min") != 1
        or component.get("protocol_max") != 1
        or component.get("instance_scope") != "per-user"
        or component.get("launch") != "on-demand"
        or component.get("privileged_service") is not False
        or component.get("discovery") != "application-relative-manifest-only"
    ):
        errors.append("vityod component lifecycle or protocol contract is invalid")
    coding_agent = contract.get("coding_agent")
    if not isinstance(coding_agent, dict) or coding_agent != {
        "name": "vityo-coding-agent",
        "lifecycle": "independent-on-demand-process",
        "discovery": "application-relative-executable-only",
    }:
        errors.append("Coding Agent component lifecycle or discovery contract is invalid")
    pafio = contract.get("pafio")
    if not isinstance(pafio, dict) or pafio != {
        "name": "pafio",
        "lifecycle": "independent-on-demand-process",
        "discovery": "application-relative-manifest-only",
    }:
        errors.append("pafio component lifecycle or discovery contract is invalid")
    state_policy = contract.get("state_policy")
    if not isinstance(state_policy, dict) or state_policy != {
        "compatible_schema_step": 1,
        "upgrade": "candidate-health-rollback",
        "uninstall": "retain-user-state",
        "reclamation": "separate-explicit-confirmation",
    }:
        errors.append("desktop delivery state retention policy is invalid")

    for platform in PLATFORMS:
        manifest_path = root / "packaging" / platform / "nightly.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"{manifest_path.relative_to(root)}: {error}")
            continue
        if manifest.get("schema_version") != 1 or manifest.get("platform") != platform:
            errors.append(f"{manifest_path.relative_to(root)}: invalid schema/platform")
        if manifest.get("product") != "vityo":
            errors.append(f"{manifest_path.relative_to(root)}: product must be vityo")
        build_path = str(manifest.get("build_relative_path", ""))
        if not build_path.startswith("products/vityo_app/build/"):
            errors.append(f"{manifest_path.relative_to(root)}: build path escapes Vityo")
        signing = manifest.get("signing")
        if not isinstance(signing, dict) or signing.get("status") not in {
            "configured",
            "explicit-gap",
        }:
            errors.append(f"{manifest_path.relative_to(root)}: signing state is not explicit")
        elif signing.get("status") == "explicit-gap" and not str(
            signing.get("reason", "")
        ).strip():
            errors.append(f"{manifest_path.relative_to(root)}: signing gap lacks a reason")
        vityod = manifest.get("vityod")
        if not isinstance(vityod, dict):
            errors.append(f"{manifest_path.relative_to(root)}: vityod component is missing")
        else:
            source_path = str(vityod.get("source_relative_path", ""))
            package_path = str(vityod.get("package_relative_path", ""))
            target = str(vityod.get("target", ""))
            runtime_libraries = vityod.get("required_runtime_libraries")
            if source_path != VITYOD_SOURCE_PATHS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: vityod source path is invalid")
            if package_path != VITYOD_PACKAGE_PATHS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: vityod package path is invalid")
            if target != VITYOD_TARGETS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: vityod target is mismatched")
            if not isinstance(runtime_libraries, list) or not all(
                isinstance(library, str) and library.strip()
                for library in runtime_libraries
            ):
                errors.append(
                    f"{manifest_path.relative_to(root)}: vityod runtime library contract is invalid"
                )
        coding_agent = manifest.get("coding_agent")
        if not isinstance(coding_agent, dict):
            errors.append(f"{manifest_path.relative_to(root)}: Coding Agent component is missing")
        else:
            source_path = str(coding_agent.get("source_relative_path", ""))
            package_path = str(coding_agent.get("package_relative_path", ""))
            target = str(coding_agent.get("target", ""))
            if source_path != CODING_AGENT_SOURCE_PATHS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: Coding Agent source path is invalid")
            if package_path != CODING_AGENT_PACKAGE_PATHS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: Coding Agent package path is invalid")
            if target != CODING_AGENT_TARGETS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: Coding Agent target is mismatched")
            if coding_agent.get("required_runtime_libraries") != CODING_AGENT_RUNTIME_LIBRARIES[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: Coding Agent runtime libraries are mismatched")
        pafio = manifest.get("pafio")
        if not isinstance(pafio, dict):
            errors.append(f"{manifest_path.relative_to(root)}: pafio component is missing")
        else:
            package_path = str(pafio.get("package_relative_path", ""))
            target = str(pafio.get("target", ""))
            if package_path != PAFIO_PACKAGE_PATHS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: pafio package path is invalid")
            if target != PAFIO_TARGETS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: pafio target is mismatched")
            if pafio.get("required_runtime_libraries") != PAFIO_RUNTIME_LIBRARIES[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: pafio runtime libraries are mismatched")
            if pafio.get("manifest_relative_path") != PAFIO_MANIFEST_PATHS[platform]:
                errors.append(f"{manifest_path.relative_to(root)}: pafio manifest path is invalid")

    workflow_path = root / ".github" / "workflows" / "local-ci-gate.yml"
    try:
        workflow = workflow_path.read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f".github/workflows/local-ci-gate.yml: {error}")
    else:
        for platform in PLATFORMS:
            if f"scripts/vityo.py deliver --mode ci --platform {platform}" not in workflow:
                errors.append(f"local-ci-gate.yml: missing {platform} unified delivery lane")
        runner_path = root / "scripts" / "vityo.py"
        if not runner_path.is_file() or "--vityo-startup-probe" not in runner_path.read_text(encoding="utf-8"):
            errors.append("scripts/vityo.py: installed-client startup probe is missing")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=pathlib.Path, required=True)
    parser.add_argument("--platform", choices=PLATFORMS)
    parser.add_argument("--evidence", type=pathlib.Path)
    parser.add_argument("--expected-candidate")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    errors = validate_repository(args.repo_root.resolve())
    lane = None
    if not errors and args.platform is not None:
        if args.evidence is None or not args.evidence.is_file():
            errors.append("desktop delivery evidence file is missing")
        elif not args.expected_candidate:
            errors.append("expected installed candidate is missing")
        else:
            evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
            host_platform = {
                "win32": "windows",
                "darwin": "macos",
                "linux": "linux",
            }.get(sys.platform, sys.platform)
            lane = evaluate_lane(
                platform=args.platform,
                host_platform=host_platform,
                expected_candidate=args.expected_candidate,
                evidence=evidence,
            )
            if lane.status != "passed":
                errors.append(f"{args.platform} lane {lane.status}: {lane.reason}")
    payload = {
        "ok": not errors,
        "errors": errors,
    }
    if lane is not None:
        payload["lane"] = lane.to_json()
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    elif errors:
        for error in errors:
            print(error, file=sys.stderr)
    else:
        print("Vityo desktop delivery contract is valid")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
