//! The first-party Coding Agent runtime.
//!
//! This crate is the implementation behind the independent `vityo-coding-agent`
//! ACP process. The Flutter client remains a protocol client and owns IDE state.

pub mod application;
pub mod cancellation;
pub mod context;
pub mod contracts;
pub mod hosts;
pub mod multi_agent;
pub mod orchestration;
pub mod policy;
pub mod protocol;
pub mod providers;
pub mod sessions;
pub mod tools;

pub use agent_client_protocol as acp;
