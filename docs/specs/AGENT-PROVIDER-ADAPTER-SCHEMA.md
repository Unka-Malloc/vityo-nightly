# Agent Provider Configuration

**Purpose:** Define the non-secret configuration contract for the first-party Coding Agent's
OpenAI-compatible chat provider.

**Last updated:** 2026-10-05

**Status:** Current Rust provider contract. A deterministic provider test does not establish live
provider availability, account authorization, or user acceptance.

## Ownership And Scope

The provider, model, limits, and credential lookup belong to the independent Coding Agent runtime.
The IDE communicates with the Agent through the shared protocol and never parses this file or
connects directly to a model provider. This contract selects one provider adapter,
`openai_compatible_chat`; it does not define a provider registry, adapter-module format, local
bridge, fallback chain, or provider-specific IDE settings.

The only product process command is
`vityo-coding-agent --stdio-agent --provider-config ABSOLUTE_PATH --session-dir ABSOLUTE_PATH`.
ACP stdio is the same control surface for GUI and non-GUI hosts; there is no separate
inspect-only/headless CLI. `--version` and `--help` do not need runtime paths. The packaged Vityo
descriptor resolves both paths under the application support directory:
`vityo-coding-agent/provider.json` and `vityo-coding-agent/sessions`. Standalone callers provide
both absolute paths explicitly. The session store path is independent of the configuration file;
the configuration can be read-only or stored elsewhere.

The selected Flow Hero client attaches this descriptor only when a non-empty `VITYO_WORKSPACE` is
explicitly configured. Without that workspace scope, the client remains in demo mode and launches
no first-party Agent process; the workspace root is not inferred from either runtime path.

## JSON Shape

The file is non-secret JSON. Its exact field names follow the Rust deserializer's camel-case
contract:

```json
{
  "adapter": "openai_compatible_chat",
  "endpointBase": "https://provider.example/v1",
  "model": "example-model",
  "capabilities": {
    "contextTokens": 64000,
    "outputTokens": 8192,
    "supportsTools": true,
    "maxConcurrency": 1
  },
  "limits": {
    "maxTotalTokens": 72192,
    "maxCostMicros": null,
    "maxBufferedOutputBytes": 262144,
    "maxToolArgumentBytes": 65536,
    "maxBufferedToolBytes": 262144,
    "maxPendingToolCalls": 16,
    "maxToolCalls": 64,
    "maxToolSchemaBytes": 262144
  },
  "auth": {
    "mode": "bearer_token",
    "secretRef": {
      "service": "vityo-coding-agent",
      "account": "example-provider-account"
    }
  }
}
```

For an endpoint that requires no authentication, use `"auth": { "mode": "none" }` and omit
`secretRef`. For bearer authentication, provide a non-empty `secretRef.service` and
`secretRef.account`; the runtime resolves that reference from the native credential store. The
reference identifies a credential and never contains its value.

`capabilities.contextTokens` is required. It is the model's full per-generation context window,
including both input and output, and it also drives history compaction (see below).

`capabilities.outputTokens` and `limits.maxTotalTokens` are optional. Omission of
`capabilities.outputTokens` means the provider declares no separate output ceiling: requests omit
`max_completion_tokens` unless the caller supplies an output limit. The full context window still
applies. An explicit output limit is checked together with estimated request input against
`contextTokens`, and reported input plus output usage for each provider attempt must also fit the
full context window.

An explicit `maxTotalTokens` caps reported input-plus-output usage accumulated for one routed
generation request, including any permitted provider fallback attempts. It does not span separate
ReAct/tool rounds. When an output limit is finite, estimated input plus requested output is
preflighted against both the context window and this routed-generation cap; reported usage is
checked after each attempt. An omitted `maxTotalTokens` removes only this routed-generation cap,
not the model's context-window limit. Provide both optional limits to have `outputTokens` also
validated against `maxTotalTokens`.

## Context Compaction

`capabilities.contextTokens` feeds a Pi-style compaction policy so a small window compacts earlier
than a large one:

1. Before compaction, reserve at least the configured maximum output, or the proportional default
   when that is larger: `reserve = min(contextTokens, max(outputTokens,
   min(16384, ceil(contextTokens / 4))))`. With no configured output ceiling, the proportional
   default is used.
2. Compaction triggers only when the estimated request (system prompt, retained turns, current
   prompt, and tool schemas, estimated at one token per four bytes) exceeds
   `contextTokens - reserve`.
3. When triggered, the newest turns are kept verbatim up to `keepRecent = min(20000,
   ceil(contextTokens / 2), ceil((contextTokens - reserve) / 2))`, always retaining at least the
   latest turn.
4. Older turns are summarized deterministically by the existing conversation compactor, with the
   summary bounded by `min(4096, contextTokens / 8)` tokens. Secret redaction is unchanged.

Compaction cannot remove the current prompt or system/tool definitions. If those inputs and the
requested output cannot fit together in the context window, the request fails its budget check
before provider I/O.

`16384` (output reserve), `20000` (hot window), and `4096` (summary) are Pi's defaults; the
per-window fractions keep them proportional for windows smaller than those defaults.

## Validation And Safety

1. The runtime reads an absolute config path. The JSON file is bounded to 64 KiB and rejects unknown
   fields.
2. `adapter` must equal `openai_compatible_chat`; `model` and `endpointBase` must be valid and
   non-empty. Endpoint URLs cannot embed user information, query parameters, or fragments.
3. `capabilities.contextTokens` must be positive. A configured `outputTokens` must be positive and
   cannot exceed `contextTokens`; when both `outputTokens` and `maxTotalTokens` are present,
   `outputTokens` cannot exceed `maxTotalTokens`. A configured `maxTotalTokens` must be positive;
   omission removes only the matching output or routed-generation limit.
4. `limits.maxCostMicros` is optional. The optional buffered-output, tool-argument, buffered-tool,
   pending-tool, tool-call, and tool-schema limits default respectively to 262144, 65536, 262144,
   16, 64, and 262144 when omitted.
5. Provider configuration may contain an endpoint, model, declared limits, and a credential
   reference, but never a raw key or bearer value. Raw credentials must not appear in argv, ACP
   messages, diagnostics, logs, or durable journals.
6. Provider request lifetime follows the explicit task budget and cancellation token. There is no
   arbitrary mandatory wall-clock timeout default.
7. Provider network requests use TLS. A local HTTP fixture is test-only and cannot authorize a
   plaintext production endpoint.

Missing configuration and unavailable native credentials return typed configuration or
credential-store failures; they never produce a fabricated Agent completion. The Linux launcher
may pass only the explicitly approved session variables needed to reach the native secret service;
it must not forward arbitrary environment values or credential contents.

## ACP Session Attachments

The current first-party ACP host supports standard filesystem and terminal operations plus the
correlated `_vityo.dev/workspace-change-proposal` extension. `session/new` and `session/load`
explicitly reject non-empty `mcpServers` with JSON-RPC error `-32003`; empty attachment lists are
accepted. The Rust MCP client library, tool catalog, and peer tests are maintained, but they do not
provide a production MCP server attachment lifecycle. The runtime does not silently ignore an
attachment request.

## Deterministic Verification And Live Acceptance

The production configuration parser accepts HTTPS endpoints only. Rust unit tests use a private
`cfg(test)` loopback transport seam to exercise the same provider request, stream reducer, and Agent
continuation code against deterministic local HTTP/SSE fixtures. That seam bypasses only production
endpoint validation while injecting the test client; there is no production HTTP flag and no
certificate-trust override. Synthetic credentials keep fixture values out of the native credential
store. The cases cover multi-turn tool-call/result history, streamed frame assembly, cancellation,
malformed responses, provider errors, and configuration/credential failures.

The executable's ACP readiness checks use explicit absolute provider and session paths with a valid
HTTPS `auth.mode: none` configuration and make no provider request. Deterministic Agent tests cover
the actual provider stream/tool continuation through an isolated test transport, not an external
service. No deterministic engineering test contacts an external provider.

Real provider conversations and real development tasks remain a separate user-authorized workflow.
This configuration contract, an adapter test, a package, or a successful client startup probe does
not establish live endpoint availability, account authorization, model behavior, or user acceptance.
