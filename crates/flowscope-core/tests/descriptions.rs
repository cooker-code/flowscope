//! Integration tests for table/column descriptions harvested from structured
//! SQL comments (`COMMENT ON`, inline `CREATE TABLE` `COMMENT '...'`).

use flowscope_core::{analyze, AnalyzeRequest, AnalyzeResult, Dialect, Node, NodeType};

fn analyze_sql(sql: &str, dialect: Dialect) -> AnalyzeResult {
    analyze(&AnalyzeRequest {
        sql: sql.trim().to_string(),
        files: None,
        dialect,
        source_name: Some("descriptions_test".into()),
        options: None,
        schema: None,
        #[cfg(feature = "templating")]
        template_config: None,
    })
}

fn find_table(result: &AnalyzeResult, label: &str) -> Node {
    result
        .nodes
        .iter()
        .find(|n| {
            matches!(n.node_type, NodeType::Table | NodeType::View)
                && n.label.as_ref().eq_ignore_ascii_case(label)
        })
        .cloned()
        .unwrap_or_else(|| panic!("no table/view node with label `{label}`"))
}

fn find_column(result: &AnalyzeResult, table: &str, column: &str) -> Node {
    let table_node = find_table(result, table);
    let column_ids: Vec<_> = result
        .edges
        .iter()
        .filter(|e| e.edge_type == flowscope_core::EdgeType::Ownership && e.from == table_node.id)
        .map(|e| e.to.clone())
        .collect();

    result
        .nodes
        .iter()
        .find(|n| {
            n.node_type == NodeType::Column
                && column_ids.contains(&n.id)
                && n.label.as_ref().eq_ignore_ascii_case(column)
        })
        .cloned()
        .unwrap_or_else(|| panic!("no column `{column}` on table `{table}`"))
}

// =============================================================================
// Tier 1: COMMENT ON statements
// =============================================================================

#[test]
fn comment_on_table_attaches_description() {
    let sql = "
        CREATE TABLE customers (id INTEGER, email VARCHAR);
        COMMENT ON TABLE customers IS 'Current state of every customer.';
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let node = find_table(&result, "customers");
    assert_eq!(
        node.description.as_deref(),
        Some("Current state of every customer.")
    );
}

#[test]
fn comment_on_column_attaches_to_column_node() {
    let sql = "
        CREATE TABLE customers (id INTEGER, currency_code VARCHAR(3));
        COMMENT ON COLUMN customers.currency_code IS 'ISO-4217; NULL means USD.';
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let column = find_column(&result, "customers", "currency_code");
    assert_eq!(
        column.description.as_deref(),
        Some("ISO-4217; NULL means USD.")
    );

    // Table node should NOT inherit the column description.
    let table = find_table(&result, "customers");
    assert!(
        table.description.is_none(),
        "table description should be independent of column description"
    );
}

#[test]
fn comment_on_qualified_column_resolves_against_schema() {
    let sql = "
        CREATE TABLE public.customers (id INTEGER, email VARCHAR);
        COMMENT ON COLUMN public.customers.email IS 'Primary contact email.';
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let column = find_column(&result, "customers", "email");
    assert_eq!(
        column.description.as_deref(),
        Some("Primary contact email.")
    );
}

#[test]
fn comment_on_before_create_table_still_applies() {
    // COMMENT ON precedes the CREATE TABLE in source order.
    // The pre-pass harvests both and applies descriptions after lineage.
    let sql = "
        COMMENT ON TABLE customers IS 'Defined later in the script.';
        CREATE TABLE customers (id INTEGER);
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let node = find_table(&result, "customers");
    assert_eq!(
        node.description.as_deref(),
        Some("Defined later in the script.")
    );
}

#[test]
fn empty_comment_is_ignored() {
    let sql = "
        CREATE TABLE customers (id INTEGER);
        COMMENT ON TABLE customers IS '   ';
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let node = find_table(&result, "customers");
    assert!(
        node.description.is_none(),
        "whitespace-only comment should not become a description"
    );
}

#[test]
fn later_comment_on_table_overrides_earlier_description() {
    let sql = "
        CREATE TABLE customers (id INTEGER) COMMENT='Initial description';
        COMMENT ON TABLE customers IS 'Replacement description.';
    ";
    let result = analyze_sql(sql, Dialect::Generic);
    let node = find_table(&result, "customers");
    assert_eq!(
        node.description.as_deref(),
        Some("Replacement description.")
    );
}

#[test]
fn later_comment_on_column_overrides_earlier_description() {
    let sql = "
        CREATE TABLE customers (
            id INTEGER,
            currency_code VARCHAR(3) COMMENT 'Initial description'
        );
        COMMENT ON COLUMN customers.currency_code IS 'Replacement description.';
    ";
    let result = analyze_sql(sql, Dialect::Generic);
    let column = find_column(&result, "customers", "currency_code");
    assert_eq!(
        column.description.as_deref(),
        Some("Replacement description.")
    );
}

#[test]
fn null_comment_clears_table_description() {
    let sql = "
        CREATE TABLE customers (id INTEGER);
        COMMENT ON TABLE customers IS 'Temporary description.';
        COMMENT ON TABLE customers IS NULL;
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let node = find_table(&result, "customers");
    assert!(
        node.description.is_none(),
        "COMMENT ... IS NULL should clear an earlier table description"
    );
}

#[test]
fn null_comment_clears_column_description() {
    let sql = "
        CREATE TABLE customers (id INTEGER, currency_code VARCHAR(3));
        COMMENT ON COLUMN customers.currency_code IS 'Temporary description.';
        COMMENT ON COLUMN customers.currency_code IS NULL;
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let column = find_column(&result, "customers", "currency_code");
    assert!(
        column.description.is_none(),
        "COMMENT ... IS NULL should clear an earlier column description"
    );
}

// =============================================================================
// Tier 2: inline CREATE TABLE comments
// =============================================================================

#[test]
fn inline_create_table_column_comment() {
    let sql = "
        CREATE TABLE t (
            id INTEGER,
            currency_code VARCHAR(3) COMMENT 'ISO-4217 currency code.'
        );
    ";
    let result = analyze_sql(sql, Dialect::Mysql);
    let column = find_column(&result, "t", "currency_code");
    assert_eq!(
        column.description.as_deref(),
        Some("ISO-4217 currency code.")
    );
}

#[test]
fn inline_create_table_level_comment_with_eq() {
    // MySQL-style: `COMMENT='...'` appears in table_options as WithEq.
    let sql = "CREATE TABLE t (id INTEGER) COMMENT='Customer state';";
    let result = analyze_sql(sql, Dialect::Mysql);
    let node = find_table(&result, "t");
    assert_eq!(node.description.as_deref(), Some("Customer state"));
}

#[test]
fn inline_create_table_level_comment_without_eq() {
    // Postgres/DuckDB-style: `COMMENT '...'` without equals — WithoutEq.
    let sql = "CREATE TABLE t (id INTEGER) COMMENT 'Customer state';";
    let result = analyze_sql(sql, Dialect::Mysql);
    let node = find_table(&result, "t");
    assert_eq!(node.description.as_deref(), Some("Customer state"));
}

#[test]
fn inline_create_table_mixes_column_and_table_comments() {
    let sql = "
        CREATE TABLE t (
            id INTEGER COMMENT 'Primary key.',
            name VARCHAR(20) COMMENT 'Display name.'
        ) COMMENT='Reference data.';
    ";
    let result = analyze_sql(sql, Dialect::Mysql);

    let table = find_table(&result, "t");
    assert_eq!(table.description.as_deref(), Some("Reference data."));

    let id_col = find_column(&result, "t", "id");
    assert_eq!(id_col.description.as_deref(), Some("Primary key."));

    let name_col = find_column(&result, "t", "name");
    assert_eq!(name_col.description.as_deref(), Some("Display name."));
}

// =============================================================================
// Negative cases
// =============================================================================

#[test]
fn sql_line_comments_are_not_harvested() {
    // Tier 3 is explicitly out of scope — leading `--` comments before a CTE
    // or table reference never become descriptions.
    let sql = "
        -- This should not attach to anything.
        CREATE TABLE customers (id INTEGER);
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let node = find_table(&result, "customers");
    assert!(
        node.description.is_none(),
        "leading `--` comments must not be surfaced as descriptions"
    );
}

#[test]
fn comment_targeting_unknown_table_is_benign() {
    // A comment pointing at a table that doesn't appear in the lineage must
    // neither crash nor attach to an unrelated node.
    let sql = "
        CREATE TABLE customers (id INTEGER);
        COMMENT ON TABLE orders IS 'Never used here.';
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let node = find_table(&result, "customers");
    assert!(node.description.is_none());
}

#[test]
fn comment_trims_surrounding_whitespace() {
    let sql = "
        CREATE TABLE customers (id INTEGER);
        COMMENT ON TABLE customers IS '   padded description   ';
    ";
    let result = analyze_sql(sql, Dialect::Postgres);
    let node = find_table(&result, "customers");
    assert_eq!(node.description.as_deref(), Some("padded description"));
}
