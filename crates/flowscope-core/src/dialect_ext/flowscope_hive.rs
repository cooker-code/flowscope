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
//! | `supports_lambda_functions`   | Spark/Hive higher-order function lambdas |
//! | `supports_values_as_table_factor` | Spark inline VALUES relations       |
//! | `supports_group_by_expr`      | Preserve advanced grouping structure   |
//! | `parse_prefix`                | Complex CAST, typed numbers, array exists |
//! | `parse_infix` (DIV operator)  | `a DIV b` integer division               |
//! | `is_table_alias` (OFFSET)     | Hive has no OFFSET keyword, so `offset`  |
//! |                               | can legally name a table (`(...) offset`)|
//!
//! Anything not explicitly overridden is delegated to the upstream
//! `HiveDialect` so behavior stays in sync with sqlparser-rs.

use sqlparser::ast::{
    ArrayElemTypeDef, BinaryOperator, CastKind, DataType, Expr, Ident, ObjectName,
    StructBracketKind, StructField, UnaryOperator, Value,
};
use sqlparser::dialect::{Dialect, HiveDialect, Precedence};
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
    recover_implicit_aliases: bool,
}

impl FlowscopeHiveDialect {
    pub(crate) fn for_implicit_alias_recovery() -> Self {
        Self {
            recover_implicit_aliases: true,
            ..Self::default()
        }
    }

    // Called after the candidate alias token has been consumed. A separator or
    // a new clause gives us evidence that the preceding word was an alias.
    fn implicit_alias_boundary(&self, kw: &Keyword, parser: &Parser, next_clause: Keyword) -> bool {
        self.recover_implicit_aliases
            && (parser.peek_token_ref().token == Token::Comma
                || (*kw != Keyword::FROM
                    && *kw != Keyword::JOIN
                    && parser.peek_keyword(next_clause)))
    }
}

/// Share the Unicode Han script classification with alias diagnostics.
pub(crate) fn is_han(ch: char) -> bool {
    static HAN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    !ch.is_ascii()
        && HAN
            .get_or_init(|| regex::Regex::new(r"^\p{Han}$").unwrap())
            .is_match(ch.encode_utf8(&mut [0; 4]))
}

impl Dialect for FlowscopeHiveDialect {
    fn is_delimited_identifier_start(&self, ch: char) -> bool {
        self.inner.is_delimited_identifier_start(ch)
    }

    fn is_identifier_start(&self, ch: char) -> bool {
        ch == '_' || self.inner.is_identifier_start(ch) || is_han(ch)
    }

    fn is_identifier_part(&self, ch: char) -> bool {
        self.inner.is_identifier_part(ch) || is_han(ch)
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

    // Spark/Hive queries can attach an ON predicate to an explicit CROSS JOIN.
    fn supports_cross_join_constraint(&self) -> bool {
        true
    }

    fn supports_group_by_with_modifier(&self) -> bool {
        self.inner.supports_group_by_with_modifier()
    }

    // Spark SQL accepts `GROUPING SETS`, `CUBE`, and `ROLLUP` as formal
    // group-by expressions. Keep their native AST representation instead of
    // reducing grouping sets to an unrelated positional GROUP BY expression.
    fn supports_group_by_expr(&self) -> bool {
        true
    }

    // Spark SQL permits an inline relation without wrapping it in parentheses:
    // `FROM VALUES (..), (..) AS t(col1, col2)`. sqlparser already has the
    // corresponding Derived/SetExpr::Values AST path; HiveDialect merely
    // does not advertise that capability.
    fn supports_values_as_table_factor(&self) -> bool {
        true
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

    // Spark/Hive higher-order functions use `x -> expression` and
    // `(x, i) -> expression`. Without the upstream lambda capability flag,
    // sqlparser parses Arrow with binary-operator precedence, which can split
    // `u -> u.goods = k.goods AND u.level = k.level` outside its lexical
    // binding. Use the formal Expr::Lambda AST so the analyzer can distinguish
    // lambda parameters and struct members from physical columns.
    fn supports_lambda_functions(&self) -> bool {
        true
    }

    // sqlparser-rs 0.61 recognizes Hive's `ARRAY<T>` shape, but reserves
    // `STRUCT<name: T>` and `MAP<K, V>` data types for other dialects. The
    // `Dialect` trait has no data-type hook, so intercept only `CAST` and
    // build the existing sqlparser AST types here. The expression to be cast
    // is still parsed by the normal Hive parser: this deliberately preserves
    // Hive-specific `DIV`, struct literals and every non-type token.
    fn parse_prefix(&self, parser: &mut Parser) -> Option<Result<Expr, ParserError>> {
        if parser.peek_keyword(Keyword::CAST) {
            return Some(parse_hive_cast_expr(parser));
        }

        if parser.peek_keyword(Keyword::NOT)
            && matches!(
                parser.peek_nth_token(1).token,
                Token::Word(ref word) if word.keyword == Keyword::EXISTS
            )
        {
            return Some(parse_hive_not_exists_or_array_function(self, parser));
        }

        if parser.peek_keyword(Keyword::EXISTS) {
            return Some(parse_hive_exists_or_array_function(parser));
        }

        parse_hive_typed_numeric_literal(parser).map(Ok)
    }

    fn is_select_item_alias(&self, explicit: bool, kw: &Keyword, parser: &mut Parser) -> bool {
        self.inner.is_select_item_alias(explicit, kw, parser)
            || self.implicit_alias_boundary(kw, parser, Keyword::FROM)
    }

    fn is_table_factor_alias(&self, explicit: bool, kw: &Keyword, parser: &mut Parser) -> bool {
        explicit
            || self.is_table_alias(kw, parser)
            || self.implicit_alias_boundary(kw, parser, Keyword::WHERE)
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
        // Valid Hive/Spark lambdas are consumed by sqlparser's formal
        // `try_parse_lambda` path before infix parsing. Reaching an Arrow here
        // means the left side was not a valid identifier parameter list (for
        // example `(source_col, 1) -> value`). Do not reinterpret it as a
        // binary operator, because that loses lexical binding and can invent
        // `u.level`/`u.sale` physical columns from the malformed AST.
        if parser.peek_token().token == Token::Arrow {
            return Some(Err(ParserError::ParserError(
                "Hive lambda parameters must be identifiers".to_string(),
            )));
        }

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

/// Parses `EXISTS (SELECT ...)` as a subquery predicate, while accepting
/// Spark's higher-order `exists(array, element -> predicate)` as an ordinary
/// function whose second argument remains a formal lambda AST.
///
/// sqlparser-rs reserves `EXISTS` for subqueries except when the concrete
/// dialect is its `DatabricksDialect`. `FlowscopeHiveDialect` is deliberately
/// a wrapper rather than that global dialect, so use the same token-shape
/// distinction locally without broadening all Hive parsing to Databricks.
fn parse_hive_exists_or_array_function(parser: &mut Parser) -> Result<Expr, ParserError> {
    parser.expect_keyword_is(Keyword::EXISTS)?;
    // Let the upstream query parser recognize every legal subquery form,
    // including `EXISTS (VALUES ...)` and the parenthesized query variant.
    // On failure `maybe_parse` restores the opening `(` for the function
    // parser, so identifiers, literals, and nested array expressions are not
    // mistaken for subqueries.
    if let Some(expr) = parser.maybe_parse(|parser| parser.parse_exists_expr(false))? {
        return Ok(expr);
    }
    parser.parse_function(ObjectName::from(vec![Ident::new("exists")]))
}

/// `Parser::parse_not` dispatches `NOT EXISTS` directly to its subquery
/// branch. Try that native branch first so every standard subquery predicate
/// retains its `Expr::Exists { negated: true }` AST. If it cannot parse a
/// query, restore the cursor and parse Spark's array `exists` function under
/// the ordinary unary-NOT precedence.
fn parse_hive_not_exists_or_array_function(
    dialect: &FlowscopeHiveDialect,
    parser: &mut Parser,
) -> Result<Expr, ParserError> {
    if let Some(expr) = parser.maybe_parse(|parser| {
        // This is the `NOT EXISTS` arm from sqlparser's `parse_not`, written
        // inline to avoid re-entering this dialect's prefix hook.
        parser.expect_keyword_is(Keyword::NOT)?;
        parser.expect_keyword_is(Keyword::EXISTS)?;
        parser.parse_exists_expr(true)
    })? {
        return Ok(expr);
    }

    parser.expect_keyword_is(Keyword::NOT)?;
    let expr = parser.parse_subexpr(dialect.prec_value(Precedence::UnaryNot))?;
    Ok(Expr::UnaryOp {
        op: UnaryOperator::Not,
        expr: Box::new(expr),
    })
}

/// Spark accepts typed numeric suffixes such as `0.00005D` (DOUBLE), `0F`
/// (FLOAT), `0BD` (DECIMAL), and `1L` (BIGINT). sqlparser-rs's Hive tokenizer
/// has `supports_numeric_prefix=true`, so an otherwise valid suffix can be
/// tokenized as an unquoted `Word` and later be interpreted as a column. Keep
/// the general numeric-prefix behaviour for identifiers like `123abc`; only a
/// complete, unquoted Spark numeric literal is converted at the dialect prefix
/// boundary.
fn parse_hive_typed_numeric_literal(parser: &mut Parser) -> Option<Expr> {
    let token = parser.peek_token();
    let Token::Word(word) = &token.token else {
        return None;
    };
    if word.quote_style.is_some() {
        return None;
    }

    let (number, long) = split_hive_typed_numeric_literal(&word.value)?;
    let token = parser.next_token();
    Some(Expr::Value(
        Value::Number(number.to_owned(), long).with_span(token.span),
    ))
}

/// Splits the exact Spark numeric grammar accepted by this dialect. This is
/// deliberately a byte-level recognizer rather than a SQL-wide rewrite: quoted
/// identifiers and malformed words never enter here, while the normal parser
/// remains responsible for rejecting them.
fn split_hive_typed_numeric_literal(value: &str) -> Option<(&str, bool)> {
    let (number, suffix) = if value
        .get(value.len().checked_sub(2)?..)
        .is_some_and(|suffix| suffix.eq_ignore_ascii_case("bd"))
    {
        (value.get(..value.len() - 2)?, "BD")
    } else {
        (
            value.get(..value.len().checked_sub(1)?)?,
            value.get(value.len().checked_sub(1)?..)?,
        )
    };

    let long = match suffix.to_ascii_uppercase().as_str() {
        "D" | "F" | "BD" => false,
        "L" => true,
        _ => return None,
    };
    let valid = if long {
        // sqlparser's `Token::Number(_, true)` is its integer-long token form.
        // Spark's `L` suffix likewise applies only to an integer literal;
        // decimal/exponent variants must remain ordinary parser input rather
        // than being silently reclassified as BIGINT.
        !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit())
    } else {
        is_decimal_or_exponent(number)
    };
    valid.then_some((number, long))
}

fn is_decimal_or_exponent(value: &str) -> bool {
    let bytes = value.as_bytes();
    let mut index = 0;
    let mut whole_digits = 0;
    while index < bytes.len() && bytes[index].is_ascii_digit() {
        index += 1;
        whole_digits += 1;
    }
    let mut fraction_digits = 0;
    if bytes.get(index) == Some(&b'.') {
        index += 1;
        while index < bytes.len() && bytes[index].is_ascii_digit() {
            index += 1;
            fraction_digits += 1;
        }
    }
    if whole_digits == 0 && fraction_digits == 0 {
        return false;
    }
    if matches!(bytes.get(index), Some(b'e' | b'E')) {
        index += 1;
        if matches!(bytes.get(index), Some(b'+' | b'-')) {
            index += 1;
        }
        let exponent_start = index;
        while index < bytes.len() && bytes[index].is_ascii_digit() {
            index += 1;
        }
        if exponent_start == index {
            return false;
        }
    }
    index == bytes.len()
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
    use sqlparser::tokenizer::Tokenizer;

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
    fn hive_lambda_keeps_and_or_predicates_inside_the_lambda_body() {
        let statements = Parser::parse_sql(
            &FlowscopeHiveDialect::default(),
            "SELECT filter(push_units, u -> u.goods = k.goods AND u.level = k.level OR u.sale = k.sale) FROM t",
        )
        .expect("Hive lambda should parse");
        let sqlparser::ast::Statement::Query(query) = &statements[0] else {
            panic!("expected query");
        };
        let sqlparser::ast::SetExpr::Select(select) = query.body.as_ref() else {
            panic!("expected SELECT");
        };
        let sqlparser::ast::SelectItem::UnnamedExpr(Expr::Function(function)) =
            &select.projection[0]
        else {
            panic!("expected filter function");
        };
        let sqlparser::ast::FunctionArguments::List(arguments) = &function.args else {
            panic!("expected function arguments");
        };
        let sqlparser::ast::FunctionArg::Unnamed(sqlparser::ast::FunctionArgExpr::Expr(
            Expr::Lambda(lambda),
        )) = &arguments.args[1]
        else {
            panic!("expected formal lambda argument");
        };

        assert_eq!(lambda.params.to_string(), "u");
        assert_eq!(
            lambda.body.to_string(),
            "u.goods = k.goods AND u.level = k.level OR u.sale = k.sale"
        );
        assert!(matches!(
            lambda.body.as_ref(),
            Expr::BinaryOp {
                op: BinaryOperator::Or,
                ..
            }
        ));
    }

    #[test]
    fn hive_array_exists_keeps_the_lambda_as_a_function_argument() {
        let statements = Parser::parse_sql(
            &FlowscopeHiveDialect::default(),
            "SELECT exists(push_groups, g -> g.weeks < 0) FROM t",
        )
        .expect("Spark array exists should parse");
        let sqlparser::ast::Statement::Query(query) = &statements[0] else {
            panic!("expected query");
        };
        let sqlparser::ast::SetExpr::Select(select) = query.body.as_ref() else {
            panic!("expected SELECT");
        };
        let sqlparser::ast::SelectItem::UnnamedExpr(Expr::Function(function)) =
            &select.projection[0]
        else {
            panic!("expected exists function");
        };
        assert_eq!(function.name.to_string(), "exists");
        let sqlparser::ast::FunctionArguments::List(arguments) = &function.args else {
            panic!("expected function arguments");
        };
        assert!(matches!(
            arguments.args[1],
            sqlparser::ast::FunctionArg::Unnamed(sqlparser::ast::FunctionArgExpr::Expr(
                Expr::Lambda(_)
            ))
        ));
    }

    #[test]
    fn hive_subquery_exists_and_array_function_forms_remain_distinct() {
        assert!(parse_ok(
            "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.id = t.id)"
        ));
        assert!(parse_ok(
            "SELECT * FROM t WHERE EXISTS /* deliberate parenthesized query */ (WITH u AS (SELECT 1) SELECT * FROM u)"
        ));
        assert!(parse_ok("SELECT * FROM t WHERE EXISTS (VALUES (1))"));
        assert!(parse_ok("SELECT * FROM t WHERE EXISTS ((SELECT 1))"));
        // Non-subquery arguments deliberately remain on the function path.
        // SQL type/arity validation belongs to the execution engine, while
        // FlowScope must retain fields nested in real array expressions.
        assert!(parse_ok(
            "SELECT exists(identifier, x -> x.id IS NOT NULL) FROM t"
        ));
        assert!(parse_ok(
            "SELECT exists(coalesce(items, ARRAY[1]), x -> x > 0) FROM t"
        ));
        assert!(parse_ok(
            "SELECT exists('string literal', x -> x IS NOT NULL) FROM t"
        ));
    }

    #[test]
    fn hive_not_array_exists_preserves_function_name_and_boolean_precedence() {
        let statements = Parser::parse_sql(
            &FlowscopeHiveDialect::default(),
            "SELECT * FROM t WHERE NOT exists(items, x -> x.id = t.id) AND active = 1 OR archived = 0",
        )
        .expect("negated Spark array exists should parse");
        assert_eq!(statements[0].to_string(), "SELECT * FROM t WHERE NOT exists(items, x -> x.id = t.id) AND active = 1 OR archived = 0");
        assert!(parse_ok(
            "SELECT * FROM t WHERE NOT EXISTS (VALUES (1)) AND active = 1"
        ));
        assert!(parse_ok(
            "SELECT * FROM t WHERE NOT EXISTS ((SELECT 1)) OR archived = 0"
        ));
    }

    #[test]
    fn values_and_grouping_expression_use_native_ast_support() {
        assert!(parse_ok(
            "SELECT v.id FROM VALUES (1, CAST(NULL AS STRING)), (2, 'x') AS v(id, label)"
        ));
        assert!(parse_ok(
            "SELECT a, b, c FROM t GROUP BY GROUPING SETS ((a), ()), GROUPING SETS ((b), (c))"
        ));
        assert!(parse_ok("SELECT a FROM t GROUP BY CUBE (a, b), ROLLUP (c)"));
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

    #[test]
    fn spark_typed_numeric_word_becomes_a_numeric_ast_literal() {
        // Hive's numeric-prefix support tokenizes the complete suffix form as
        // a Word. The dialect hook must consume exactly that legal token and
        // produce a Value::Number before column analysis sees it.
        let dialect = FlowscopeHiveDialect::default();
        let mut tokenizer = Tokenizer::new(&dialect, "SELECT 0.00005D");
        let tokens = tokenizer.tokenize().expect("typed numeric tokenizes");
        assert!(matches!(&tokens[2], Token::Word(word) if word.value == "0.00005D"));

        let statements = Parser::parse_sql(&FlowscopeHiveDialect::default(), "SELECT 0.00005D")
            .expect("typed numeric parses");
        let sqlparser::ast::Statement::Query(query) = &statements[0] else {
            panic!("expected query");
        };
        let sqlparser::ast::SetExpr::Select(select) = query.body.as_ref() else {
            panic!("expected select");
        };
        assert!(matches!(
            &select.projection[0],
            sqlparser::ast::SelectItem::UnnamedExpr(Expr::Value(value))
                if matches!(&value.value, Value::Number(number, false) if number == "0.00005")
        ));
    }

    #[test]
    fn quoted_numeric_looking_identifier_stays_an_identifier() {
        assert!(parse_ok("SELECT `0.00005D` FROM t"));
    }

    #[test]
    fn spark_typed_numeric_suffixes_are_strict() {
        assert_eq!(split_hive_typed_numeric_literal("1D"), Some(("1", false)));
        assert_eq!(split_hive_typed_numeric_literal(".5f"), Some((".5", false)));
        assert_eq!(
            split_hive_typed_numeric_literal("1e-3BD"),
            Some(("1e-3", false))
        );
        assert_eq!(split_hive_typed_numeric_literal("1L"), Some(("1", true)));
        assert_eq!(split_hive_typed_numeric_literal("1.2L"), None);
        assert_eq!(split_hive_typed_numeric_literal("1e3L"), None);
        assert_eq!(split_hive_typed_numeric_literal("1st"), None);
        assert_eq!(split_hive_typed_numeric_literal("1eD"), None);
        assert_eq!(split_hive_typed_numeric_literal("1.2DB"), None);
    }
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
        // numeric and non-Han boundaries remain delegated upstream.
        let dialect = FlowscopeHiveDialect::default();
        let upstream = HiveDialect {};
        assert!(dialect.is_identifier_start('_'));
        assert_eq!(
            dialect.is_identifier_start('1'),
            upstream.is_identifier_start('1')
        );
        assert_eq!(
            dialect.is_identifier_start('é'),
            upstream.is_identifier_start('é')
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
