//! Tool permissions and effect policy.

use std::collections::{BTreeSet, HashMap, VecDeque};

use crate::tools::ToolRisk;

/// The root identity and path domain an Agent operation is allowed to address.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolRootDomain {
    ResourceUri(String),
    HostManaged,
}

/// A workspace resource explicitly authorized for an Agent session.
#[derive(Clone, PartialEq, Eq)]
pub struct ToolRoot {
    pub id: String,
    pub domain: ToolRootDomain,
}

impl ToolRoot {
    pub fn resource_uri(id: impl Into<String>, uri: impl Into<String>) -> Option<Self> {
        let root = Self {
            id: id.into(),
            domain: ToolRootDomain::ResourceUri(uri.into()),
        };
        (!root.id.trim().is_empty()
            && matches!(&root.domain, ToolRootDomain::ResourceUri(uri) if parse_resource_uri(uri).is_some()))
        .then_some(root)
    }

    pub fn host_managed(id: impl Into<String>) -> Option<Self> {
        let root = Self {
            id: id.into(),
            domain: ToolRootDomain::HostManaged,
        };
        (!root.id.trim().is_empty()).then_some(root)
    }
}

/// A validated path scope returned by the resolver appropriate to its domain.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolPathScope {
    ResourceUri {
        requested_uri: String,
        resolved_uri: String,
    },
    HostManaged {
        root_id: String,
        relative_path: String,
    },
}

/// Immutable policy inputs for one Agent turn or operation batch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExecutionPolicy {
    pub version: u64,
    pub allowed_risks: BTreeSet<ToolRisk>,
    pub allowed_network_hosts: BTreeSet<String>,
    pub max_result_bytes: usize,
    pub deny_raw_credentials: bool,
}

impl ExecutionPolicy {
    pub fn new(
        version: u64,
        allowed_risks: impl IntoIterator<Item = ToolRisk>,
        allowed_network_hosts: impl IntoIterator<Item = String>,
        max_result_bytes: usize,
    ) -> Option<Self> {
        (max_result_bytes > 0).then(|| Self {
            version,
            allowed_risks: allowed_risks.into_iter().collect(),
            allowed_network_hosts: allowed_network_hosts
                .into_iter()
                .map(|host| host.trim().to_ascii_lowercase())
                .filter(|host| !host.is_empty())
                .collect(),
            max_result_bytes,
            deny_raw_credentials: true,
        })
    }
}

/// A user-approved grant constrained to one session, tool, risk, and root.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionGrant {
    pub id: String,
    pub session_id: String,
    pub tool_id: String,
    pub risks: BTreeSet<ToolRisk>,
    pub root_ids: BTreeSet<String>,
}

impl PermissionGrant {
    pub fn new(
        id: impl Into<String>,
        session_id: impl Into<String>,
        tool_id: impl Into<String>,
        risks: impl IntoIterator<Item = ToolRisk>,
        root_ids: impl IntoIterator<Item = String>,
    ) -> Option<Self> {
        let grant = Self {
            id: id.into(),
            session_id: session_id.into(),
            tool_id: tool_id.into(),
            risks: risks.into_iter().collect(),
            root_ids: root_ids.into_iter().collect(),
        };
        (!grant.id.trim().is_empty()
            && !grant.session_id.trim().is_empty()
            && !grant.tool_id.trim().is_empty()
            && !grant.risks.is_empty())
        .then_some(grant)
    }
}

/// Bounded grants with an O(1) session/tool lookup before checking grant scope.
#[derive(Debug)]
pub struct PermissionGrantStore {
    max_grants: usize,
    grants: HashMap<String, PermissionGrant>,
    by_tool: HashMap<(String, String), BTreeSet<String>>,
    order: VecDeque<String>,
    version: u64,
}

impl PermissionGrantStore {
    pub fn new(max_grants: usize) -> Option<Self> {
        (max_grants > 0).then(|| Self {
            max_grants,
            grants: HashMap::new(),
            by_tool: HashMap::new(),
            order: VecDeque::new(),
            version: 0,
        })
    }

    pub fn version(&self) -> u64 {
        self.version
    }

    pub fn active_grant_count(&self) -> usize {
        self.grants.len()
    }

    pub fn grant(&mut self, grant: PermissionGrant) -> bool {
        if grant.id.trim().is_empty()
            || grant.session_id.trim().is_empty()
            || grant.tool_id.trim().is_empty()
            || grant.risks.is_empty()
        {
            return false;
        }

        self.remove(&grant.id);
        let key = (grant.session_id.clone(), grant.tool_id.clone());
        self.by_tool
            .entry(key)
            .or_default()
            .insert(grant.id.clone());
        self.order.push_back(grant.id.clone());
        self.grants.insert(grant.id.clone(), grant);

        while self.grants.len() > self.max_grants {
            if let Some(oldest) = self.order.pop_front() {
                self.remove(&oldest);
            }
        }
        self.version = self.version.wrapping_add(1);
        true
    }

    pub fn revoke(&mut self, grant_id: &str) -> bool {
        let removed = self.remove(grant_id);
        self.version = self.version.wrapping_add(1);
        removed
    }

    pub fn allows(&self, session_id: &str, tool_id: &str, risk: ToolRisk, root_id: &str) -> bool {
        self.by_tool
            .get(&(session_id.to_owned(), tool_id.to_owned()))
            .is_some_and(|ids| {
                ids.iter().any(|id| {
                    self.grants.get(id).is_some_and(|grant| {
                        grant.risks.contains(&risk) && grant.root_ids.contains(root_id)
                    })
                })
            })
    }

    fn remove(&mut self, grant_id: &str) -> bool {
        let Some(grant) = self.grants.remove(grant_id) else {
            return false;
        };
        self.order.retain(|id| id != grant_id);
        let key = (grant.session_id, grant.tool_id);
        if let Some(ids) = self.by_tool.get_mut(&key) {
            ids.remove(grant_id);
            if ids.is_empty() {
                self.by_tool.remove(&key);
            }
        }
        true
    }
}

/// Facts used to decide whether one proposed tool effect is authorized.
#[derive(Clone, PartialEq, Eq)]
pub struct ToolEffect {
    pub tool_id: String,
    pub risk: ToolRisk,
    pub path_scope: Option<ToolPathScope>,
    pub require_host_managed_root: bool,
    pub network_host: Option<String>,
    pub raw_credential_detected: bool,
    pub secret_audience_valid: bool,
}

impl ToolEffect {
    pub fn new(tool_id: impl Into<String>, risk: ToolRisk) -> Self {
        Self {
            tool_id: tool_id.into(),
            risk,
            path_scope: None,
            require_host_managed_root: false,
            network_host: None,
            raw_credential_detected: false,
            secret_audience_valid: true,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PolicyDecisionCode {
    Allowed,
    InvalidPolicy,
    RiskDenied,
    CredentialDenied,
    HostDenied,
    PathDenied,
    PermissionDenied,
}

/// Exact scope required for an explicit user permission grant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolPermissionRequirement {
    pub tool_id: String,
    pub risk: ToolRisk,
    pub root_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PolicyDecision {
    pub code: PolicyDecisionCode,
    pub permission_requirement: Option<ToolPermissionRequirement>,
}

impl PolicyDecision {
    fn deny(code: PolicyDecisionCode) -> Self {
        Self {
            code,
            permission_requirement: None,
        }
    }

    pub fn allowed(&self) -> bool {
        self.code == PolicyDecisionCode::Allowed
    }
}

/// Applies deterministic policy without exposing private denial details to a tool.
#[derive(Clone, Copy, Debug, Default)]
pub struct DefaultPolicyEvaluator;

impl DefaultPolicyEvaluator {
    pub fn evaluate(
        &self,
        effect: &ToolEffect,
        policy: &ExecutionPolicy,
        roots: &[ToolRoot],
        grants: &PermissionGrantStore,
        session_id: &str,
    ) -> PolicyDecision {
        if policy.max_result_bytes == 0 {
            return PolicyDecision::deny(PolicyDecisionCode::InvalidPolicy);
        }
        if !policy.allowed_risks.contains(&effect.risk) {
            return PolicyDecision::deny(PolicyDecisionCode::RiskDenied);
        }
        if (policy.deny_raw_credentials && effect.raw_credential_detected)
            || !effect.secret_audience_valid
        {
            return PolicyDecision::deny(PolicyDecisionCode::CredentialDenied);
        }
        if let Some(host) = effect.network_host.as_deref() {
            let normalized = host.trim().to_ascii_lowercase();
            if normalized.is_empty() || !policy.allowed_network_hosts.contains(&normalized) {
                return PolicyDecision::deny(PolicyDecisionCode::HostDenied);
            }
        }

        let root_id = if effect.require_host_managed_root {
            if let Some(root) = roots
                .iter()
                .find(|root| root.domain == ToolRootDomain::HostManaged)
            {
                root.id.as_str()
            } else {
                return PolicyDecision::deny(PolicyDecisionCode::PathDenied);
            }
        } else if let Some(path_scope) = effect.path_scope.as_ref() {
            match path_scope {
                ToolPathScope::ResourceUri {
                    requested_uri,
                    resolved_uri,
                } => {
                    let Some(requested_uri) = parse_resource_uri(requested_uri) else {
                        return PolicyDecision::deny(PolicyDecisionCode::PathDenied);
                    };
                    let Some(resolved_uri) = parse_resource_uri(resolved_uri) else {
                        return PolicyDecision::deny(PolicyDecisionCode::PathDenied);
                    };
                    let requested_root = matching_root(&requested_uri, roots);
                    let resolved_root = matching_root(&resolved_uri, roots);
                    let (Some(requested_root), Some(resolved_root)) =
                        (requested_root, resolved_root)
                    else {
                        return PolicyDecision::deny(PolicyDecisionCode::PathDenied);
                    };
                    if requested_root.id != resolved_root.id {
                        return PolicyDecision::deny(PolicyDecisionCode::PathDenied);
                    }
                    resolved_root.id.as_str()
                }
                ToolPathScope::HostManaged {
                    root_id,
                    relative_path,
                } => {
                    let has_root = roots.iter().any(|root| {
                        root.id == *root_id && root.domain == ToolRootDomain::HostManaged
                    });
                    let process_at_root =
                        effect.risk == ToolRisk::Process && relative_path.is_empty();
                    if !has_root || !(process_at_root || is_normalized_relative_path(relative_path))
                    {
                        return PolicyDecision::deny(PolicyDecisionCode::PathDenied);
                    }
                    root_id.as_str()
                }
            }
        } else if let Some(root) = roots.first() {
            root.id.as_str()
        } else {
            return PolicyDecision::deny(PolicyDecisionCode::PathDenied);
        };

        if !grants.allows(session_id, &effect.tool_id, effect.risk, root_id) {
            return PolicyDecision {
                code: PolicyDecisionCode::PermissionDenied,
                permission_requirement: Some(ToolPermissionRequirement {
                    tool_id: effect.tool_id.clone(),
                    risk: effect.risk,
                    root_id: root_id.to_owned(),
                }),
            };
        }
        PolicyDecision {
            code: PolicyDecisionCode::Allowed,
            permission_requirement: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ResourceUri {
    scheme: String,
    authority: String,
    segments: Vec<String>,
}

fn parse_resource_uri(input: &str) -> Option<ResourceUri> {
    if input.contains('?') || input.contains('#') {
        return None;
    }
    let (scheme, rest) = input.split_once("://")?;
    if scheme.is_empty()
        || !scheme
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.'))
    {
        return None;
    }
    let (authority, raw_path) = match rest.split_once('/') {
        Some((authority, path)) => (authority, path),
        None => (rest, ""),
    };
    if authority.is_empty() || authority.contains('@') || authority.contains('\\') {
        return None;
    }

    let mut segments = Vec::new();
    for raw_segment in raw_path.split('/') {
        if raw_segment.is_empty() {
            continue;
        }
        let segment = percent_decode_segment(raw_segment)?;
        if segment == ".."
            || segment.contains('/')
            || segment.contains('\\')
            || segment.contains('\0')
        {
            return None;
        }
        if segment != "." {
            segments.push(segment);
        }
    }
    Some(ResourceUri {
        scheme: scheme.to_ascii_lowercase(),
        authority: authority.to_owned(),
        segments,
    })
}

fn percent_decode_segment(raw: &str) -> Option<String> {
    let input = raw.as_bytes();
    let mut decoded = Vec::with_capacity(input.len());
    let mut index = 0;
    while index < input.len() {
        if input[index] == b'%' {
            let high = *input.get(index + 1)?;
            let low = *input.get(index + 2)?;
            decoded.push((hex(high)? << 4) | hex(low)?);
            index += 3;
        } else {
            decoded.push(input[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn matching_root<'a>(candidate: &ResourceUri, roots: &'a [ToolRoot]) -> Option<&'a ToolRoot> {
    roots.iter().find(|root| {
        let ToolRootDomain::ResourceUri(uri) = &root.domain else {
            return false;
        };
        let Some(root_uri) = parse_resource_uri(uri) else {
            return false;
        };
        root_uri.scheme == candidate.scheme
            && root_uri.authority == candidate.authority
            && candidate.segments.len() >= root_uri.segments.len()
            && candidate.segments[..root_uri.segments.len()] == root_uri.segments
    })
}

fn is_normalized_relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path
            .chars()
            .any(|character| matches!(character, '\\' | '\0'))
        && path
            .split('/')
            .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
}

/// Sanitizes schema-independent policy maps before durable logging.
pub fn redact_argument_secrets(
    arguments: &serde_json::Map<String, serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    arguments
        .iter()
        .map(|(key, value)| (key.clone(), redact_value(value, Some(key))))
        .collect()
}

fn redact_value(value: &serde_json::Value, key: Option<&str>) -> serde_json::Value {
    if key.is_some_and(is_sensitive_name) {
        return serde_json::Value::String("[redacted]".to_owned());
    }
    match value {
        serde_json::Value::Object(object) => serde_json::Value::Object(
            object
                .iter()
                .map(|(key, value)| (key.clone(), redact_value(value, Some(key))))
                .collect(),
        ),
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.iter().map(|item| redact_value(item, key)).collect())
        }
        serde_json::Value::String(text) if text.to_ascii_lowercase().starts_with("bearer ") => {
            serde_json::Value::String("[redacted]".to_owned())
        }
        _ => value.clone(),
    }
}

fn is_sensitive_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [
        "token",
        "password",
        "secret",
        "credential",
        "api_key",
        "apikey",
    ]
    .iter()
    .any(|part| lower.contains(part))
}
