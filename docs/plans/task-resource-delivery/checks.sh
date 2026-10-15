#!/usr/bin/env bash
# Registered engineering entrypoints. Defining a command does not execute it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
case "${1:-}" in
  baseline)
    python3 docs/plans/task-resource-delivery/baseline.py
    ;;
  focused)
    python3 docs/plans/task-resource-delivery/focused.py
    ;;
  integration)
    python3 scripts/ecosystem-product-gate.py --platform "${VITYO_PRODUCT_PLATFORM:?Set host platform}" --styio-bin "${STYIO_BIN:?Set the current-source Styio binary}" --pafio-bin "${PAFIO_BIN:?Set the current-source Pafio binary}" --lspd-bin "${ROOT}/../styio-nightly/build/default/bin/styio_lspd" --vityod-bin "${ROOT}/products/vityo_app/native/vityod/target/debug/vityod" --require-real-matrix --json
    ;;
  final)
    # The registered entrypoint is the complete local engineering run through
    # final.py's default mode (scripts/vityo.py test --mode local). A diagnosed
    # failure may justify a one-shot recovery selection for that host attempt
    # (final.py --remaining-local --completed <retained steps>); such a
    # selection narrows a single run's record and never replaces this form.
    # The documented repository virtual environment supplies coverage.py.
    PYTHON="${ROOT}/.venv/bin/python3"
    [ -x "$PYTHON" ] || PYTHON="python3"
    "$PYTHON" docs/plans/task-resource-delivery/final.py \
      --platform "${VITYO_PRODUCT_PLATFORM:?Set host platform}" \
      --styio-bin "${STYIO_BIN:?Set the current-source Styio binary}" \
      --pafio-bin "${PAFIO_BIN:?Set the current-source Pafio binary}"
    ;;
  review)
    git diff --check
    ;;
  *) echo "usage: checks.sh {baseline|focused|integration|final|review}" >&2; exit 2 ;;
esac
