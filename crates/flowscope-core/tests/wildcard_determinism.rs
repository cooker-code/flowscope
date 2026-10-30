use flowscope_core::{analyze, AnalyzeRequest, Dialect, NodeType};
use std::collections::HashSet;

fn analyze_without_schema(sql: &str) -> flowscope_core::AnalyzeResult {
    analyze(&AnalyzeRequest {
        sql: sql.to_string(),
        files: None,
        dialect: Dialect::Hive,
        source_name: Some("wildcard_determinism".to_string()),
        options: None,
        schema: None,
        #[cfg(feature = "templating")]
        template_config: None,
    })
}

fn stable_result_json(sql: &str) -> serde_json::Value {
    let mut value =
        serde_json::to_value(analyze_without_schema(sql)).expect("analysis result serializes");
    remove_schema_timestamps(&mut value);
    value
}

fn remove_schema_timestamps(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(object) => {
            object.remove("updatedAt");
            for child in object.values_mut() {
                remove_schema_timestamps(child);
            }
        }
        serde_json::Value::Array(values) => {
            for child in values {
                remove_schema_timestamps(child);
            }
        }
        _ => {}
    }
}

const MULTI_LEVEL_STAR_SQL: &str = r#"
    WITH raw_pass AS (
        SELECT * FROM raw_events
    ),
    normalized_pass AS (
        SELECT * FROM raw_pass
    ),
    selected AS (
        SELECT event_id, event_type, user_id
        FROM normalized_pass
    )
    SELECT * FROM selected
"#;

#[test]
fn symbolic_select_star_is_deterministic_across_repeated_analyses() {
    let first = stable_result_json(MULTI_LEVEL_STAR_SQL);
    for _ in 0..16 {
        assert_eq!(
            stable_result_json(MULTI_LEVEL_STAR_SQL),
            first,
            "symbolic wildcard result must be stable apart from SchemaRegistry's documented generated timestamp"
        );
    }
}

#[test]
fn symbolic_select_star_still_propagates_explicit_columns_through_every_level() {
    let result = analyze_without_schema(MULTI_LEVEL_STAR_SQL);
    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let raw_columns: HashSet<_> = result
        .nodes
        .iter()
        .filter(|node| {
            node.node_type == NodeType::Column
                && node
                    .qualified_name
                    .as_deref()
                    .is_some_and(|name| name.starts_with("raw_events."))
        })
        .map(|node| node.label.to_string())
        .collect();
    assert_eq!(
        raw_columns,
        HashSet::from([
            "event_id".to_string(),
            "event_type".to_string(),
            "user_id".to_string(),
        ])
    );
}

#[test]
fn reused_derived_aliases_keep_their_own_wildcard_paths() {
    let result = analyze_without_schema(
        r#"
            SELECT left_branch.customer_id, right_branch.order_id
            FROM (
                SELECT repeated.customer_id
                FROM (SELECT * FROM raw_orders) repeated
            ) AS left_branch
            JOIN (
                SELECT repeated.order_id
                FROM (SELECT * FROM raw_orders) repeated
            ) AS right_branch ON 1 = 1
        "#,
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let raw_columns: HashSet<_> = result
        .nodes
        .iter()
        .filter(|node| {
            node.node_type == NodeType::Column
                && node
                    .qualified_name
                    .as_deref()
                    .is_some_and(|name| name.starts_with("raw_orders."))
        })
        .map(|node| node.label.to_string())
        .collect();
    assert_eq!(
        raw_columns,
        HashSet::from(["customer_id".to_string(), "order_id".to_string()])
    );
}

#[test]
fn cte_self_join_instances_propagate_to_the_shared_definition_source() {
    let result = analyze_without_schema(
        r#"
            WITH raw_pass AS (
                SELECT * FROM raw_events
            )
            SELECT a.event_id AS left_event_id, b.user_id AS right_user_id
            FROM raw_pass AS a
            JOIN raw_pass AS b ON a.event_id = b.event_id
        "#,
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let raw_columns: HashSet<_> = result
        .nodes
        .iter()
        .filter(|node| {
            node.node_type == NodeType::Column
                && node
                    .qualified_name
                    .as_deref()
                    .is_some_and(|name| name.starts_with("raw_events."))
        })
        .map(|node| node.label.to_string())
        .collect();
    assert!(raw_columns.contains("event_id"));
    assert!(raw_columns.contains("user_id"));

    let output_id = result
        .nodes
        .iter()
        .find(|node| node.node_type == NodeType::Output)
        .expect("standalone SELECT output relation")
        .id
        .clone();
    for (source_name, output_name) in [
        ("raw_events.event_id", "left_event_id"),
        ("raw_events.user_id", "right_user_id"),
    ] {
        let source_id = result
            .nodes
            .iter()
            .find(|node| node.qualified_name.as_deref() == Some(source_name))
            .expect("inferred raw source column")
            .id
            .clone();
        let output_id = result
            .edges
            .iter()
            .find(|edge| {
                edge.from == output_id
                    && edge.edge_type == flowscope_core::EdgeType::Ownership
                    && result
                        .nodes
                        .iter()
                        .any(|node| node.id == edge.to && node.label.as_ref() == output_name)
            })
            .expect("aliased SELECT output ownership")
            .to
            .clone();
        assert!(
            has_value_ancestor(&result, &source_id, &output_id),
            "{source_name} must reach {output_name} through its own CTE self-join instance"
        );
    }
}

fn has_value_ancestor(
    result: &flowscope_core::AnalyzeResult,
    source_id: &std::sync::Arc<str>,
    output_id: &std::sync::Arc<str>,
) -> bool {
    let mut reachable = HashSet::from([output_id.clone()]);
    let mut changed = true;
    while changed {
        changed = false;
        for edge in &result.edges {
            if matches!(
                edge.edge_type,
                flowscope_core::EdgeType::DataFlow | flowscope_core::EdgeType::Derivation
            ) && reachable.contains(&edge.to)
                && reachable.insert(edge.from.clone())
            {
                changed = true;
            }
        }
    }
    reachable.contains(source_id)
}
