# Repository Hygiene

**Purpose:** Define the repository hygiene entrypoint for `styio-view` so contributors and CI use one script to reject generated artifacts, dependency payloads, and undocumented binary blobs.

**Last updated:** 2026-04-19

## Command

Tracked-tree hygiene:

```bash
python3 scripts/repo-hygiene-gate.py --mode tracked
```

Staged-only hygiene:

```bash
python3 scripts/repo-hygiene-gate.py --mode staged
```

Push-range hygiene:

```bash
python3 scripts/repo-hygiene-gate.py --mode push --range origin/main..HEAD
```

## Scope

This gate rejects:

1. generated and dependency directories such as `build/`, `.dart_tool/`, `node_modules/`, and `.artifacts/`
2. forbidden binary/archive suffixes in tracked files or pushed history
3. undocumented binary files outside the narrow allowlist
4. `.gitignore` drift against the shared cross-repo baseline
5. missing documentation references for the hygiene and delivery entrypoints, including `scripts/delivery-gate.sh`
