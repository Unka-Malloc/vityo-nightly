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
    # host-jmfne0vj stopped at pinned-toolchain admission; host-_7p0g4aw passed
    # the pinned Rust coverage tool preparation and Flutter analysis, then the
    # host interpreter could not import coverage.py. host-37qqo58a ran the
    # remaining commands under .venv and stopped inside Python coverage
    # collection on resolver-environment test isolation; host-__2_7q6x passed
    # those legs and stopped on proxy-routed dev-server tests. host-wp6g5gps
    # passed the Python gate and both cargo builds, then flutter test
    # --coverage stalled: the host's 256-FD soft limit could not hold the
    # per-suite development-service children, suite loads froze for hours and
    # the process was SIGKILLed. final.py now raises the open-file soft limit
    # for its spawned tree. host-cizah2v_ then stopped at input admission:
    # the fifth run's own required cargo build had relinked vityod and the
    # owning sibling's authorized final repair had rebuilt the in-place
    # styio candidate, so strict accepted-stat equality could never pass
    # again. Admission now accepts a stat attested by an authorized run
    # record (this stage's own selected-after, the owning sibling's own
    # final build records) and still fails closed on unexplained drift.
    # The documented repository virtual environment
    # supplies coverage.py; verified retained passes are not replayed.
    PYTHON="${ROOT}/.venv/bin/python3"
    [ -x "$PYTHON" ] || PYTHON="python3"
    "$PYTHON" docs/plans/task-resource-delivery/final.py --remaining-local \
      --completed rust-coverage-tools --completed flutter-analysis \
      --platform "${VITYO_PRODUCT_PLATFORM:?Set host platform}" \
      --styio-bin "${STYIO_BIN:?Set the current-source Styio binary}" \
      --pafio-bin "${PAFIO_BIN:?Set the current-source Pafio binary}"
    ;;
  review)
    git diff --check
    ;;
  *) echo "usage: checks.sh {baseline|focused|integration|final|review}" >&2; exit 2 ;;
esac
