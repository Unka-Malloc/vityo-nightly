#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/delivery-gate.sh [options]

Run the common Vityo delivery floor by composing repository hygiene, the docs
gate, external audit, checkpoint health, and the ecosystem product gate into
one entrypoint. CI and VITYO_PRODUCT_GATE=1 require the product gate; local
runs without that opt-in record an explicit skip.

Options:
  --mode <checkpoint|push>  Delivery mode (default: checkpoint)
  --base <ref>              Base ref for team-docs-gate branch checks
  --range <rev-range>       Explicit revision range for repo-hygiene push mode
  --skip-health             Skip checkpoint-health (docs/process-only deliveries)
  --skip-audit              Skip external General-Auditor gate
  --skip-ecosystem          Skip ecosystem CLI doc consistency check in docs-gate
  --audit-root <path>       Trusted General-Auditor checkout
  -h, --help                Show this help
USAGE
}

log() {
  echo "[delivery-gate] $*"
}

run_cmd() {
  log "$*"
  "$@"
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

default_upstream_base() {
  git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="checkpoint"
BASE_REF=""
REV_RANGE=""
RUN_HEALTH=1
RUN_AUDIT=1
SKIP_ECOSYSTEM=0
AUDIT_BIN="${GENERAL_AUDITOR_ROOT:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --base)
      BASE_REF="$2"
      shift 2
      ;;
    --range)
      REV_RANGE="$2"
      shift 2
      ;;
    --skip-health)
      RUN_HEALTH=0
      shift
      ;;
    --skip-audit)
      RUN_AUDIT=0
      shift
      ;;
    --skip-ecosystem)
      SKIP_ECOSYSTEM=1
      shift
      ;;
    --audit-root)
      AUDIT_BIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

REPO_CMD=("$PYTHON_BIN" scripts/repo-hygiene-gate.py)
DOCS_GATE_CMD=(bash scripts/docs-gate.sh)
HEALTH_CMD=(bash scripts/checkpoint-health.sh)

case "$MODE" in
  checkpoint)
    REPO_CMD+=(--mode staged)
    DOCS_GATE_CMD+=(--mode staged)
    ;;
  push)
    REPO_CMD+=(--mode push)
    if [[ -n "$REV_RANGE" ]]; then
      REPO_CMD+=(--range "$REV_RANGE")
    fi
    if [[ -z "$BASE_REF" ]]; then
      BASE_REF="$(default_upstream_base)"
    fi
    if [[ -z "$BASE_REF" ]]; then
      echo "push mode requires --base <ref> or a configured upstream branch" >&2
      exit 2
    fi
    DOCS_GATE_CMD+=(--mode push --base "$BASE_REF")
    ;;
  *)
    echo "Unsupported mode: $MODE" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ "$SKIP_ECOSYSTEM" -eq 1 ]]; then
  DOCS_GATE_CMD+=(--skip-ecosystem)
fi

run_cmd "${REPO_CMD[@]}"
run_cmd "${DOCS_GATE_CMD[@]}"

audit_command=scan
for ci_flag in "${CI:-}" "${GITHUB_ACTIONS:-}"; do
  case "$ci_flag" in
    ""|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) ;;
    *) audit_command=check ;;
  esac
done
audit_status=0
if [[ "$RUN_AUDIT" -eq 1 ]]; then
  if [ -z "${AUDIT_BIN:-}" ]; then
    AUDIT_BIN="$(git -C "$ROOT" config --local --get generalAuditor.root || true)"
  fi
  case "$AUDIT_BIN" in
    /*) ;;
    *) echo 'General-Auditor requires an absolute trusted root; use GENERAL_AUDITOR_ROOT or local git config generalAuditor.root.' >&2; exit 2 ;;
  esac
  if [ ! -f "$AUDIT_BIN/action_entry.py" ]; then
    echo 'General-Auditor root must contain action_entry.py.' >&2
    exit 2
  fi
  if git -C "$AUDIT_BIN" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "General-Auditor commit: $(git -C "$AUDIT_BIN" rev-parse HEAD)"
  fi
  audit_status=0
  "$PYTHON_BIN" -I "$AUDIT_BIN/action_entry.py" "$audit_command" --policy-root "$AUDIT_BIN" --directory "$ROOT" --repository "Unka-Malloc/vityo-nightly" --scope history || audit_status=$?
  "$PYTHON_BIN" -I "$AUDIT_BIN/action_entry.py" "$audit_command" --policy-root "$AUDIT_BIN" --directory "$ROOT" --repository "Unka-Malloc/vityo-nightly" --scope worktree || audit_status=$?
else
  log "General-Auditor skipped"
fi

if [[ "$RUN_HEALTH" -eq 1 ]]; then
  run_cmd "${HEALTH_CMD[@]}"
else
  log "checkpoint-health skipped"
fi

PRODUCT_GATE_STATUS="skipped"
if is_true "${CI:-}" || is_true "${GITHUB_ACTIONS:-}" || is_true "${VITYO_PRODUCT_GATE:-}"; then
  log "ecosystem product gate is required"
  PRODUCT_GATE_CMD=(
    "$PYTHON_BIN"
    scripts/ecosystem-product-gate.py
  )
  if [[ -n "${VITYO_PRODUCT_PLATFORM:-}" ]]; then
    PRODUCT_GATE_CMD+=(--platform "$VITYO_PRODUCT_PLATFORM")
  fi
  if [[ -n "${VITYO_PRODUCT_STYIO_BIN:-}" ]]; then
    PRODUCT_GATE_CMD+=(--styio-bin "$VITYO_PRODUCT_STYIO_BIN")
  fi
  if [[ -n "${VITYO_PRODUCT_PAFIO_BIN:-}" ]]; then
    PRODUCT_GATE_CMD+=(--pafio-bin "$VITYO_PRODUCT_PAFIO_BIN")
  fi
  if [[ -n "${VITYO_PRODUCT_GATE_OUTPUT:-}" ]]; then
    PRODUCT_GATE_CMD+=(--output "$VITYO_PRODUCT_GATE_OUTPUT")
  fi
  PRODUCT_GATE_CMD+=(--require-real-matrix --json)
  if PRODUCT_GATE_OUTPUT="$("${PRODUCT_GATE_CMD[@]}" 2>&1)"; then
    PRODUCT_GATE_STATUS="proven"
    log "$PRODUCT_GATE_OUTPUT"
  else
    PRODUCT_GATE_STATUS="failed"
    log "$PRODUCT_GATE_OUTPUT"
    log "product-gate-status=$PRODUCT_GATE_STATUS"
    exit 1
  fi
else
  log "ecosystem product gate skipped locally; set VITYO_PRODUCT_GATE=1 to require it"
fi

log "product-gate-status=$PRODUCT_GATE_STATUS"
if [[ "$audit_status" -eq 0 ]]; then log "all required checks passed"; fi
exit "$audit_status"
