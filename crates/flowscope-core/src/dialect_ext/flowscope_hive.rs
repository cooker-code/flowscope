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
//! | `parse_infix` (DIV operator)  | `a DIV b` integer division               |
//! | `is_table_alias` (OFFSET)     | Hive has no OFFSET keyword, so `offset`  |
//! |                               | can legally name a table (`(...) offset`)|
//!
//! Anything not explicitly overridden is delegated to the upstream
//! `HiveDialect` so behavior stays in sync with sqlparser-rs.

use sqlparser::ast::{BinaryOperator, Expr};
use sqlparser::dialect::{Dialect, HiveDialect};
use sqlparser::keywords::Keyword;
use sqlparser::parser::{Parser, ParserError};

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

    // ── PR3 override ────────────────────────────────────────────────────────
    //
    // Hive's SELECT grammar does NOT have an OFFSET clause (see
    // <https://cwiki.apache.org/confluence/display/Hive/LanguageManual+Select>),
    // so writing `CROSS JOIN (...) offset` to name a derived table `offset` is
    // perfectly legal Hive syntax. sqlparser-rs, however, keeps OFFSET in its
    // global `RESERVED_FOR_TABLE_ALIAS` list and HiveDialect inherits that
    // default, which makes the construct fail with "Expected: ), found: <next
    // token>". We loosen the rule here.
    //
    // Anything that's truly required to disambiguate Hive grammar (SELECT,
    // FROM, WHERE, etc.) is still rejected because we only remove OFFSET from
    // the reserved set.
    fn is_table_alias(&self, kw: &Keyword, parser: &mut Parser) -> bool {
        if matches!(kw, Keyword::OFFSET) {
            return true;
        }
        self.inner.is_table_alias(kw, parser)
    }

    // ── PR2 override ────────────────────────────────────────────────────────
    //
    // Hive's `DIV` operator (BIGINT integer division) is documented at
    // <https://cwiki.apache.org/confluence/display/hive/languagemanual+udf>
    // but sqlparser-rs only registers `DIV` parsing inside MySqlDialect. We
    // mirror that implementation here so `a DIV b` parses as a BinaryOp
    // identical to MySQL's `MyIntegerDivide`.
    fn parse_infix(
        &self,
        parser: &mut Parser,
        expr: &Expr,
        _precedence: u8,
    ) -> Option<Result<Expr, ParserError>> {
        if parser.parse_keyword(Keyword::DIV) {
            let rhs = match parser.parse_expr() {
                Ok(e) => e,
                Err(e) => return Some(Err(e)),
            };
            return Some(Ok(Expr::BinaryOp {
                left: Box::new(expr.clone()),
                op: BinaryOperator::MyIntegerDivide,
                right: Box::new(rhs),
            }));
        }
        None
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

    // ── PR2 (DIV operator) tests ─────────────────────────────────────────────

    #[test]
    fn integer_division_with_div_operator_parses() {
        // From id=2568:
        // CAST(shumei_timestamp AS BIGINT) DIV 1000
        assert!(parse_ok("SELECT x DIV 1000 FROM t"));
        assert!(parse_ok("SELECT CAST(x AS BIGINT) DIV 1000 AS r FROM t"));
    }

    #[test]
    fn upstream_hive_still_fails_div() {
        assert!(Parser::parse_sql(&HiveDialect {}, "SELECT x DIV 1000 FROM t").is_err());
    }

    // ── PR3 (OFFSET as table alias) tests ────────────────────────────────────

    #[test]
    fn offset_keyword_as_table_alias_parses() {
        // From id=2482:
        // CROSS JOIN (SELECT 0 AS offset_val UNION ALL SELECT 1) offset
        assert!(parse_ok(
            "SELECT * FROM t \
             CROSS JOIN (SELECT 0 AS v UNION ALL SELECT 1) offset \
             WHERE t.x = offset.v"
        ));
    }

    #[test]
    fn upstream_hive_still_fails_offset_alias() {
        assert!(Parser::parse_sql(
            &HiveDialect {},
            "SELECT * FROM t CROSS JOIN (SELECT 0 AS v) offset WHERE t.x = offset.v"
        )
        .is_err());
    }

    #[test]
    fn select_keyword_still_rejected_as_table_alias() {
        // Sanity guard: the override only loosens OFFSET, not everything.
        assert!(Parser::parse_sql(
            &FlowscopeHiveDialect::default(),
            "SELECT * FROM t CROSS JOIN (SELECT 1) select"
        )
        .is_err());
    }
}
