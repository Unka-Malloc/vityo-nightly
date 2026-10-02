use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};

use crate::contracts::JsonObject;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ToolRisk {
    Read,
    Write,
    Process,
    Network,
    Credential,
    Destructive,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolSourceKind {
    Builtin,
    Mcp,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ToolDescriptor {
    pub id: String,
    pub description: String,
    pub source_kind: ToolSourceKind,
    pub input_schema: JsonObject,
    pub output_schema: JsonObject,
    pub risk: ToolRisk,
    pub tags: BTreeSet<String>,
    pub path_argument: Option<String>,
    pub network_host_argument: Option<String>,
    pub secret_arguments: BTreeMap<String, String>,
    pub max_result_bytes: usize,
}

impl ToolDescriptor {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        description: impl Into<String>,
        source_kind: ToolSourceKind,
        input_schema: JsonObject,
        output_schema: JsonObject,
        risk: ToolRisk,
        tags: impl IntoIterator<Item = String>,
        path_argument: Option<String>,
        network_host_argument: Option<String>,
        secret_arguments: BTreeMap<String, String>,
        max_result_bytes: usize,
    ) -> Result<Self, ToolSchemaError> {
        let descriptor = Self {
            id: id.into(),
            description: description.into(),
            source_kind,
            input_schema,
            output_schema,
            risk,
            tags: tags.into_iter().collect(),
            path_argument,
            network_host_argument,
            secret_arguments,
            max_result_bytes,
        };
        if descriptor.id.trim().is_empty()
            || descriptor.description.trim().is_empty()
            || descriptor.max_result_bytes == 0
        {
            return Err(ToolSchemaError::InvalidDescriptor);
        }
        ToolSchema::validate_definition(&descriptor.input_schema, true)?;
        ToolSchema::validate_definition(&descriptor.output_schema, true)?;
        Ok(descriptor)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ToolCatalog {
    version: String,
    tools: BTreeMap<String, ToolDescriptor>,
    truncated: bool,
}

impl ToolCatalog {
    pub fn new(
        version: impl Into<String>,
        tools: impl IntoIterator<Item = ToolDescriptor>,
        truncated: bool,
    ) -> Result<Self, ToolSchemaError> {
        let version = version.into();
        if version.trim().is_empty() {
            return Err(ToolSchemaError::InvalidCatalog);
        }
        let mut indexed = BTreeMap::new();
        for tool in tools {
            if indexed.insert(tool.id.clone(), tool).is_some() {
                return Err(ToolSchemaError::DuplicateToolId);
            }
        }
        Ok(Self {
            version,
            tools: indexed,
            truncated,
        })
    }

    pub fn version(&self) -> &str {
        &self.version
    }

    pub fn tools(&self) -> impl Iterator<Item = &ToolDescriptor> {
        self.tools.values()
    }

    pub fn is_truncated(&self) -> bool {
        self.truncated
    }

    pub fn find(&self, id: &str) -> Option<&ToolDescriptor> {
        self.tools.get(id)
    }

    /// Selects the most relevant tools with deterministic score and ID ordering.
    pub fn relevant_for<'a>(
        &'a self,
        task_tags: &BTreeSet<String>,
        limit: usize,
    ) -> Vec<&'a ToolDescriptor> {
        let mut ranked: Vec<_> = self
            .tools
            .values()
            .filter_map(|tool| {
                let matches = tool.tags.intersection(task_tags).count();
                (task_tags.is_empty() || matches > 0).then_some((matches, tool))
            })
            .collect();
        ranked.sort_unstable_by(|(left_score, left), (right_score, right)| {
            right_score
                .cmp(left_score)
                .then_with(|| left.id.cmp(&right.id))
        });
        ranked
            .into_iter()
            .take(limit)
            .map(|(_, tool)| tool)
            .collect()
    }

    pub fn merge(
        version: impl Into<String>,
        catalogs: impl IntoIterator<Item = ToolCatalog>,
    ) -> Result<Self, ToolSchemaError> {
        let mut tools = Vec::new();
        let mut truncated = false;
        for catalog in catalogs {
            truncated |= catalog.truncated;
            tools.extend(catalog.tools.into_values());
        }
        Self::new(version, tools, truncated)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolSchemaError {
    InvalidDescriptor,
    InvalidCatalog,
    DuplicateToolId,
    RootMustBeObject,
    UnsupportedType,
    InvalidObjectProperties,
    InvalidRequiredProperties,
    InvalidAdditionalProperties,
    InvalidArrayItems,
    ValueTypeMismatch,
    MissingRequiredProperty,
    UnknownProperty,
}

impl ToolSchemaError {
    pub const fn safe_message(self) -> &'static str {
        match self {
            Self::InvalidDescriptor => "Tool descriptor is invalid.",
            Self::InvalidCatalog => "Tool catalog version is invalid.",
            Self::DuplicateToolId => "Tool catalog contains duplicate IDs.",
            Self::RootMustBeObject => "Tool schemas must have object roots.",
            Self::UnsupportedType => "Tool schema uses an unsupported type.",
            Self::InvalidObjectProperties => "Tool object schema is invalid.",
            Self::InvalidRequiredProperties => "Tool required properties are invalid.",
            Self::InvalidAdditionalProperties => "Tool additionalProperties is invalid.",
            Self::InvalidArrayItems => "Tool array item schema is invalid.",
            Self::ValueTypeMismatch => "Tool value does not match its schema.",
            Self::MissingRequiredProperty => "Tool value is missing a required property.",
            Self::UnknownProperty => "Tool value contains an unknown property.",
        }
    }
}

pub struct ToolSchema;

impl ToolSchema {
    pub fn validate_definition(schema: &JsonObject, root: bool) -> Result<(), ToolSchemaError> {
        Self::validate_schema(schema, root)
    }

    pub fn accepts(schema: &JsonObject, value: &Value) -> bool {
        Self::validate_value(schema, value).is_ok()
    }

    pub fn encoded_bytes(value: &Value) -> Option<usize> {
        serde_json::to_vec(value).ok().map(|bytes| bytes.len())
    }

    fn validate_schema(schema: &JsonObject, root: bool) -> Result<(), ToolSchemaError> {
        let kind = schema
            .get("type")
            .and_then(Value::as_str)
            .ok_or(ToolSchemaError::UnsupportedType)?;
        if root && kind != "object" {
            return Err(ToolSchemaError::RootMustBeObject);
        }
        match kind {
            "object" => {
                let property_names = match schema.get("properties") {
                    None => BTreeSet::new(),
                    Some(Value::Object(properties)) => {
                        for (name, definition) in properties {
                            let Value::Object(definition) = definition else {
                                return Err(ToolSchemaError::InvalidObjectProperties);
                            };
                            if name.is_empty() {
                                return Err(ToolSchemaError::InvalidObjectProperties);
                            }
                            Self::validate_schema(definition, false)?;
                        }
                        properties.keys().cloned().collect()
                    }
                    _ => return Err(ToolSchemaError::InvalidObjectProperties),
                };
                if let Some(required) = schema.get("required") {
                    let Some(items) = required.as_array() else {
                        return Err(ToolSchemaError::InvalidRequiredProperties);
                    };
                    let mut unique = BTreeSet::new();
                    for item in items {
                        let Some(name) = item.as_str() else {
                            return Err(ToolSchemaError::InvalidRequiredProperties);
                        };
                        if !property_names.contains(name) || !unique.insert(name) {
                            return Err(ToolSchemaError::InvalidRequiredProperties);
                        }
                    }
                }
                if schema
                    .get("additionalProperties")
                    .is_some_and(|value| !value.is_boolean())
                {
                    return Err(ToolSchemaError::InvalidAdditionalProperties);
                }
            }
            "array" => {
                if let Some(items) = schema.get("items") {
                    let Value::Object(items) = items else {
                        return Err(ToolSchemaError::InvalidArrayItems);
                    };
                    Self::validate_schema(items, false)?;
                }
            }
            "string" | "integer" | "number" | "boolean" | "null" => {}
            _ => return Err(ToolSchemaError::UnsupportedType),
        }
        Ok(())
    }

    fn validate_value(schema: &JsonObject, value: &Value) -> Result<(), ToolSchemaError> {
        let kind = schema
            .get("type")
            .and_then(Value::as_str)
            .ok_or(ToolSchemaError::UnsupportedType)?;
        match kind {
            "object" => {
                let Some(object) = value.as_object() else {
                    return Err(ToolSchemaError::ValueTypeMismatch);
                };
                let properties = schema.get("properties").and_then(Value::as_object);
                if let Some(required) = schema.get("required").and_then(Value::as_array) {
                    if required
                        .iter()
                        .filter_map(Value::as_str)
                        .any(|name| !object.contains_key(name))
                    {
                        return Err(ToolSchemaError::MissingRequiredProperty);
                    }
                }
                if schema.get("additionalProperties") == Some(&Value::Bool(false))
                    && object.keys().any(|name| {
                        !properties.is_some_and(|properties| properties.contains_key(name))
                    })
                {
                    return Err(ToolSchemaError::UnknownProperty);
                }
                if let Some(properties) = properties {
                    for (name, child_schema) in properties {
                        if let (Some(value), Value::Object(child_schema)) =
                            (object.get(name), child_schema)
                        {
                            Self::validate_value(child_schema, value)?;
                        }
                    }
                }
            }
            "array" => {
                let Some(items) = value.as_array() else {
                    return Err(ToolSchemaError::ValueTypeMismatch);
                };
                if let Some(Value::Object(item_schema)) = schema.get("items") {
                    for item in items {
                        Self::validate_value(item_schema, item)?;
                    }
                }
            }
            "string" if value.is_string() => {}
            "integer"
                if value
                    .as_number()
                    .is_some_and(|number| number.is_i64() || number.is_u64()) => {}
            "number" if value.is_number() => {}
            "boolean" if value.is_boolean() => {}
            "null" if value.is_null() => {}
            _ => return Err(ToolSchemaError::ValueTypeMismatch),
        }
        Ok(())
    }
}

pub(crate) fn empty_object_schema() -> JsonObject {
    let mut schema = Map::new();
    schema.insert("type".to_owned(), Value::String("object".to_owned()));
    schema
}
