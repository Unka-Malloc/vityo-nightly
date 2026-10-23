# Vityo Nightly desktop packages

`release-versions.json` versions the Vityo core and each desktop adapter
independently. `scripts/package-nightly.py --platform <platform>` consumes one
platform definition and writes only that platform's artifact and receipt under
`build/nightly/`.

| Platform | Artifact | Install/start gate |
|---|---|---|
| Linux | Debian package | `dpkg -i`, then launch through Xvfb |
| Windows | ZIP with per-user PowerShell installer | install to a temporary per-user directory, launch, uninstall |
| macOS | DMG | verify, mount, copy the app bundle, launch |

The three native CI jobs do not depend on one another. A platform failure blocks
only that adapter artifact. Each artifact receipt records both the core version
and that platform adapter version. Each package also carries exactly one
`vityod-component.json`. That identity binds the target, daemon version, protocol
range, executable digest, daemon-source fingerprint, declared runtime libraries,
and application-relative location. The package definition declares where it is
staged through `vityod.manifest_relative_path`, and it defaults to sitting beside
the daemon executable. macOS stages it under `Contents/Resources` instead, because
`codesign` treats `Contents/Helpers` as a directory of nested code and refuses to
seal the bundle while an unsigned JSON record is inside it.

The same package also bundles the pinned `pafio` CLI as a built-in component. Its
binary is staged at the platform layout (`components/pafio` on Linux,
`components/pafio.exe` on Windows, `Contents/Helpers/pafio` on macOS) and its
identity is recorded in `pafio-component.json`, a different file name so a
package still contains exactly one `vityod-component.json`. pafio is a pinned
external CLI rather than an in-repository workspace, so its contract declares the
target and runtime libraries but no build source path: packaging resolves the
binary through the shared pinned-CLI resolution, preferring an explicit
`--pafio-bin` and otherwise provisioning the product-matrix revision. The record
uses the same application-relative discovery model as vityod — `manifest_relative_path`
declares where it is staged, defaulting beside the executable, and macOS stages it
under `Contents/Resources` for the same `codesign` reason.

`python3 scripts/vityod-desktop-matrix-gate.py --fixtures-only` verifies all
three structural lanes without claiming a launch. A matching host validates an
installed layout with `--platform <platform> --application-root <path>`; that
lane checks the component digest, daemon health, and two consecutive client
handshakes against the same daemon instance.

Nightly signing is currently an explicit release gap on all three platforms.
Until a platform definition reports configured signing, its automatic update
policy must remain `false`; the release-readiness gate enforces this fail-closed.
An unsigned artifact is for manual trust/install testing and is not evidence of
a completed product capability.
