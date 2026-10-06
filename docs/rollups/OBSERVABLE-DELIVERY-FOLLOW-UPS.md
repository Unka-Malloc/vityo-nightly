# Observable Delivery Follow-Ups

**Purpose:** Point Vityo agents at the unapproved observable-graph follow-ups, especially the execution-adapter envelope mismatch that dropped real Pafio receipts.

**Last updated:** 2026-10-05

**Status:** Unapproved. Do not implement these items from this rollup. Item 1 was fixed outside this rollup and is kept here as the closure record.

The full cross-repo list lives in the Styio rollup `docs/rollups/OBSERVABLE-DELIVERY-FOLLOW-UPS.md` on `styio-nightly`. Vityo-owned entries:

1. **Fixed (2026-10-05).** `execution_adapter_io.dart` required a `workflow_payload_version` envelope that Pafio never emits, so real Pafio sessions lost receipt, diagnostics, and runtime events to a silent null. The adapter now parses the current `{action, command, intent, message, mode, plan, profile, status, styio, sync, target}` envelope, reads the schema-v1 receipt from `<plan.build_root>/receipt.json` and the JSONL diagnostics from `<plan.diag_dir>/diagnostics.jsonl` through the vityod file-system scope, derives the session id from the receipt, and surfaces an unreadable or malformed envelope/receipt as a structured failure session rather than a silent null. The execution-adapter fixtures were converted to the current shape.
2. **Medium.** Publishing identical snapshot bytes leaves the Observable panel stuck at `refreshing`.
3. Language and compiler follow-ups (lineage producers, wait-reason runtime, S3 budget approval) are Styio-owned and stay unapproved here.
