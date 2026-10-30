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
//! | leading `_` identifiers        | Spark/Hive aliases and CTEs may start `_`|
//! | `supports_struct_literal`     | `STRUCT(col AS name)` field naming       |
//! | `parse_prefix` (complex CAST) | Spark `ARRAY/STRUCT/MAP` type grammar    |
//! | `parse_infix` (DIV operator)  | `a DIV b` integer division               |
//! | `is_table_alias` (OFFSET)     | Hive has no OFFSET keyword, so `offset`  |
//! |                               | can legally name a table (`(...) offset`)|
//!
//! Anything not explicitly overridden is delegated to the upstream
//! `HiveDialect` so behavior stays in sync with sqlparser-rs.

use sqlparser::ast::{
    ArrayElemTypeDef, BinaryOperator, CastKind, DataType, Expr, StructBracketKind, StructField,
};
use sqlparser::dialect::{Dialect, HiveDialect};
use sqlparser::keywords::Keyword;
use sqlparser::parser::{Parser, ParserError};
use sqlparser::tokenizer::Token;

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
        // Spark/Hive regular identifiers allow `_` as their first character.
        // sqlparser-rs 0.61's HiveDialect delegates this character to a
        // punctuation token, which makes aliases such as `__semantic_tuomin`
        // fail before the analyzer receives the original SQL. Keep every
        // other start-character decision delegated to the upstream dialect:
        // this deliberately does not make digits, quotes, or keywords legal.
        ch == '_' || self.inner.is_identifier_start(ch)
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

    // sqlparser-rs 0.61 recognizes Hive's `ARRAY<T>` shape, but reserves
    // `STRUCT<name: T>` and `MAP<K, V>` data types for other dialects. The
    // `Dialect` trait has no data-type hook, so intercept only `CAST` and
    // build the existing sqlparser AST types here. The expression to be cast
    // is still parsed by the normal Hive parser: this deliberately preserves
    // Hive-specific `DIV`, struct literals and every non-type token.
    fn parse_prefix(&self, parser: &mut Parser) -> Option<Result<Expr, ParserError>> {
        if !parser.peek_keyword(Keyword::CAST) {
            return None;
        }

        Some(parse_hive_cast_expr(parser))
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

fn parse_hive_cast_expr(parser: &mut Parser) -> Result<Expr, ParserError> {
    parser.expect_keyword_is(Keyword::CAST)?;
    parser.expect_token(&Token::LParen)?;
    let expr = parser.parse_expr()?;
    parser.expect_keyword_is(Keyword::AS)?;
    let (data_type, trailing_bracket) = parse_hive_data_type(parser, 0)?;
    if trailing_bracket {
        return Err(ParserError::ParserError(
            "unmatched > after parsing Hive data type".to_string(),
        ));
    }
    let array = parser.parse_keyword(Keyword::ARRAY);
    let format = parser.parse_optional_cast_format()?;
    parser.expect_token(&Token::RParen)?;

    Ok(Expr::Cast {
        kind: CastKind::Cast,
        expr: Box::new(expr),
        data_type,
        array,
        format,
    })
}

/// Parses the Spark/Hive complex data-type subset using sqlparser's existing
/// `DataType` variants. `bool` records the second `>` in a tokenized `>>`,
/// matching sqlparser's nested-angle-bracket handling without changing the
/// tokenizer or accepting an unbalanced type.
const MAX_HIVE_COMPLEX_TYPE_DEPTH: usize = 128;

fn parse_hive_data_type(
    parser: &mut Parser,
    depth: usize,
) -> Result<(DataType, bool), ParserError> {
    if depth > MAX_HIVE_COMPLEX_TYPE_DEPTH {
        return Err(ParserError::ParserError(format!(
            "Hive complex data type exceeds maximum nesting depth of {MAX_HIVE_COMPLEX_TYPE_DEPTH}"
        )));
    }

    if parser.peek_keyword(Keyword::ARRAY) {
        parser.expect_keyword_is(Keyword::ARRAY)?;
        parser.expect_token(&Token::Lt)?;
        let (element_type, trailing_bracket) = parse_hive_data_type(parser, depth + 1)?;
        let trailing_bracket = expect_hive_closing_angle_bracket(parser, trailing_bracket)?;
        return Ok((
            DataType::Array(ArrayElemTypeDef::AngleBracket(Box::new(element_type))),
            trailing_bracket,
        ));
    }

    if parser.peek_keyword(Keyword::STRUCT) {
        parser.expect_keyword_is(Keyword::STRUCT)?;
        parser.expect_token(&Token::Lt)?;
        let mut fields = Vec::new();
        let trailing_bracket = loop {
            // Spark accepts both `name: TYPE` and `name TYPE`. Treat a word
            // followed by another word or a colon as a field name; otherwise
            // retain sqlparser's anonymous-field representation.
            let has_field_name = matches!(
                parser.peek_nth_token(1).token,
                Token::Colon | Token::Word(_)
            );
            let field_name = has_field_name
                .then(|| parser.parse_identifier())
                .transpose()?;
            let _ = parser.consume_token(&Token::Colon);
            let (field_type, field_trailing_bracket) = parse_hive_data_type(parser, depth + 1)?;
            fields.push(StructField {
                field_name,
                field_type,
                options: None,
            });

            if field_trailing_bracket || !parser.consume_token(&Token::Comma) {
                break field_trailing_bracket;
            }
        };
        let trailing_bracket = expect_hive_closing_angle_bracket(parser, trailing_bracket)?;
        return Ok((
            DataType::Struct(fields, StructBracketKind::AngleBrackets),
            trailing_bracket,
        ));
    }

    if parser.peek_keyword(Keyword::MAP) {
        parser.expect_keyword_is(Keyword::MAP)?;
        parser.expect_token(&Token::Lt)?;
        let (key_type, key_trailing_bracket) = parse_hive_data_type(parser, depth + 1)?;
        if key_trailing_bracket {
            return Err(ParserError::ParserError(
                "Hive MAP key type cannot close the enclosing type".to_string(),
            ));
        }
        parser.expect_token(&Token::Comma)?;
        let (value_type, value_trailing_bracket) = parse_hive_data_type(parser, depth + 1)?;
        let trailing_bracket = expect_hive_closing_angle_bracket(parser, value_trailing_bracket)?;
        return Ok((
            DataType::Map(Box::new(key_type), Box::new(value_type)),
            trailing_bracket,
        ));
    }

    Ok((parser.parse_data_type()?, false))
}

fn expect_hive_closing_angle_bracket(
    parser: &mut Parser,
    trailing_bracket: bool,
) -> Result<bool, ParserError> {
    if trailing_bracket {
        return Ok(false);
    }

    match parser.peek_token().token {
        Token::Gt => {
            parser.next_token();
            Ok(false)
        }
        Token::ShiftRight => {
            parser.next_token();
            Ok(true)
        }
        _ => parser.expected(">", parser.peek_token()),
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

    #[test]
    fn hive_cast_parses_nested_array_struct_and_map_types() {
        let sql = "SELECT CAST(payload AS ARRAY<STRUCT<order_id:STRING, attrs:MAP<STRING,ARRAY<INT>>>>) FROM t";
        assert!(parse_ok(sql));
    }

    #[test]
    fn hive_cast_accepts_whitespace_comments_and_mixed_case_types() {
        let sql = "SELECT CAST(payload AS array< /* element */ struct<`order_id`:STRING, tags: map<STRING, array<INT>> >>) FROM t";
        assert!(parse_ok(sql));
    }

    #[test]
    fn hive_cast_rejects_malformed_complex_types() {
        assert!(!parse_ok("SELECT CAST(x AS ARRAY<STRUCT<a:STRING>) FROM t"));
        assert!(!parse_ok("SELECT CAST(x AS MAP<STRING>) FROM t"));
        assert!(!parse_ok("SELECT CAST(x AS STRUCT<a:>) FROM t"));
    }

    #[test]
    fn hive_cast_accepts_struct_fields_without_colons() {
        assert!(parse_ok(
            "SELECT CAST(x AS STRUCT<a STRING, b ARRAY<INT>>) FROM t"
        ));
    }

    #[test]
    fn hive_scalar_cast_still_uses_the_normal_data_type_parser() {
        assert!(parse_ok("SELECT CAST(x AS DECIMAL(38, 4)) FROM t"));
        assert!(parse_ok("SELECT CAST(x AS STRING ARRAY) FROM t"));
    }

    #[test]
    fn hive_cast_rejects_complex_types_beyond_the_depth_limit() {
        let mut data_type = "INT".to_string();
        for _ in 0..=MAX_HIVE_COMPLEX_TYPE_DEPTH {
            data_type = format!("ARRAY<{data_type}>");
        }
        assert!(!parse_ok(&format!("SELECT CAST(x AS {data_type}) FROM t")));
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

    // ── Leading underscore identifier tests ────────────────────────────────

    #[test]
    fn leading_underscore_identifiers_parse_in_hive_positions() {
        assert!(parse_ok(
            "WITH _cte AS (SELECT _src._value AS _value FROM source_table AS _src) \
             SELECT _cte._value AS _result FROM _cte"
        ));
    }

    #[test]
    fn upstream_hive_still_rejects_leading_underscore_identifier() {
        assert!(Parser::parse_sql(
            &HiveDialect {},
            "SELECT _src._value FROM source_table AS _src"
        )
        .is_err());
    }

    #[test]
    fn leading_underscore_override_keeps_invalid_identifier_boundaries() {
        // The override is intentionally only for a leading underscore. All
        // existing numeric and Unicode behavior remains delegated upstream.
        let dialect = FlowscopeHiveDialect::default();
        let upstream = HiveDialect {};
        assert!(dialect.is_identifier_start('_'));
        assert_eq!(
            dialect.is_identifier_start('1'),
            upstream.is_identifier_start('1')
        );
        assert_eq!(
            dialect.is_identifier_start('中'),
            upstream.is_identifier_start('中')
        );
        assert_eq!(
            dialect.is_identifier_part('_'),
            upstream.is_identifier_part('_')
        );
        assert_eq!(
            Parser::parse_sql(&dialect, "SELECT * FROM source_table AS select").is_ok(),
            Parser::parse_sql(&upstream, "SELECT * FROM source_table AS select").is_ok(),
            "the underscore override must not change keyword handling"
        );
    }
}
