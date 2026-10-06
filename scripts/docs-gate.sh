#!/usr/bin/env bash
# Convenience entrypoint for the docs/process gate on a Unix host.
#
# The gate itself is implemented in `scripts/docs_gate.py`, which delivery calls
# directly: that keeps the gate runnable on Windows, where `bash` in PATH can
# resolve to a WSL launcher with no distribution installed. This script exists for
# interactive use and forwards its arguments, so the two entrypoints cannot drift.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/docs-gate.sh [options]

Run the common docs/process gate by composing team-runbook maintenance,
docs audit, and ecosystem CLI contract consistency into one entrypoint.

Options:
  --mode <worktree|staged|push>  Change source for team-docs-gate (default: worktree)
  --base <ref>                   Base ref for push-mode team-docs-gate
  --skip-ecosystem               Skip the ecosystem CLI doc consistency check
  -h, --help                     Show this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PYTHON_BIN="${PYTHON_BIN:-python3}"
exec "$PYTHON_BIN" scripts/docs_gate.py --python-bin "$PYTHON_BIN" "$@"
