# Styio View Toolchain Backend Handoff Plan

**Purpose:** Define the repo-local toolchain backend surface so frontend, adapter, and upstream-integration work can proceed in parallel without guessing ownership.

**Last updated:** 2026-04-21

**Status:** Active plan

## 1. Problem

`toolchain/` currently exposes raw profile assets but not a clear backend-owned handoff surface. That makes parallel work fuzzy in three ways:

1. frontend teams do not know which fields should come from normalized backend state versus raw files
2. backend work has no repo-local place to document route selection and blocked-state behavior
3. upstream asks to `styio-nightly` and `styio-spio` risk getting mixed with UI-specific assumptions

This plan makes `toolchain/` the local ownership area for profile assets, backend notes, and mockable handoff examples while preserving upstream SSOT boundaries.

## 2. Fixed Ownership Split

| Area | Owner | What it owns |
|------|-------|--------------|
| `toolchain/` | `styio-view` toolchain backend | repo-local profile assets, normalization notes, frontend handoff examples |
| `docs/contracts/` | `styio-view` product-contract owners | adapter SSOT consumed by frontend and backend |
| `styio-spio` | package/workflow/backend-service owners | hosted control plane, project graph, toolchain state, dependency and deployment backend services |
| `styio-nightly` | compiler/toolchain owners | compiler binary truth, managed toolchain install/use/pin semantics, machine-info capability SSOT |

## 3. Backend-Owned Surface Inside This Repo

The backend side of `styio-view` should now treat `toolchain/` as four lanes:

1. root profile tables
   `android-sdk-profiles.csv` and `apple-platform-profiles.csv` stay at the current paths because scripts, Dockerfiles, and build docs already consume them
2. backend notes
   `toolchain/backend/` explains route selection, state normalization, and output expectations
3. frontend handoff
   `toolchain/handoff/` fixes the UI-facing working rules without turning this directory into a second contract SSOT
4. mock examples
   `toolchain/examples/` carries non-authoritative example payloads for local mocks and early adapter tests

## 4. What The Toolchain Backend Consumes

### `styio-nightly`

The backend consumes published compiler and managed-toolchain truth from `styio-nightly`, including:

1. compiler version and channel identity
2. install/use/pin lifecycle semantics
3. machine-info and capability publication

### `styio-spio`

The backend consumes package/workflow/backend-service truth from `styio-spio`, including:

1. project graph payloads
2. toolchain state payloads
3. dependency-source and registry state when environment screens need them
4. hosted control-plane routes and envelopes for remote workspaces

When an upstream contract is missing or not yet published, the backend must return structured `blocked` or `partial` status instead of guessing through filesystem layout.

## 5. Frontend Interface Rule

Frontend teams interface with this backend lane through product contracts and hosted machine payloads, not through raw files.

Fixed rule set:

1. frontend binds to `ToolchainManagementAdapter`, `ProjectGraphAdapter`, `DependencySourceAdapter`, `AdapterCapabilitySnapshot`, and the hosted toolchain routes published by `styio-spio`
2. frontend may use `toolchain/examples/*.example.json` for mocks and tests, but those files are not SSOT
3. frontend must not parse `.spio`, compiler-install symlinks, cache layout, or raw profile CSVs on the main runtime path
4. missing hosted identity or unpublished capability must render as `blocked` or `partial`, never as silent fallback logic

## 6. Parallel Development Handoff

### Backend Can Move Independently On

1. profile loading and selection
2. route selection across `local-cli`, `ffi`, and `hosted`
3. normalized toolchain state snapshots
4. install/use/pin/clear-pin result envelopes
5. blocked-reason and recovery-hint reporting

### Frontend Can Move Independently On

1. toolchain badges and environment status UI
2. install/use/pin flows
3. blocked-state UX and required-handoff rendering
4. project and environment panels that depend on normalized toolchain state

### Cross-Repo Coordination Rule

If a new field, operation, or route is required:

1. promote it into `docs/contracts/` when it is a `styio-view` product contract
2. promote it into `styio-spio` or `styio-nightly` when it belongs to upstream machine truth
3. only then update `toolchain/examples/` and downstream UI/backend code

## 7. Exit Criteria

This split is working when:

1. a frontend developer can build toolchain UI against the example payloads and contract docs without reading raw backend assets
2. a backend developer can implement route selection and status normalization without waiting on UI layout decisions
3. new upstream asks are written against explicit owners instead of landing as repo-local folklore
4. `toolchain/` remains a backend-owned area rather than drifting into a mixed frontend asset folder
