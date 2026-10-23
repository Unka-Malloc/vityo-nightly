# Pafio Workflow Success Payloads

**Purpose:** 冻结 `Vityo` 对 `pafio` workflow success payload 的 handoff 要求。

**Last updated:** 2026-10-15

## 1. Current Project Execution Payloads

The local project route invokes `pafio --json check`, `pafio --json build`,
`pafio --json run`, or `pafio --json test` with the selected manifest and
explicit `--styio-bin`. The success envelope contains command metadata,
`status`, and a `plan` object. Vityo consumes the returned `plan.path`,
`plan.build_root`, `plan.artifact_dir`, and `plan.diag_dir`.

Three per-invocation paths anchor each run for consumers:

- `receipt_path`: `<plan.build_root>/receipt.json` — the schema-1 Styio
  receipt; its artifact list, `phases`, `session_id`, and `outputs`
  references identify the actual invocation files.
- `diagnostics_path`: `<plan.diag_dir>/diagnostics.jsonl` — truncated and
  rewritten per invocation, so its entries belong to that run alone.
- `runtime_events_path`: the receipt's `outputs.runtime_events_path`
  (`<plan.build_root>/runtime-events.jsonl`) — the runtime event stream the
  observable pipeline publishes from.

There is no required inline parsed receipt or runtime-event array in Pafio's
success envelope. The existing Vityo receipt decoder remains the single
receipt projection; Pafio keeps the compiler receipt opaque.

A stable `plan.cache_key` is cache identity, not output ownership. Each actual
invocation allocates its own output directory. Consumers must follow returned
paths and receipt references, retain prior artifacts for delayed consumers and
parent snapshots, and never reconstruct output paths from the cache key.
Failure invalidates the current success projection without deleting earlier
artifacts. A `planned` dry run does not supply an execution receipt.

The ordinary non-JSON command route preserves child stdout for exact task
result expectations. JSON mode supplies the workflow envelope rather than
embedding captured child stdout. Process exit and structured payload status,
not prose matching, determine production success. Static and runtime
observation remain explicit opt-ins; retained-parent delta and
`full_snapshot_required` / `parent_unreadable` are consumed through the existing
snapshot and receipt contracts.

## 2. Stable JSON Success For Supporting Commands

除 `workflow_success_payloads` 外，`Vityo` 当前还依赖这些 canonical CLI forms 的成功 JSON：

```text
pafio --json sync --manifest-path <path> ...
pafio --json vendor --manifest-path <path> ...
pafio --json pack --manifest-path <path> ...
pafio --json publish --manifest-path <path> --dry-run
pafio --json publish --manifest-path <path> --registry <path-or-url>
```

这些 supporting commands 当前可以不是共享 published family，但成功时仍必须：

1. 向 stdout 写一个稳定 JSON object
2. 至少包含 `command`
3. 至少包含 `message`
4. 按命令补充路径或状态字段，例如 `archive_path`、`package` 或 registry 状态

## 3. Rules

1. 不能只有 failure JSON；成功也必须有稳定机器输出。
2. `check/build/run/test` consume the nested current workflow envelope described above.
3. supporting commands 的成功 JSON 也必须稳定，因为 `Vityo` 已通过这些命令驱动 sync/vendor 与 pack/publish。
4. `Vityo` 不解析 prose stderr 来判断 workflow 是否成功。
