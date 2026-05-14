//! FlowScope-specific extensions to sqlparser-rs dialects.
//!
//! sqlparser-rs ships official dialect implementations that we generally rely
//! on as-is. When we discover real-world SQL that fails to parse due to a
//! missing trait override, we add a thin wrapper here that delegates to the
//! upstream dialect but enables the additional behavior.
//!
//! Each wrapper must:
//!   - Keep upstream behavior by delegating non-overridden methods.
//!   - Document each override with a comment + spec reference.
//!   - Provide a unit test demonstrating both the failure on upstream and the
//!     success on the wrapper.

pub mod flowscope_hive;

pub use flowscope_hive::FlowscopeHiveDialect;
