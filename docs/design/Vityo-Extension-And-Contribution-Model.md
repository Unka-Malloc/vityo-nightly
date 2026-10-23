# Vityo Extension and Contribution Model

**Purpose:** Define Vityo's Styio-native extension and contribution model — how modules declare capabilities, how contributions are routed, and how the extension host isolates and activates extensions. This is NOT a VS Code extension API clone.

**Owner:** Extension/module architecture owner (`CODEOWNERS` → module_host domain)
**Last updated:** 2026-08-31

---

## 1. Design Principles

1. **Styio-first, not VS Code-compatible.** Vityo extensions use a Styio-native manifest schema and typed contribution model. No attempt is made to load or run VS Code extensions.
2. **Capability-gated activation.** Extensions expose capability flags; the host activates them only when trust, lifecycle state, and the module capability matrix permit.
3. **Trust-matched execution.** Bundled code may use the registered in-process
   host path; installable code must use an OS process, browser Worker, or an
   explicitly configured remote service.
4. **Typed contributions, not string-based.** Contribution points are typed Dart classes, not JSON string identifiers.
5. **Staged updates.** Extensions support staged update cycles: verify → stage → activate → rollback on failure.

## 2. Extension Manifest

### 2.1 Manifest Schema

Extensions declare their identity, capabilities, contributions, and requirements in a manifest:

```dart
class ExtensionManifest {
  final int schemaVersion;
  final String extensionId;
  final String displayName;
  final String version;
  final String publisher;
  final String entrypoint;
  final String? moduleId;
  final List<String> activationEvents;
  final List<ExtensionContributionPoint> contributions;
  final Map<String, bool> capabilities;
  final bool trustedByDefault;
  final Map<String, Object?> metadata;
}
```

Reference: `products/vityo_app/lib/src/view_ide/module_host/extension_manifest_contract.dart`

### 2.2 Manifest Validation

- ID, version, publisher, and entrypoint must be non-empty.
- ID must be unique within the installed extension registry.
- Every contribution must have a non-empty ID and target.
- Schema version and unknown extension fields round-trip through JSON so later
  schema owners can migrate without silently dropping data.
- Activation requires both enabled and trusted state; installed third-party
  extensions are not implicitly trusted.

## 3. Contribution Model

### 3.1 Contribution Points

Vityo defines typed contribution points, each owned by a domain:

| Contribution Point | Domain Owner | Dart Type | Example |
|-------------------|-------------|-----------|---------|
| `commands` | `commands/` | `ExtensionCommandContribution` | Register a command in palette |
| `languages` | `language/` | `ExtensionLanguageContribution` | Register a language service |
| `agents` | `ide/agent_client/` | Agent connection contribution | Register a compatible Agent connection/launcher |
| `debug_adapters` | `debugger/` | `ExtensionDebugContribution` | Register a debug adapter |
| `toolchains` | `toolchain/` | `ExtensionToolchainContribution` | Register a toolchain |
| `themes` | `theme/` | `ExtensionThemeContribution` | Register a theme |
| `views` | `view_render/extensions/` | `ExtensionViewContribution` | Register a UI view |
| `runtime_tasks` | `runtime/` | `ExtensionRuntimeTaskContribution` | Register a runtime task |

Model providers and Agent tools are not IDE contribution points. They belong to the connected Agent
runtime. The retired IDE-side provider/tool contribution kinds are not accepted aliases and must
not be reintroduced.

### 3.2 Contribution Router

The `ExtensionContributionRouter` (at `products/vityo_app/lib/src/view_ide/module_host/extension_contribution_router.dart`) routes contributions to their domain owners. Each domain owner validates and registers the contribution.

### 3.3 Contribution Lifecycle

1. **Declare**: Extension manifest declares contributions.
2. **Validate**: Domain owner validates contribution against capability matrix.
3. **Register**: Valid contribution is registered in domain registry.
4. **Activate**: Contribution becomes active when activation conditions are met.
5. **Deactivate**: Contribution is deactivated on extension unload or capability loss.
6. **Remove**: Contribution is fully removed on extension uninstall.

## 4. Extension Host Isolation

### 4.1 Isolation Levels

| Level | Description | Use Case |
|-------|------------|----------|
| `in-process` | Compiled-in module activates from Vityo's registered host set | Shell, editor, themes |
| `local-process` | Extension runs as a vityod-managed OS process | Language servers, toolchains |
| `web-worker` | Extension runs in a browser Worker | Web language and analysis workers |
| `remote-service` | Extension connects to an explicitly configured remote service | Cloud-backed services |
| `blocked` | Trust or platform policy rejected execution | Untrusted or unsupported extensions |

### 4.2 Isolation Rules

- `in-process` extensions are compiled into Vityo and activate only from the
  bundled module registry.
- `local-process` extensions launch through the platform `ProcessManager`, so
  vityod owns process identity and cancellation.
- `web-worker` extensions use the browser Worker constructor and the browser's
  origin/security policy.
- `remote-service` extensions require a registered client and explicit network
  permission; the host never silently substitutes another isolation mode.

Reference: `products/vityo_app/lib/src/view_ide/module_host/extension_host_isolation.dart`

### 4.3 Startup execution and telemetry

`ExtensionHostStartupExecutor` consumes the activation supervisor snapshot and
dispatches every active record through the platform launcher registry. Each
record must leave `starting` as either `running` or `failed`; the execution
receipt retains launch identity and both transition events. App bootstrap owns
this receipt and the Extensions surface exposes it under **Activation & Hosts**.

The platform catalog is selected at compile time:

- Native targets register the compiled-in container and managed OS-process
  launcher.
- Web registers the compiled-in container and browser Worker launcher.
- Unsupported targets register only capabilities they can execute; missing
  launchers remain explicit failures instead of false-ready states.

## 5. Extension Lifecycle

### 5.1 Lifecycle States

```
[installed] → [validated] → [staged] → [active]
                                  ↓
                            [rollback] → [staged-previous]
                                  ↓
                            [removed]
```

### 5.2 Lifecycle Hooks

Extensions may implement lifecycle hooks (defined in `extension_lifecycle_hooks.dart`):

- `onInstall()` — one-time setup
- `onActivate()` — called when activation conditions are met
- `onDeactivate()` — called when deactivation is requested
- `onUpdate(fromVersion, toVersion)` — staged update hook
- `onUninstall()` — cleanup

### 5.3 Activation Events

Activation events (modeled after Theia/VS Code concepts but Styio-native):

- `onLanguage:{languageId}` — activate when a file of this language is opened
- `onWorkspaceOpen` — activate when any workspace is opened
- `onCommand:{commandId}` — activate when a specific command is invoked
- `onDebug` — activate when a debug session starts
- `onStartup` — activate at application startup
- `*` — activate immediately on install

## 6. Extension Marketplace

The `ExtensionMarketplace` (at `products/vityo_app/lib/src/view_ide/module_host/extension_marketplace.dart`) provides:

- Workspace-scoped index discovery through an explicitly configured HTTPS URL
  (loopback HTTP is accepted only for local development and native tests).
- Verified-publisher gating plus mandatory SHA-256 comparison against the
  downloaded bytes before any cache write or manifest registration.
- Atomic package caching inside Foundation workspace resources, with failed IO
  batches stopping before lifecycle state can be persisted.
- Install and update confirmation, searchable results, IO progress, and
  receipts in the Extensions surface.
- Persisted index, installation manifest registry, and lifecycle preferences
  shared with the product Settings surface.

`ExtensionMarketplaceController` is the production coordinator. App bootstrap
constructs its platform IO catalog from `NetworkManager`, `FileSystemManager`,
`FoundationResourceCoordinator`, and `FoundationDataStore`; no marketplace
request is made at startup unless the user has configured an index URL.

## 7. Capability Matrix Integration

Extensions expose capability flags in their manifest. The `ModuleCapabilityMatrix` (at `products/vityo_app/lib/src/view_ide/module_host/module_capability_matrix.dart`) gates mounting and activation:

- If a required capability is unavailable, the extension is blocked.
- If a required capability is degraded, the extension activates with limited functionality.
- Capability changes trigger re-evaluation of active extensions.

## 8. Extension Governance

### 8.1 Extension Manifest Schema Test

Every new contribution point must have:
- A manifest schema test in `extension_manifest_contract_test.dart`
- A contribution validation test in the domain owner's test suite
- An activation/deactivation lifecycle test

### 8.2 Extension Security

- Extensions must declare all permissions in their manifest.
- `in-process` extensions are limited to compiled-in, trusted modules.
- `local-process` extensions run with the user's OS permissions; the host
  validates trust and isolation policy before launch.
- `web-worker` extensions remain subject to browser origin and CSP policy.
- `remote-service` extensions require explicit network permission and TLS.

### 8.3 Extension Hygiene

- Extension manifests are validated at install, activation, and periodically.
- Stale extensions (no update in N days, where N is configurable) generate warnings.
- Extensions with known vulnerabilities are blocked from activation.

## 9. Cross-Reference

- [Vityo Mainstream Architecture Alignment](./Vityo-Mainstream-Architecture-Alignment.md)
- [Vityo Protocol And Capability Negotiation](./Vityo-Protocol-And-Capability-Negotiation.md)
- [Vityo Agent-Native IDE Architecture](./Vityo-Agent-Native-IDE-Architecture.md)
- [ADR-0009 Module Runtime and Staged Updates](../adr/ADR-0009-module-runtime-and-staged-updates.md)
- [Module Platform Runbook](../teams/MODULE-PLATFORM-RUNBOOK.md)
- [Extension Module Runbook](../teams/EXTENSION-MODULE-RUNBOOK.md)
