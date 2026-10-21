# ADR-0010: Vityo IDE Ownership And Presentation Import Boundary

**Purpose:** Establish presentation-independent service ownership, registered presentation imports, and a single application composition boundary.

**Last updated:** 2026-10-02

**Status:** Accepted
**Date:** 2026-06-24
**Deciders:** Architecture owner
**Replaces:** None (new ADR)

## Context

Vityo's Flutter codebase has domain/application contracts in both `view_ide/` and `ide/`, with Flutter screens in `view_render/` and service composition in `app/`. Treating every IDE contract as if it lived in `view_ide/` would either hide the true owner or encourage unnecessary moves. At the same time, unregistered presentation imports can couple domain implementation to widgets and make dependency direction unclear.

## Decision

We establish these ownership and import rules:

1. **`view_ide/`** owns presentation-independent IDE services and contracts, including language, runtime, platform, and backend-toolchain adapters. It must not import `view_render/` or Flutter presentation libraries such as `package:flutter/material.dart`, `package:flutter/widgets.dart`, `package:flutter/cupertino.dart`, or `dart:ui`.
2. **`ide/`** remains an independently owned IDE application root for editor/document/workspace state and Agent Client/collaboration state. Its public model, command, and projection surfaces are not moved to `view_ide/` solely to simplify a gate.
3. **`view_render/`** owns Flutter screens, visual state, themes, and presentation bindings. It may consume only narrow, path-registered public contract/model/projection surfaces from their actual owners in `ide/` or `view_ide/`. Registering one path does not make sibling implementation paths public. Widgets do not construct a second workspace or Agent authority.
4. **`app/`** is the composition root. It creates shared service instances and injects them into the IDE application and presentation.
5. **Legacy source roots remain retired.** Old top-level `backend_toolchain/`, `editor/`, `language/`, and `integration/` import paths are not compatibility surfaces and must not be restored. The active `view_ide/backend_toolchain/` implementation is not one of these retired roots.

The path-level registry is a reviewed declaration of individual presentation dependencies, not a directory-wide API or proof that a feature is connected at runtime.

## Consequences

### Positive

- Domain and adapter services can be validated without building Flutter widgets.
- Source paths retain their actual owners rather than being moved to satisfy a presentation gate.
- Presentation receives only explicit model/projection entry points.
- Application composition can share one workspace, editor, language, runtime, and Agent authority.
- Import rules are covered by complementary architecture, product-import, and legacy-root checks; they do not share one registry or prove production composition.

### Negative

- Composition and narrow import registrations require explicit maintenance as new surfaces are added.
- A registered import must remain a small stable surface with owner-level tests; it is not permission for presentation to depend on neighboring implementation details.

## Enforcement

### Automated Gate

The checks have separate responsibilities:

1. `scripts/check_architecture_boundaries.py` resolves Dart imports and exports. It rejects `ide/` or `view_ide/` dependencies on `view_render/`, Flutter presentation imports from those IDE roots, and `view_render/` imports into either IDE root that are not listed individually in `VIEW_RENDER_ALLOWED_VIEW_IDE_IMPORTS`.
2. `scripts/import-boundary-gate.py` retains complementary product checks for direct legacy backend-toolchain and integration imports, concrete toolchain implementations, upstream-private imports from `view_ide/`, and Flutter widget imports from the legacy backend-toolchain root. Its independent allowlist does not replace the path-level registry.
3. `scripts/vityo-product-gate.py` rejects non-facade implementation in the retained legacy `integration/`, top-level `backend_toolchain/`, and top-level `language/` directories. These checks do not constitute a general import graph scan or establish that retired roots can never be recreated.

The architecture registry is the narrow presentation dependency check. These gates do not verify that an allowlisted path is composed by the running application or that its feature is operational.

The gate must report the missing owner path and preserve the registered public path as the smallest reviewed unit. Expanding an allowlist to an entire directory is not an acceptable repair for a missing import.

### Code Review Checklist

Reviewers verify:

1. New `view_ide/` files do not import Flutter presentation libraries or `view_render/`.
2. New presentation imports use a path registered for an existing public contract/model/projection and have an architecture owner review.
3. `app/` composes one shared service instance for each document/workspace/Agent authority used by multiple surfaces.
4. Registered import paths do not expose neighboring implementation as a public API.
5. Retired top-level compatibility roots are not restored.

### Migration Path

The top-level source-root migration is complete. The path-level presentation registry is the maintained boundary; no compatibility phase remains. An allowlisted presentation dependency is not evidence that a feature is composed in the production application.

## Validation

- `scripts/check_architecture_boundaries.py` — resolved import/export graph scan
- `scripts/import-boundary-gate.py` — product import-boundary scan
- `python3 -m unittest tests.test_architecture_boundaries` — gate unit tests
- `flutter analyze` — static analysis
- Code review checklist in `docs/teams/ARCHITECTURE-RUNBOOK.md`

## Related

- [ADR-0009: Module Runtime and Staged Updates](./ADR-0009-module-runtime-and-staged-updates.md)
- [Vityo Mainstream Architecture Alignment](../design/Vityo-Mainstream-Architecture-Alignment.md)
- [Vityo System Architecture](../design/Vityo-System-Architecture.md)
- [Architecture Runbook](../teams/ARCHITECTURE-RUNBOOK.md)
