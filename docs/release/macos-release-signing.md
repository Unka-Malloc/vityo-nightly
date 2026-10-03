# Vityo macOS Release Signing

**Purpose:** Define the macOS Developer ID signing and notarization interface for
Vityo nightly packaging, including the credential contract, the sealing order,
the published evidence shape, and the difference between a sealed artifact and a
formal release.

**Last updated:** 2026-10-03
**Status:** Signing interface implemented; credentials not yet provisioned, so nightly packages remain an explicit gap

## 1. Scope

This document covers macOS code signing and notarization for Vityo as a native
Flutter desktop app. It distinguishes three states:

1. **Unsigned nightly candidate.** No signing credentials are present. Packaging
   records `{"status": "explicit-gap", "reason": ...}` and produces an unsigned
   DMG. This is the current state.
2. **Sealed nightly candidate.** Developer ID credentials are present.
   Packaging seals the bundle, verifies the seal, builds the DMG, notarizes it,
   staples the ticket, and records `{"status": "configured", ...}`.
3. **Formal release.** Requires state 2 plus a distribution channel, install
   and update behavior, rollback evidence, and release notes. Sealing alone does
   not establish a formal release.

The macOS release artifact is a `.dmg` produced by
[packaging/macos/create-dmg.sh](../../packaging/macos/create-dmg.sh) from the
staged `Vityo.app`.

## 1a. Known Bundle Blockers Before A Seal Can Succeed

Signing was exercised against a real Developer ID certificate on the installed
nightly bundle, and sealing stopped on two concrete bundle defects rather than on
the credential path. Both must be fixed in the build/staging layout before a
signed artifact can exist:

1. **Resolved: `vityod-component.json` is no longer staged as nested code.**
   The seal previously failed with `code object is not signed at all` naming
   `Contents/Helpers/vityod-component.json`, because `codesign` treats
   `Contents/Helpers` as a directory of nested code. The package definition now
   declares the manifest location through `vityod.manifest_relative_path`, and
   macOS stages it under `Contents/Resources`; other platforms keep the manifest
   beside the daemon. The desktop matrix gate discovers it by recursive search and
   still requires exactly one record per package.
2. **The Flutter frameworks are not in a form `codesign` will seal.**
   `Contents/Frameworks/FlutterMacOS.framework` fails with `bundle format is
   ambiguous (could be app or framework)`, and the same applies to
   `App.framework`. On disk these frameworks carry a top-level binary alongside a
   `Versions/` tree, which is not a layout `codesign` accepts for a framework
   bundle. This originates in the Flutter macOS build output, so the resolution
   belongs to the build configuration rather than to the seal step.

Until both are resolved, package builds keep recording the explicit signing gap,
which is the honest state: the seal step refuses to report success for a bundle it
cannot verify. `--deep` is deliberately not used, because it is deprecated for
signing and reports the framework problem with a less specific message.

## 2. Sealing Order

`scripts/package-nightly.py` stages `vityod` and `vityo-coding-agent` into
`Contents/Helpers` before sealing. That order is required and must not be
rearranged:

1. Copy `Vityo.app` into a staging directory.
2. Stage `Contents/Helpers/vityod` and `Contents/Helpers/vityo-coding-agent`.
3. Stage the Rust third-party notices.
4. Enumerate the bundle's nested code — helpers, frameworks (including each
   framework's versioned bundle), app extensions, and loose dylibs — and seal each
   item deepest-first with the hardened runtime. `--deep` is not used.
5. Seal the enclosing `Vityo.app` bundle and verify the seal.
6. Build the DMG from the sealed bundle.
7. Notarize the DMG and staple the ticket.

Sealing a bundle before its nested executables exist produces a signature that
the later helpers invalidate. The DMG must be built after sealing so the shipped
artifact carries the sealed bundle, and notarization must run against the built
DMG rather than the bundle.

## 3. Credential Contract

`scripts/vityo_macos_signing.py` reads signing material from the process
environment and nothing else. No credential value is written to the repository,
the evidence directory, or a log.

**Required to enable signing at all:**

| Variable | Meaning |
|----------|---------|
| `VITYO_MACOS_SIGNING_IDENTITY` | Codesigning identity, for example `Developer ID Application: Example (ABCDE12345)`. Its presence is the switch that enables signing. |

**Notarization, choose one mode:**

| Variable | Mode |
|----------|------|
| `VITYO_MACOS_NOTARY_KEYCHAIN_PROFILE` | Preferred. A `notarytool` keychain profile created ahead of time. |
| `VITYO_MACOS_NOTARY_APPLE_ID` + `VITYO_MACOS_NOTARY_TEAM_ID` + `VITYO_MACOS_NOTARY_PASSWORD` | App-specific password mode. All three are required together. |

**Optional, for an ephemeral signing keychain in CI:**

| Variable | Meaning |
|----------|---------|
| `VITYO_MACOS_SIGNING_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID certificate. |
| `VITYO_MACOS_SIGNING_CERTIFICATE_PASSWORD` | Password for that certificate. |
| `VITYO_MACOS_SIGNING_KEYCHAIN_PASSWORD` | Password for a temporary keychain. |

A CI provider stores these as secrets and injects them as environment variables
for the packaging step. The certificate is not itself secret in the way a
password is, but it is still never committed.

## 4. Behavior And Failure Rules

1. When `VITYO_MACOS_SIGNING_IDENTITY` is unset or blank, packaging records the
   explicit gap and produces an unsigned DMG. It does not fail and does not
   claim a seal.
2. When the identity is set but notarization credentials are incomplete,
   `validate_release_inputs` fails before any build work starts, naming only the
   missing variable names.
3. A nonzero exit from `codesign`, `notarytool`, or `stapler` stops packaging.
   A partially sealed artifact is never published.
4. Tool output included in an error message is redacted: credential values and
   the workstation home-directory prefix are removed, and the detail is bounded
   in length.
5. The published signing status carries only the identity string, the
   notarization mode, and the team identifier when known. It never carries a
   password, an Apple ID, or certificate material.

## 5. Evidence

Packaging writes the signing block into the artifact manifest beside the DMG,
for example `build/nightly/vityo-nightly-macos-<version>.dmg.json`:

```json
{
  "signing": {
    "status": "configured",
    "identity": "Developer ID Application: Example (ABCDE12345)",
    "notarization": "keychain-profile",
    "team_id": "ABCDE12345"
  }
}
```

`automatic_updates` may only be `true` when signing is `configured`; this is
enforced by both the packaging validator and the release readiness gate.

## 6. Verification Of A Sealed Artifact

A sealed candidate is verified with:

```sh
codesign --verify --deep --strict --verbose=2 /path/to/Vityo.app
spctl --assess --type execute --verbose=4 /path/to/Vityo.app
xcrun stapler validate /path/to/vityo-nightly-macos-<version>.dmg
```

Gatekeeper assessment and a successful staple check on the target host are the
evidence that matter. A green CI lane alone does not prove them, because CI does
not run the signed artifact through Gatekeeper on a user machine.

## 7. Current Gaps

| Gap | Priority | Owner |
|-----|----------|-------|
| Developer ID certificate and notarization credentials are not provisioned in this repository's pipeline | High | Release |
| No CI secret is configured for the variables in section 3, so hosted macOS packaging stays unsigned | High | Release |
| Signed install, update, rollback, and uninstall proof is not attached | High | Release |
| The Flutter frameworks in the macOS build output are not a bundle layout `codesign` will seal | High | Build |
| Formal distribution channel is not selected | High | Release |

## 8. Enabling Signing

1. Provision a Developer ID Application certificate and its private key.
2. Choose a notarization mode from section 3 and create the credential.
3. Add the variables as CI secrets and inject them into the macOS packaging
   step only.
4. Run packaging and confirm the artifact manifest reports
   `"status": "configured"`.
5. Verify the sealed artifact per section 6 on a real host.
6. Attach the verification output to the release record and update the signing
   status in [packaging/macos/nightly.json](../../packaging/macos/nightly.json)
   from `explicit-gap` to `configured`.

## 9. Related Documents

- [Release Evidence](./README.md)
- [Windows Release Packaging](./windows-release-packaging.md)
- [Linux Release Packaging](./linux-release-packaging.md)
- [Release Checklist](../governance/RELEASE-CHECKLIST.md)
- [Security And Supply Chain](../governance/SECURITY-AND-SUPPLY-CHAIN.md)
- [Local Validation Evidence](./local-validation-evidence.md)
