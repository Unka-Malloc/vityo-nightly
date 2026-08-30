# Credential DataStore

**Purpose:** Document the `docs/design/environment/configuration-store/credential-data-store/` collection scope, ownership, and maintenance rules.
**Last updated:** 2026-08-31

`Credential DataStore` belongs to Configuration. It is the storage boundary for tokens, registry credentials, remote-service credentials, and other secret values that must not be mixed into ordinary configuration files.

## 1. Position

```text
Configuration / Credential DataStore
  -> stores secret values behind a credential key

Configuration / ordinary settings
  -> stores CredentialReference only
  -> never stores raw secret values
```

## 2. Responsibility

| Responsibility | Meaning |
|---|---|
| Secret value ownership | Own token and credential values. |
| Credential reference | Provide stable keys that ordinary settings can reference. |
| Redacted metadata | Expose display-safe metadata without leaking secret values. |
| Backend selection | Select and verify the operating system's secure credential backend. |
| Scope separation | Separate user, workspace, toolchain, and service credentials. |

## 3. Non-Responsibilities

| Not Owned Here | Owner |
|---|---|
| Network authentication flow | Network or service connector. |
| Registry protocol | Toolchain or package manager. |
| Plain product settings | Configuration store. |
| UI for credential editing | Interaction / Appearance. |
| Hosted or remote vaults | A future provider-neutral service adapter. |

## 4. Data Rule

Ordinary configuration may store this:

```text
CredentialReference
  key
  kind
  displayName
```

The Configuration Store must round-trip `CredentialReference` values exactly. A setting may persist credential references beside ordinary non-secret values, and loading that setting must restore the reference key, kind, scope, target id, and display name so callers can resolve the real secret through `CredentialDataStore`.

Ordinary configuration must not store this:

```text
secretValue
rawToken
password
privateKey
```

## 5. Runtime Contract

```text
CredentialDataStore
  write(record)
  read(key)
  delete(key)
  list(scope)
  snapshot()
```

`snapshot()` must return redacted metadata only. It must be safe to show in logs, settings pages, and diagnostics panels.

## 6. Production Implementation

The production path is:

```text
ConfigurationStore
  -> CredentialStoragePolicyEnforcingDataStore
    -> PlatformSecureCredentialDataStore
      -> PlatformSecureJsonCredentialStorageAdapter
        -> FlutterSecureStorageKeyValueBackend
          -> operating-system secure storage
```

`PlatformSecureJsonCredentialStorageAdapter` stores one versioned JSON envelope per credential. Stable credential ids are encoded into storage-safe keys. Raw envelopes are passed directly to the secure-storage plugin and never enter Foundation DataStore, shared preferences, logs, diagnostics, or configuration snapshots.

`PlatformSecureCredentialStorageAdapterRegistry` owns backend selection:

| Target | Backend | Production route |
|---|---|---|
| macOS | Keychain | Enabled after live write/read/delete verification |
| iOS | Keychain | Enabled after live write/read/delete verification |
| Android | RSA OAEP + AES-GCM encrypted storage | Enabled after live write/read/delete verification |
| Windows | AES-GCM storage with its key protected by Windows Credential Manager | Enabled after live write/read/delete verification |
| Linux | libsecret | Enabled after live write/read/delete verification |
| Web | WebCrypto-backed browser storage | Not approved for persistent production credentials |

App bootstrap performs an isolated probe and removes the probe value before selecting a backend. If the native route is unavailable, the active store is session memory wrapped by `CredentialStoragePolicyEnforcingDataStore`; long-lived credentials are rejected, while explicitly short-lived credentials may remain in memory for the current process.

`InMemoryCredentialDataStore` and `InMemoryPlatformSecureCredentialStorageAdapter` are non-production test fixtures. They are not persistence alternatives.

## 7. Security Invariants

1. Ordinary settings store only `CredentialReference` values.
2. No plaintext credential implementation may use Foundation DataStore or shared preferences.
3. `snapshot()` and Settings expose `CredentialMetadata` or health facts only; neither may contain `secretValue`.
4. A native backend is production-ready only after the live probe succeeds.
5. Failure messages never include plugin exceptions, paths, usernames, or secret material.
6. Web and unavailable native backends cannot accept long-lived secrets.

## 8. Platform Build Requirements

- macOS uses the standard application Keychain without shared access groups so ad-hoc local development builds remain runnable; iOS enables Keychain Sharing entitlements for its signed runner.
- Android uses API 23 or newer and disables application backup for encrypted credential state.
- Linux development and CI images install `libsecret-1-dev`; deployed desktop environments also need a compatible keyring service.
- Windows build tools include ATL for the native plugin.

Do not reintroduce plaintext credential persistence as an ordinary configuration setting or Foundation DataStore namespace.
