use flowscope_core::{analyze, AnalyzeRequest, Dialect, EdgeType, Node, NodeType};
use std::collections::BTreeSet;

fn analyze_hive(sql: &str) -> flowscope_core::AnalyzeResult {
    analyze(&AnalyzeRequest {
        sql: sql.to_owned(),
        files: None,
        dialect: Dialect::Hive,
        source_name: Some("leading_underscore_lineage".into()),
        options: None,
        schema: None,
        #[cfg(feature = "templating")]
        template_config: None,
    })
}

fn node<'a>(nodes: &'a [Node], id: &str) -> &'a Node {
    nodes
        .iter()
        .find(|node| node.id.as_ref() == id)
        .expect("edge endpoint must exist")
}

fn physical_value_roots(result: &flowscope_core::AnalyzeResult) -> BTreeSet<String> {
    result
        .edges
        .iter()
        .filter(|edge| matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation))
        .filter_map(|edge| {
            let source = node(&result.nodes, edge.from.as_ref());
            (source.node_type == NodeType::Column)
                .then(|| source.qualified_name.as_ref().map(ToString::to_string))
                .flatten()
        })
        .collect()
}

#[test]
fn leading_underscore_cte_alias_window_and_target_mapping_keep_lineage() {
    let result = analyze_hive(
        r#"
        WITH _base AS (
            SELECT _source.user_id AS _user_id,
                   _source.amount AS _amount,
                   _source.paid_at AS _paid_at
            FROM source_table AS _source
        )
        INSERT INTO target_table (_user_id, _first_amount)
        SELECT _user_id,
               FIRST_VALUE(_amount) OVER (
                   PARTITION BY _user_id ORDER BY _paid_at
               ) AS _first_amount
        FROM _base
        "#,
    );

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert_eq!(
        result
            .target_table
            .as_ref()
            .and_then(|table| table.qualified_name.clone()),
        Some("target_table".to_owned())
    );
    assert_eq!(
        result
            .source_tables
            .iter()
            .filter_map(|table| table.qualified_name.clone())
            .collect::<Vec<_>>(),
        vec!["source_table".to_owned()]
    );

    let output = result
        .nodes
        .iter()
        .find(|node| {
            node.label.as_ref() == "_first_amount"
                && node
                    .metadata
                    .as_ref()
                    .is_some_and(|metadata| metadata.contains_key("insertTarget"))
        })
        .expect("underscore output must retain its explicit INSERT target mapping");
    assert_eq!(
        output.metadata.as_ref().unwrap()["insertTarget"]["column"],
        "_first_amount"
    );
    assert_eq!(
        output.metadata.as_ref().unwrap()["insertTarget"]["position"],
        2
    );

    let controls: Vec<_> = result
        .edges
        .iter()
        .filter(|edge| edge.to == output.id && edge.edge_type == EdgeType::WindowControl)
        .collect();
    assert_eq!(
        controls.len(),
        2,
        "partition and order controls stay distinct"
    );
    let roles: BTreeSet<_> = controls
        .iter()
        .filter_map(|edge| {
            edge.metadata
                .as_ref()
                .and_then(|metadata| metadata.get("windowRole"))
                .and_then(serde_json::Value::as_str)
        })
        .collect();
    assert_eq!(roles, BTreeSet::from(["order", "partition"]));

    let value_sources: BTreeSet<_> = result
        .edges
        .iter()
        .filter(|edge| {
            edge.to == output.id
                && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
        })
        .map(|edge| node(&result.nodes, edge.from.as_ref()).label.to_string())
        .collect();
    assert_eq!(value_sources, BTreeSet::from(["_amount".to_owned()]));
    let control_sources: BTreeSet<_> = controls
        .iter()
        .map(|edge| node(&result.nodes, edge.from.as_ref()).label.to_string())
        .collect();
    assert_eq!(
        control_sources,
        BTreeSet::from(["_paid_at".to_owned(), "_user_id".to_owned()])
    );
}

#[test]
fn leading_underscore_names_do_not_change_physical_value_roots() {
    let underscored = analyze_hive(
        r#"
        WITH _base AS (
            SELECT _source.user_id AS _user_id, _source.amount AS _amount
            FROM source_table AS _source
        )
        SELECT _user_id, _amount FROM _base
        "#,
    );
    let plain = analyze_hive(
        r#"
        WITH base AS (
            SELECT source.user_id AS user_id, source.amount AS amount
            FROM source_table AS source
        )
        SELECT user_id, amount FROM base
        "#,
    );

    assert!(!underscored.summary.has_errors, "{:?}", underscored.issues);
    assert!(!plain.summary.has_errors, "{:?}", plain.issues);
    assert_eq!(
        physical_value_roots(&underscored),
        physical_value_roots(&plain)
    );
}
