# Vityo Windows Release Packaging

**Purpose:** Define Windows desktop release packaging requirements for Vityo, including native build evidence, installer behavior, PATH and file associations, update and repair behavior, and rollback evidence.

**Last updated:** 2026-10-02
**Status:** Formal distribution requirements; nightly candidate package is implemented

## 1. Scope

This document covers Windows package requirements for Vityo as a native Flutter desktop app. It distinguishes the unsigned nightly candidate from a formal Windows release with distribution, signing, update, and rollback evidence.

The Windows release artifact is:

- A native `flutter build windows --release` bundle.
- The nightly pipeline packages a ZIP with PowerShell installer scripts, `vityod`, and the `vityo-coding-agent` executable. Its Authenticode signing status is an explicit gap and automatic updates are disabled.
- A formal product release additionally requires signed distribution and the install/update/uninstall and rollback evidence in the release record.

## 2. CI Evidence Floor

The hosted Windows job reuses `python3 scripts/vityo.py` in CI mode and must:

1. Run on `windows-latest`.
2. Resolve the pinned Styio/Pafio executables from the configured product matrix.
3. Run the canonical privacy, architecture, test, coverage, build, isolated install, and startup stages without a separate wrapper path.
4. Use the pinned Rust/Cargo toolchain for the daemon and Coding Agent release binaries.
5. Upload the configured Windows coverage and candidate artifacts.

This proves the default CI floor. It does not prove formal distribution, signing, installer behavior, update behavior, or rollback.

## 3. Installer Requirements

A formal Windows release must define and verify:

| Requirement | Evidence |
|-------------|----------|
| Install path | Default install location and per-user or machine-wide scope are documented. |
| PATH behavior | Any command-line launcher or PATH entry is documented and reversible. |
| File associations | `.styio`, text files, and workspace-directory associations are either implemented and tested or explicitly unsupported. |
| Repair | Re-running the installer repairs missing binaries, metadata, shortcuts, and file associations. |
| Update | Installing a newer package preserves user data and replaces binaries atomically enough to recover from interruption. |
| Rollback | Downgrade or rollback path is documented, including user-data preservation rules. |
| Uninstall | Uninstall removes application binaries, shortcuts, launcher entries, and associations while preserving user data unless purge is explicitly selected. |

## 4. Runtime Data Preservation

The installer must not delete user project data during normal uninstall or update. User data locations must be documented in the release record, including:

1. Configuration directory.
2. Module package cache and staged updates.
3. Logs and diagnostics.
4. Workspace-local metadata.

## 5. Nightly Candidate Boundary

`python3 scripts/vityo.py build` creates the host Windows release bundle and
nightly ZIP. `install` uses the included per-user PowerShell installer and
verifies the installed client and Agent executable; `launch` runs the installed
candidate. The CI startup probe establishes candidate identity, process launch,
and first-frame evidence only. The app integration test root has no
Windows-target native UI integration selector, so package and startup results do
not establish Windows native UI behavior.

## 6. Current Gaps

| Gap | Priority | Owner |
|-----|----------|-------|
| Formal signed distribution channel and installer lifecycle are not selected; the existing ZIP is a nightly candidate package | High | Release |
| Code signing evidence is not attached | High | Release |
| Install/update/uninstall/repair/rollback proof is not attached | High | Release |
| Formal code-signing evidence is absent and automatic updates are disabled | High | Release |

## 7. Related Documents

- [Windows Desktop Adaptation Plan](../design/Vityo-Windows-Desktop-Adaptation-Plan.md)
- [BUILD-AND-DEV-ENV.md](../BUILD-AND-DEV-ENV.md)
- [Release Checklist](../governance/RELEASE-CHECKLIST.md)
- [Local Validation Evidence](./local-validation-evidence.md)
