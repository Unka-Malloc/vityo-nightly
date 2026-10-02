# Vityo License Policy

**Purpose:** Record the source-license boundary enforced by `styio-audit`.

**Last updated:** 2026-10-02

`Vityo` is an Apache-2.0 source project. The accepted SPDX identifier is `Apache-2.0`.

Any source-derived app, adapter, module host, runtime integration, prototype, package, binary distribution, or build artifact that redistributes `Vityo` source or binaries must preserve the Apache License, Version 2.0 terms, copyright notices, NOTICE content when present, modification notices, and patent-license conditions required by Apache-2.0.

First-party Dart packages under `packages/` inherit this repository license and must be consumed through their canonical repository path. They are not third-party allowlist entries. External runtime and development dependencies must be registered in `DEPENDENCY-USAGE.md` with SPDX license evidence before being added to the license allowlist.

This file governs the Vityo source license. The dependency license allowlist and its distinction
between registered direct dependencies and supported-target locked-graph review are maintained in
[`docs/governance/SECURITY-AND-SUPPLY-CHAIN.md`](docs/governance/SECURITY-AND-SUPPLY-CHAIN.md).

The repository audit gate checks for Apache-2.0 license evidence, matching package metadata where present, and this source-distribution notice before delivery can be considered closed.
