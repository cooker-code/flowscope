use flowscope_core::{analyze, AnalyzeRequest, Dialect, EdgeType, NodeType};
use std::collections::{HashMap, HashSet};

fn analyze_hive(sql: &str) -> flowscope_core::AnalyzeResult {
    analyze(&AnalyzeRequest {
        sql: sql.to_owned(),
        files: None,
        dialect: Dialect::Hive,
        source_name: Some("lateral_view_struct_lineage".into()),
        options: None,
        schema: None,
        #[cfg(feature = "templating")]
        template_config: None,
    })
}

fn has_physical_root(
    result: &flowscope_core::AnalyzeResult,
    node_id: &str,
    expected_column: &str,
) -> bool {
    let nodes: HashMap<_, _> = result
        .nodes
        .iter()
        .map(|node| (node.id.as_ref(), node))
        .collect();
    let mut pending = vec![node_id.to_owned()];
    let mut visited = HashSet::new();
    while let Some(current) = pending.pop() {
        if !visited.insert(current.clone()) {
            continue;
        }
        for edge in result.edges.iter().filter(|edge| {
            edge.to.as_ref() == current
                && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
        }) {
            let source = nodes[edge.from.as_ref()];
            if source.node_type == NodeType::Column
                && source.label.as_ref() == expected_column
                && source
                    .qualified_name
                    .as_deref()
                    .is_some_and(|name| name.starts_with("db.t."))
            {
                return true;
            }
            pending.push(edge.from.to_string());
        }
    }
    false
}

#[test]
fn explode_struct_field_aliases_keep_physical_roots() {
    let result = analyze_hive(
        r#"
        WITH output_arrays AS (
            SELECT array(named_struct('goods', goods, 'level', level)) AS result_rows
            FROM db.t
        )
        SELECT r.goods, r.level
        FROM output_arrays
        LATERAL VIEW explode(result_rows) e AS r
        "#,
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert_eq!(
        result
            .source_tables
            .iter()
            .filter_map(|table| table.qualified_name.as_deref())
            .collect::<Vec<_>>(),
        vec!["db.t"]
    );
    let output_columns: Vec<_> = result
        .nodes
        .iter()
        .filter(|node| node.node_type == NodeType::Column)
        .filter(|node| matches!(node.label.as_ref(), "goods" | "level"))
        .collect();
    assert!(
        output_columns
            .iter()
            .any(|node| has_physical_root(&result, &node.id, "goods")),
        "r.goods must retain a path through explode(result_rows) to db.t.goods"
    );
    assert!(
        output_columns
            .iter()
            .any(|node| has_physical_root(&result, &node.id, "level")),
        "r.level must retain a path through explode(result_rows) to db.t.level"
    );
}

#[test]
fn posexplode_and_lateral_view_order_reuse_the_prior_udtf_input() {
    let result = analyze_hive(
        r#"
        WITH source_rows AS (
            SELECT array(named_struct('goods', goods)) AS rows_a FROM db.t
        )
        SELECT nested_row.goods
        FROM source_rows
        LATERAL VIEW posexplode(rows_a) p AS position, row_value
        LATERAL VIEW explode(array(row_value)) e AS nested_row
        "#,
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(
        !result
            .issues
            .iter()
            .any(|issue| issue.code == "UNRESOLVED_REFERENCE"),
        "the later UDTF input must resolve its prior output alias: {:?}",
        result.issues
    );
    assert!(result.nodes.iter().any(|node| {
        node.node_type == NodeType::Column
            && node.label.as_ref() == "goods"
            && has_physical_root(&result, &node.id, "goods")
    }));
}

#[test]
fn real_table_alias_wins_over_a_conflicting_lateral_output_alias() {
    let result = analyze_hive(
        r#"
        SELECT r.goods
        FROM db.real_rows AS r
        LATERAL VIEW explode(r.result_rows) e AS r
        "#,
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(result.nodes.iter().any(|node| {
        node.node_type == NodeType::Column
            && node.label.as_ref() == "goods"
            && node
                .qualified_name
                .as_deref()
                .is_some_and(|name| name == "db.real_rows.goods")
    }));
}

#[test]
fn duplicate_lateral_view_output_alias_is_an_error_without_source_bias() {
    let result = analyze_hive(
        r#"
        SELECT r.goods
        FROM db.t
        LATERAL VIEW explode(a) e1 AS r
        LATERAL VIEW explode(b) e2 AS r
        "#,
    );

    assert!(result.summary.has_errors, "{:?}", result.issues);
    assert!(result.issues.iter().any(|issue| {
        issue.code == "UNRESOLVED_REFERENCE"
            && issue.message.contains("LATERAL VIEW output alias 'r'")
            && issue.message.contains("ambiguous")
    }));
    let output = result
        .nodes
        .iter()
        .find(|node| node.node_type == NodeType::Column && node.label.as_ref() == "goods")
        .expect("projection output is retained for diagnostics");
    assert!(
        !has_physical_root(&result, &output.id, "a")
            && !has_physical_root(&result, &output.id, "b"),
        "an ambiguous output alias must not choose either lateral input: {:?}",
        result.edges
    );
}

#[test]
fn uniquely_proven_named_struct_member_keeps_its_base_value_lineage() {
    let result = analyze_hive(
        r#"
        WITH state AS (
            SELECT last_total_weekcount AS temp_settled FROM db.t
        ), start_search AS (
            SELECT aggregate(
                array(temp_settled),
                named_struct('remaining', temp_settled, 'idx', 0),
                (a, p) -> named_struct('remaining', a.remaining, 'idx', p)
            ) AS search_state
            FROM state
        )
        SELECT search_state.idx AS start_idx FROM start_search
        "#,
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(result.nodes.iter().any(|node| {
        node.node_type == NodeType::Column
            && node.label.as_ref() == "start_idx"
            && has_physical_root(&result, &node.id, "last_total_weekcount")
    }));
    assert!(
        !result.nodes.iter().any(|node| {
            node.node_type == NodeType::Column
                && node.qualified_name.as_deref() == Some("search_state.idx")
        }),
        "derived struct member must not become a pseudo physical column"
    );
}

#[test]
fn scalar_wrappers_containing_named_struct_do_not_enable_member_fallback() {
    for scalar_expression in [
        "length('named_struct(')",
        "size(array(named_struct('idx', source_value)))",
    ] {
        let result = analyze_hive(&format!(
            "WITH source AS (SELECT source_value FROM db.t), derived AS (SELECT {scalar_expression} AS scalar_value FROM source) SELECT scalar_value.idx AS value FROM derived"
        ));
        assert!(
            !result.nodes.iter().any(|node| {
                node.node_type == NodeType::Column
                    && node.label.as_ref() == "value"
                    && has_physical_root(&result, &node.id, "source_value")
            }),
            "scalar expression {scalar_expression} must not be treated as a struct producer"
        );
    }
}

#[test]
fn lateral_view_fields_keep_window_controls_out_of_value_lineage() {
    let result = analyze_hive(
        r#"
        WITH source_rows AS (
            SELECT array(named_struct('goods', goods, 'level', level)) AS rows_a FROM db.t
        )
        SELECT FIRST_VALUE(r.goods) OVER (
            PARTITION BY r.level ORDER BY r.goods
        ) AS first_goods
        FROM source_rows
        LATERAL VIEW explode(rows_a) e AS r
        "#,
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let output = result
        .nodes
        .iter()
        .find(|node| node.node_type == NodeType::Column && node.label.as_ref() == "first_goods")
        .expect("window output");
    let controls: Vec<_> = result
        .edges
        .iter()
        .filter(|edge| edge.to == output.id && edge.edge_type == EdgeType::WindowControl)
        .collect();
    assert_eq!(controls.len(), 2);
    let roles: HashSet<_> = controls
        .iter()
        .filter_map(|edge| {
            edge.metadata
                .as_ref()
                .and_then(|metadata| metadata.get("windowRole"))
                .and_then(serde_json::Value::as_str)
        })
        .collect();
    assert_eq!(roles, HashSet::from(["partition", "order"]));
    assert!(result.edges.iter().any(|edge| {
        edge.to == output.id && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
    }));
    assert!(has_physical_root(&result, &output.id, "goods"));
}
