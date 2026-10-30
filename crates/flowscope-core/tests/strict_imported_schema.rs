use flowscope_core::{
    analyze, issue_codes, AnalyzeRequest, ColumnSchema, Dialect, SchemaMetadata, SchemaTable,
};

fn table(name: &str) -> SchemaTable {
    SchemaTable {
        catalog: None,
        schema: None,
        name: name.to_string(),
        columns: vec![ColumnSchema {
            name: "id".to_string(),
            data_type: None,
            is_primary_key: None,
            foreign_key: None,
        }],
    }
}

fn analyze_with_schema(schema: Option<SchemaMetadata>, sql: &str) -> flowscope_core::AnalyzeResult {
    analyze(&AnalyzeRequest {
        sql: sql.to_owned(),
        files: None,
        dialect: Dialect::Hive,
        source_name: Some("strict_imported_schema".to_string()),
        options: None,
        schema,
        #[cfg(feature = "templating")]
        template_config: None,
    })
}

#[test]
fn strict_imported_schema_accepts_known_source_table() {
    let result = analyze_with_schema(
        Some(SchemaMetadata {
            tables: vec![table("known_source")],
            allow_implied: false,
            ..Default::default()
        }),
        "SELECT id FROM known_source",
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(result.issues.is_empty(), "{:?}", result.issues);
}

#[test]
fn strict_imported_schema_rejects_missing_source_table() {
    let result = analyze_with_schema(
        Some(SchemaMetadata {
            tables: vec![table("known_source")],
            allow_implied: false,
            ..Default::default()
        }),
        "SELECT id FROM missing_source",
    );

    assert!(result.summary.has_errors, "{:?}", result.issues);
    assert!(result.issues.iter().any(|issue| {
        issue.code == issue_codes::UNKNOWN_TABLE
            && issue.message.contains("missing_source")
            && issue.message.contains("strict imported schema")
    }));
}

#[test]
fn strict_empty_imported_schema_rejects_symbolic_source_table() {
    let result = analyze_with_schema(
        Some(SchemaMetadata {
            allow_implied: false,
            ..Default::default()
        }),
        "SELECT id FROM missing_source",
    );

    assert!(result.summary.has_errors, "{:?}", result.issues);
    assert!(
        result
            .issues
            .iter()
            .any(|issue| issue.code == issue_codes::UNKNOWN_TABLE),
        "{:?}",
        result.issues
    );
}

#[test]
fn absent_schema_keeps_symbolic_source_table_parseable() {
    let result = analyze_with_schema(None, "SELECT id FROM symbolic_source");

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(result.issues.is_empty(), "{:?}", result.issues);
}

#[test]
fn implied_schema_mode_keeps_partial_schema_best_effort() {
    let result = analyze_with_schema(
        Some(SchemaMetadata {
            tables: vec![table("known_source")],
            allow_implied: true,
            ..Default::default()
        }),
        "SELECT id FROM missing_source",
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(result.issues.iter().any(|issue| {
        issue.code == issue_codes::UNRESOLVED_REFERENCE && issue.message.contains("missing_source")
    }));
}
