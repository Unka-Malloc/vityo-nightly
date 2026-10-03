#!/usr/bin/env python3
"""Sign and notarize the staged macOS Vityo.app, or report the explicit gap.

Packaging calls :func:`apply_signing` after every packaged helper binary is
staged and before the installer definition builds the DMG. That order is
required: ``codesign`` seals nested code from the inside out, so the ``vityod``
and ``vityo-coding-agent`` executables under ``Contents/Helpers`` must already
be in place, and the DMG that carries the sealed bundle must be built after it
is sealed.

Credential boundary: signing material is read from the process environment
only. This module never writes, caches, copies, or logs a credential value, a
keychain path, or a certificate file. It reads the environment, returns a
status mapping that is safe to publish, and reports observed tool output. Every
secret-shaped value stays inside the ``subprocess`` call that consumes it.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

# Credential interface. These names are the whole contract; the packaging
# definition only ever records the status derived from them.
IDENTITY_ENV = "VITYO_MACOS_SIGNING_IDENTITY"
APPLE_ID_ENV = "VITYO_MACOS_NOTARY_APPLE_ID"
TEAM_ID_ENV = "VITYO_MACOS_NOTARY_TEAM_ID"
PASSWORD_ENV = "VITYO_MACOS_NOTARY_PASSWORD"
KEYCHAIN_PROFILE_ENV = "VITYO_MACOS_NOTARY_KEYCHAIN_PROFILE"

# The certificate is not a secret, so a pipeline may import it from a base64
# secret. The decoded material is used and discarded inside this process and is
# never written into the repository or the evidence directory.
CERTIFICATE_ENV = "VITYO_MACOS_SIGNING_CERTIFICATE_P12_BASE64"
CERTIFICATE_PASSWORD_ENV = "VITYO_MACOS_SIGNING_CERTIFICATE_PASSWORD"
KEYCHAIN_PASSWORD_ENV = "VITYO_MACOS_SIGNING_KEYCHAIN_PASSWORD"

SIGNING_GAP_REASON = (
    "Nightly Developer ID and notarization credentials are not configured."
)

# Helpers that live inside the bundle and must be sealed before the bundle.
NESTED_EXECUTABLES = ("Contents/Helpers/vityod", "Contents/Helpers/vityo-coding-agent")


class SigningError(RuntimeError):
    """A configured signing run failed; packaging must stop."""


@dataclass(frozen=True)
class SigningConfiguration:
    """The non-secret part of a resolved signing request."""

    identity: str
    team_id: str | None
    uses_keychain_profile: bool


def signing_requested(environ: dict[str, str] | None = None) -> bool:
    """Report whether the environment asks for a real signing run."""
    env = os.environ if environ is None else environ
    return bool(env.get(IDENTITY_ENV, "").strip())


def resolve_configuration(environ: dict[str, str] | None = None) -> SigningConfiguration:
    """Resolve the signing identity and notarization mode, or raise."""
    env = os.environ if environ is None else environ
    identity = env.get(IDENTITY_ENV, "").strip()
    if not identity:
        raise SigningError(f"{IDENTITY_ENV} is not set")

    profile = env.get(KEYCHAIN_PROFILE_ENV, "").strip()
    if profile:
        notarization_ready = True
        team_id = env.get(TEAM_ID_ENV, "").strip() or None
    else:
        apple_id = env.get(APPLE_ID_ENV, "").strip()
        team_id = env.get(TEAM_ID_ENV, "").strip()
        password = env.get(PASSWORD_ENV, "").strip()
        missing = [
            name
            for name, value in (
                (APPLE_ID_ENV, apple_id),
                (TEAM_ID_ENV, team_id),
                (PASSWORD_ENV, password),
            )
            if not value
        ]
        if missing:
            raise SigningError(
                "notarization credentials are incomplete; set "
                f"{KEYCHAIN_PROFILE_ENV} or all of {', '.join(missing)}"
            )
        notarization_ready = True

    if not notarization_ready:
        raise SigningError("notarization mode could not be resolved")
    return SigningConfiguration(
        identity=identity,
        team_id=team_id,
        uses_keychain_profile=bool(profile),
    )


def _run(command: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True, env=env)


# Every environment value that must never appear in a published message.
_CREDENTIAL_VARIABLES = (
    PASSWORD_ENV,
    APPLE_ID_ENV,
    CERTIFICATE_ENV,
    CERTIFICATE_PASSWORD_ENV,
    KEYCHAIN_PASSWORD_ENV,
)

_REDACTED = "<redacted>"
_MAX_DETAIL = 400


def _redact(detail: str) -> str:
    """Remove credential values and workstation paths from tool output."""
    redacted = detail
    for name in _CREDENTIAL_VARIABLES:
        value = os.environ.get(name, "")
        if len(value) >= 4 and value in redacted:
            redacted = redacted.replace(value, _REDACTED)
    redacted = redacted.replace(str(Path.home()), "<home>")
    redacted = " ".join(redacted.split())
    if len(redacted) > _MAX_DETAIL:
        redacted = f"{redacted[:_MAX_DETAIL]}…"
    return redacted


def _require_success(result: subprocess.CompletedProcess[str], action: str) -> None:
    if result.returncode != 0:
        detail = _redact((result.stderr or result.stdout or "").strip())
        raise SigningError(f"{action} failed: {detail}")


def sign_nested_executables(
    app: Path,
    configuration: SigningConfiguration,
    *,
    run: object = _run,
) -> list[str]:
    """Seal each packaged helper before the enclosing bundle is sealed."""
    signed: list[str] = []
    for relative in NESTED_EXECUTABLES:
        target = app / relative
        if not target.is_file():
            continue
        result = run(
            [
                "codesign",
                "--force",
                "--options",
                "runtime",
                "--timestamp",
                "--sign",
                configuration.identity,
                str(target),
            ]
        )
        _require_success(result, f"codesign of {relative}")
        signed.append(relative)
    return signed


def sign_app_bundle(app: Path, configuration: SigningConfiguration, *, run: object = _run) -> None:
    """Seal the application bundle itself, deepest content first."""
    result = run(
        [
            "codesign",
            "--force",
            "--deep",
            "--options",
            "runtime",
            "--timestamp",
            "--sign",
            configuration.identity,
            str(app),
        ]
    )
    _require_success(result, "codesign of the application bundle")
    result = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    _require_success(result, "codesign verification")


def notarize(artifact: Path, configuration: SigningConfiguration, *, run: object = _run) -> None:
    """Submit the built artifact for notarization and staple the ticket."""
    if configuration.uses_keychain_profile:
        credentials = ["--keychain-profile", os.environ[KEYCHAIN_PROFILE_ENV]]
    else:
        credentials = [
            "--apple-id",
            os.environ[APPLE_ID_ENV],
            "--team-id",
            os.environ[TEAM_ID_ENV],
            "--password",
            os.environ[PASSWORD_ENV],
        ]
    result = run(["xcrun", "notarytool", "submit", str(artifact), *credentials, "--wait"])
    _require_success(result, "notarization submission")
    result = run(["xcrun", "stapler", "staple", str(artifact)])
    _require_success(result, "stapler")


def configured_status(configuration: SigningConfiguration) -> dict[str, object]:
    """Describe a completed signing run without exposing any credential."""
    status: dict[str, object] = {
        "status": "configured",
        "identity": configuration.identity,
        "notarization": (
            "keychain-profile" if configuration.uses_keychain_profile else "apple-id"
        ),
    }
    if configuration.team_id:
        status["team_id"] = configuration.team_id
    return status


def gap_status() -> dict[str, object]:
    """Describe the unconfigured state that packaging currently records."""
    return {"status": "explicit-gap", "reason": SIGNING_GAP_REASON}


def apply_signing(app: Path) -> dict[str, object]:
    """Seal the staged bundle when configured, otherwise report the gap.

    Returns the ``signing`` block to record in packaging evidence. When signing
    is not configured the result is the existing explicit gap, so an unsigned
    nightly keeps its present honest status instead of claiming a sealed build.
    """
    if not signing_requested():
        return gap_status()
    configuration = resolve_configuration()
    sign_nested_executables(app, configuration)
    sign_app_bundle(app, configuration)
    return configured_status(configuration)


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Staged Vityo.app to seal")
    parser.add_argument(
        "--notarize",
        type=Path,
        help="Built artifact (DMG) to submit for notarization after sealing",
    )
    args = parser.parse_args()
    status = apply_signing(args.app)
    if args.notarize is not None and status.get("status") == "configured":
        notarize(args.notarize, resolve_configuration())
    import json

    print(json.dumps(status, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
