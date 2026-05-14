//! Custom Hive dialect that fixes gaps in `sqlparser::dialect::HiveDialect`.
//!
//! sqlparser-rs 0.61's `HiveDialect` is missing several syntax features that
//! real-world Hive / Spark SQL relies on. This module composes the upstream
//! `HiveDialect` and overrides individual trait methods to close those gaps.
//!
//! Currently overridden:
//!
//! | Feature                       | Reason                                   |
//! |-------------------------------|------------------------------------------|
//! | `supports_struct_literal`     | `STRUCT(col AS name)` field naming       |
//!
//! Anything not explicitly overridden is delegated to the upstream
//! `HiveDialect` so behavior stays in sync with sqlparser-rs.

use sqlparser::dialect::{Dialect, HiveDialect};

/// FlowScope's enhanced Hive dialect.
///
/// Wraps `sqlparser::dialect::HiveDialect` and selectively overrides trait
/// methods to enable Hive features that the upstream dialect is missing.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FlowscopeHiveDialect {
    inner: HiveDialect,
}

impl Dialect for FlowscopeHiveDialect {
    fn is_delimited_identifier_start(&self, ch: char) -> bool {
        self.inner.is_delimited_identifier_start(ch)
    }

    fn is_identifier_start(&self, ch: char) -> bool {
        self.inner.is_identifier_start(ch)
    }

    fn is_identifier_part(&self, ch: char) -> bool {
        self.inner.is_identifier_part(ch)
    }

    fn supports_filter_during_aggregation(&self) -> bool {
        self.inner.supports_filter_during_aggregation()
    }

    fn supports_numeric_prefix(&self) -> bool {
        self.inner.supports_numeric_prefix()
    }

    fn require_interval_qualifier(&self) -> bool {
        self.inner.require_interval_qualifier()
    }

    fn supports_bang_not_operator(&self) -> bool {
        self.inner.supports_bang_not_operator()
    }

    fn supports_load_data(&self) -> bool {
        self.inner.supports_load_data()
    }

    fn supports_table_sample_before_alias(&self) -> bool {
        self.inner.supports_table_sample_before_alias()
    }

    fn supports_group_by_with_modifier(&self) -> bool {
        self.inner.supports_group_by_with_modifier()
    }

    // ── PR1 override ────────────────────────────────────────────────────────
    //
    // Hive's `struct(field1 AS name1, field2 AS name2, ...)` literal is widely
    // used in `collect_list(struct(...))`-style patterns. sqlparser-rs's
    // HiveDialect inherits the default `false`, which causes `STRUCT(a AS b)`
    // to fail with "Expected: ), found: AS". BigQuery / Databricks / Generic
    // all override this to `true`; we do the same for Hive.
    fn supports_struct_literal(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlparser::parser::Parser;

    fn parse_ok(sql: &str) -> bool {
        Parser::parse_sql(&FlowscopeHiveDialect::default(), sql).is_ok()
    }

    #[test]
    fn struct_with_named_fields_parses() {
        // The exact pattern that triggered auditId=2479 / 2482 / 2571.
        assert!(parse_ok("SELECT STRUCT(a AS w, b AS l) FROM t"));
    }

    #[test]
    fn collect_list_with_struct_parses() {
        // collect_list(struct(...)) is the real-world usage from
        // dwd_conan_course_lifecycle_detail_da.sql (id=2571).
        assert!(parse_ok(
            "SELECT collect_list(struct(ldap, cast(d AS INT) AS duration, c)) FROM t"
        ));
    }

    #[test]
    fn upstream_hive_still_fails_struct_named() {
        // Sanity guard: the upstream dialect must still fail; if this assertion
        // breaks, the override has become redundant and can be removed.
        assert!(Parser::parse_sql(&HiveDialect {}, "SELECT STRUCT(a AS w) FROM t").is_err());
    }

    #[test]
    fn nested_struct_with_function_parses() {
        // From id=2479 / 2482:
        // TRANSFORM(ARRAY_SORT(COLLECT_LIST(STRUCT(week AS w, label AS l))), x -> x.l)
        assert!(parse_ok(
            "SELECT TRANSFORM(\
                ARRAY_SORT(COLLECT_LIST(STRUCT(week AS w, label AS l))),\
                x -> x.l\
             ) FROM t"
        ));
    }
}
