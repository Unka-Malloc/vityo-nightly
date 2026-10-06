# Live Provider Acceptance Boundary

**Purpose:** Keep external-provider acceptance separate from deterministic engineering coverage and
protect credentials and conversation data.

**Last updated:** 2026-10-02

## Engineering Verification

Provider configuration and the OpenAI-compatible adapter belong to the independent Coding Agent
runtime. The selected non-secret JSON contract is documented in
[`AGENT-PROVIDER-ADAPTER-SCHEMA.md`](../specs/AGENT-PROVIDER-ADAPTER-SCHEMA.md). Engineering
coverage uses the production adapter against a deterministic local HTTP/SSE fixture, synthetic
credential resolution, and protocol/tool fixtures. It does not require cloud credentials or make a
real provider request.

Provider configuration stores only endpoint/model/limits and an OS credential-service/account
reference. A raw API key or bearer value must not be written to the config file, command arguments,
IDE state, ACP messages, logs, test artifacts, or durable session journal.

## Live Acceptance

This repository does not define a live-provider CI lane or initiate a real model conversation as an
engineering test. Real provider conversations and real development tasks belong to the user's
designated Agent on an explicit task. Installing or opening the client, an adapter fixture test, a
provider-config parser, or the startup probe does not authorize or establish that acceptance.

If the user explicitly runs a live acceptance task, record only whether the user-authorized request
reached the selected provider and whether the expected structured protocol outcome was observed.
Do not store prompts, model responses, credentials, provider account identifiers, private endpoint
details, backend payloads, or raw logs in repository evidence. Keep any required report redacted and
limited to the stage outcome and recovery category.

## Recovery And Reporting

Treat missing configuration, unavailable native credential service, provider connection failure,
authentication failure, quota response, malformed response, and cancellation as distinct outcomes.
The provider runtime must expose a safe error category and recovery action without echoing secrets,
request bodies, or private service data. Deterministic fixture failures are repaired as engineering
defects; external-provider failure remains live-acceptance evidence for the explicitly assigned
Agent.
