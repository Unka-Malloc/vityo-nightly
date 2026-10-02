# Delivery Gate

**Purpose:** Document the shared local and CI delivery entrypoint that composes repository hygiene, documentation checks, audit, deterministic health, and the required product matrix.

**Last updated:** 2026-10-02

## Commands

Local checkpoint delivery:

```bash
./scripts/delivery-gate.sh --mode checkpoint
```

Branch-delivery mode requires the actual target branch and candidate range. CI supplies both from the event being checked:

```bash
./scripts/delivery-gate.sh --mode push --base <target-ref> --range <base>..<candidate>
```

For docs/process-only changes whose code tests and health checks are out of scope:

```bash
./scripts/delivery-gate.sh --mode checkpoint --skip-health
```

Do not use the skip flags to claim a skipped step passed. `--skip-audit` is limited to a delivery whose separate required `styio-audit` workflow covers the check or a separately scoped recovery. `--skip-ecosystem` is for targeted recovery, not normal CI.

## Gate Composition

1. Repository hygiene checks the staged tree in checkpoint mode or the specified incoming range in push mode.
2. The docs gate checks current documentation and, unless explicitly skipped for targeted recovery, records ecosystem CLI document consistency.
3. The external `styio-audit` executable runs when available; the script uses its local security/architecture policy gates when the external executable is unavailable. A CI job configured to skip this stage does not establish an audit result; the separate `styio-audit` job must be observed.
4. Unless `--skip-health` is set, the gate runs [Checkpoint Health](./CHECKPOINT-HEALTH.md), which owns discovered Python tests, Flutter coverage, deterministic Agent/IDE integrations, language fixtures, and permanent Prototype tests.
5. On CI, or when `VITYO_PRODUCT_GATE=1` is set, the ecosystem product gate is required and must pass with the real configured Styio and Pafio executables. A normal local run without that request records an explicit product-gate skip.

The gate is an engineering entrypoint, not proof of a live provider conversation, installed-client test, release package signature, or user acceptance scenario. Local passes and configured remote Actions remain separate evidence.

## Configured GitHub Actions Lanes

The current workflow configuration includes:

| Workflow/job | Evidence lane |
|---|---|
| `repo-hygiene` | Tracked-tree and repository governance checks |
| `audit` | Security, supply-chain, dependency, architecture, product-line, and license checks |
| `styio-audit` | External released audit policy |
| `project-coverage-gate` | Direct Python and Flutter coverage run |
| `local-ci-gate` | Linux, Windows, and macOS delivery, native build, and platform-specific checks |
| `windows-native` | Additional Windows validation and artifact lane |

Workflow files describe configured checks, not observed results. Confirm required status names and current Ruleset state only when an authorized task needs that remote governance fact. Preserve the status output for the exact candidate commit; a queued or unobserved run is unresolved.
