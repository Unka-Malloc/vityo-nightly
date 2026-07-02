# Styio View

**Styio View is the dedicated editor and runtime viewport for the Styio
ecosystem.**
Part of the [Styio](https://styio.io) ecosystem.

[![License](https://img.shields.io/github/license/SymPolicy/Vityo?style=flat-square)](LICENSE)

[Simplified Chinese](README_zh.md) | [Documentation](docs/README.md) | [Build guide](docs/BUILD-AND-DEV-ENV.md) | [Prototype](prototype/index.html) | [Web Editor](prototype/editor.html)

---

The current repository stage is `product-led integration bootstrap`:

1. Styio View freezes its product contracts and adapter boundaries first.
2. The Flutter main shell and editor core continue advancing independently.
3. Upstream `styio` / `pafio` implement the machine interfaces required by
   Styio View contracts.
4. The human-maintained web entry point is the hand-written `editor.html` line
   only; Flutter build artifacts under `frontend/styio_view_app/build/web` are
   for build verification, not human-maintained pages.

## Frontend / Backend Split

- **Frontend** — the user-facing editor, runtime viewport, and product
  interaction layer. Entry points: `frontend/styio_view_app/` and `prototype/`.
- **Backend** — not a single service, but the full toolchain surface behind
  Styio View: adapter layer, local CLI/FFI, hosted control plane, and upstream
  `pafio` / `styio` contracts.
- The frontend orchestrates and displays machine contracts only. Toolchain
  parsing, dependency/publish/execution semantics, and repository/cloud
  behaviors stay in the backend.

System-level boundary definition:
[Styio-View-System-Architecture.md](docs/design/Styio-View-System-Architecture.md).

## Development Environment

Container / VM:

```bash
./scripts/bootstrap-dev-container.sh
```

Linux:

```bash
./scripts/bootstrap-dev-env.sh
./scripts/bootstrap-dev-env.sh --with-android
```

macOS:

```bash
./scripts/bootstrap-dev-env-macos.sh
./scripts/bootstrap-dev-env-macos.sh --with-ios
./scripts/bootstrap-dev-env-macos.sh --with-android
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-dev-env-windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-dev-env-windows.ps1 -WithAndroid
```

Shared workspace initialization:

```bash
./scripts/bootstrap-workspace.sh --platforms web,linux
```

For the full build, test, profile switching, and device verification guide, see
[docs/BUILD-AND-DEV-ENV.md](docs/BUILD-AND-DEV-ENV.md).

## Implementation

The actual application entry point is
[frontend/styio_view_app/README.md](frontend/styio_view_app/README.md).

## Repository Hygiene Gate

The GitHub Actions workflow `Repository Hygiene Gate` runs
`python3 scripts/repo-hygiene-gate.py` on every push and pull request. It
blocks generated directories, dependency directories, packaging artifact
suffixes, and any binary files not explicitly allowlisted.

## License

Apache-2.0. See [LICENSE](LICENSE).
