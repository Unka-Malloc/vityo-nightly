//! Shared tool catalogue, authorization, and execution boundary.

mod catalog;
mod executor;
mod mcp;

pub use crate::policy::ToolPermissionRequirement;
pub use catalog::{
    ToolCatalog, ToolDescriptor, ToolRisk, ToolSchema, ToolSchemaError, ToolSourceKind,
};
pub use executor::{
    EffectState, ExecutionHook, SecretResolver, ToolAdapter, ToolAdapterError, ToolCall,
    ToolExecutionContext, ToolExecutionLimits, ToolExecutionReceipt, ToolExecutor, ToolFailure,
    ToolFailureCode, ToolPathResolver, ToolPreflight,
};
pub use mcp::{
    McpClient, McpFailure, McpFailureCode, McpToolMetadata, McpToolPolicy, McpToolSnapshot,
    McpToolSource, RmcpMcpClient,
};
