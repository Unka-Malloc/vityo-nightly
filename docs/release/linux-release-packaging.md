# Vityo Linux Release Packaging

**Purpose:** Define the Linux desktop release packaging requirements for Vityo,
including desktop entry specification, icon policy, executable permissions,
AppStream metadata, update policy, release notes, and rollback/recovery
evidence.

**Owner:** Governance owner (CODEOWNERS -> governance domain)
**Last updated:** 2026-10-02
**Status:** Formal distribution requirements; nightly candidate package is implemented

## 1. Scope

This document covers Linux package requirements for Vityo as a native Flutter
desktop app. It distinguishes the unsigned nightly candidate from a formal
Linux release with distribution, signing, upgrade, and rollback evidence.

The Linux release artifact is:

- A native `flutter build linux --release` binary bundle.
- The nightly pipeline packages a `.deb` containing the Flutter client, `vityod`,
  and the `vityo-coding-agent` executable. Its signing status is an explicit gap
  and automatic updates are disabled.
- A formal product release additionally requires signed distribution and the
  install/update/uninstall and rollback evidence in the release record.

## 1.1 Current Engineering Candidate

`python3 scripts/vityo.py build` runs the host Linux release build and
`scripts/package-nightly.py`, which builds both Rust companions with locked Cargo
dependencies and assembles the `.deb` candidate. `python3 scripts/vityo.py install`
extracts the candidate under the per-user installation root (defaulting beneath
`XDG_DATA_HOME` or the user's local data directory); it does not install a
system-wide Debian package. `launch` opens the installed client. The CI probe
checks only candidate identity, launch, and first-frame evidence; it does not
prove Agent behavior or live UI acceptance.

## 2. Desktop Entry

The desktop entry file is at `packaging/linux/io.vityo.desktop`.

**Requirements:**

| Field | Value | Notes |
|-------|-------|-------|
| `Type` | `Application` | Standard desktop application |
| `Name` | `Vityo` | Must match the product name |
| `GenericName` | `Integrated Development Environment` | Desktop search |
| `Categories` | `Development;IDE;` | FreeDesktop.org menu placement |
| `Exec` | `vityo %F` | `%F` for file-open support |
| `Icon` | `io.vityo` | Matches the icon basename in `packaging/linux/icons/` |
| `Terminal` | `false` | No terminal wrapper needed |
| `MimeType` | `text/plain;text/x-styio;inode/directory;` | File associations |

**Validation:**

```bash
desktop-file-validate packaging/linux/io.vityo.desktop
```

## 3. Application Icons

Icons must be installed to the standard FreeDesktop.org icon theme paths:

| Size | Path | Format |
|------|------|--------|
| 256x256 | `/usr/share/icons/hicolor/256x256/apps/io.vityo.png` | PNG |
| scalable | `/usr/share/icons/hicolor/scalable/apps/io.vityo.svg` | SVG |

Icons live in source under `packaging/linux/icons/` and are copied by the
release build script.

## 4. AppStream Metadata

The AppStream file is at `packaging/linux/io.vityo.metainfo.xml`.

**Validation:**

```bash
appstreamcli validate packaging/linux/io.vityo.metainfo.xml
```

## 5. Executable Permissions

The main Flutter release binary lives at:

```
products/vityo_app/build/linux/x64/release/bundle/vityo
```

During packaging:
1. The binary must have executable bit set (`chmod +x`).
2. A wrapper script `/usr/bin/vityo` (or `/usr/local/bin/vityo`) is installed
   that launches the Flutter bundle.
3. The wrapper must NOT require `flutter` or Dart SDK at runtime.
4. The bundle's `lib/` directory and all `.so` files must have correct
   permissions (644 for libraries, 755 for binaries).

## 6. Update Policy

| Mechanism | Priority | Status |
|-----------|----------|--------|
| `.deb` package from GitHub Releases | Primary | Planned |
| Built-in self-update (in-app) | Secondary | Not implemented |
| Flatpak | Tertiary | Not implemented |
| AppImage | Quaternary | Not implemented |

For `.deb` distribution:
1. Each release publishes a `.deb` to GitHub Releases.
2. Users install via `dpkg -i vityo_<version>_amd64.deb`.
3. Update check: `apt update && apt upgrade` (if added to a repo).

## 7. Release Notes

Every formal Linux release requires:

1. A CHANGELOG or release notes entry in the release record.
2. Documentation of any Linux-specific changes, regressions, or known issues.
3. Upgrade/downgrade path instructions.
4. System requirements (Debian 13 / Ubuntu 24.04+, GTK 3.24+, etc.).

## 8. Rollback And Recovery

1. A formal release record must identify the prior signed package and supported
   downgrade procedure.
2. The nightly per-user install path replaces only the application candidate;
   it is not a formal system package uninstall or purge operation.
3. Any formal uninstall or purge behavior must preserve user workspaces and
   clearly distinguish application files from user data.

## 9. Gate Integration

The release-readiness gate (`scripts/release-readiness-gate.py`) verifies:

- `packaging/linux/io.vityo.desktop` exists.
- `packaging/linux/io.vityo.metainfo.xml` exists.
- `packaging/linux/DEBIAN/control` exists (for `.deb` release).

The canonical pipeline is `python3 scripts/vityo.py deliver`; its build stage
creates and validates the nightly package candidate. Static package metadata can
be checked separately with:

```bash
python3 scripts/release-readiness-gate.py --skip-build  # static packaging check
desktop-file-validate packaging/linux/io.vityo.desktop   # if available
```

## 10. Current Gaps

| Gap | Priority | Owner |
|-----|----------|-------|
| Icon SVG/PNG assets not yet created | Medium | Design |
| Signed repository distribution and formal install/update/uninstall/rollback workflow | High | Release |
| `appstreamcli validate` not in CI gate | Low | Governance |
| Flutter Linux release bundle size optimization | Low | Performance |
| Formal release evidence still needs signed/distributed package, install/update/uninstall proof, and rollback proof | High | Release |

## 11. Related Documents

- [Linux Desktop Adaptation Plan](../design/Vityo-Linux-Desktop-Adaptation-Plan.md)
- [BUILD-AND-DEV-ENV.md](../BUILD-AND-DEV-ENV.md)
- [Release Checklist](../governance/RELEASE-CHECKLIST.md)
- [packaging/linux/README.md](../../packaging/linux/README.md)
