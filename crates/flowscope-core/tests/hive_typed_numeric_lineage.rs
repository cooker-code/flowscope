use flowscope_core::{
    analyze, AnalyzeRequest, ColumnSchema, Dialect, EdgeType, NodeType, SchemaMetadata, SchemaTable,
};

#[test]
fn hive_double_suffix_is_a_literal_not_a_physical_column() {
    let result = analyze(&AnalyzeRequest {
        sql: "SELECT CASE WHEN abs(fee) < 0.00005D THEN 0D ELSE fee END AS rounded_fee FROM source_table"
            .to_string(),
        files: None,
        dialect: Dialect::Hive,
        source_name: Some("hive_typed_numeric_lineage".to_string()),
        options: None,
        schema: Some(SchemaMetadata {
            tables: vec![SchemaTable {
                catalog: None,
                schema: None,
                name: "source_table".to_string(),
                columns: vec![ColumnSchema {
                    name: "fee".to_string(),
                    data_type: Some("double".to_string()),
                    is_primary_key: None,
                    foreign_key: None,
                }],
            }],
            allow_implied: true,
            ..Default::default()
        }),
        #[cfg(feature = "templating")]
        template_config: None,
    });

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let output = result
        .nodes
        .iter()
        .find(|node| node.node_type == NodeType::Column && node.label.as_ref() == "rounded_fee")
        .expect("rounded_fee output");
    let nodes_by_id: std::collections::HashMap<_, _> =
        result.nodes.iter().map(|node| (&node.id, node)).collect();
    let roots: std::collections::HashSet<_> = result
        .edges
        .iter()
        .filter(|edge| {
            edge.to == output.id
                && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
        })
        .filter_map(|edge| nodes_by_id.get(&edge.from))
        .map(|node| node.label.to_string())
        .collect();
    assert_eq!(roots, std::collections::HashSet::from(["fee".to_string()]));
    assert!(!result.nodes.iter().any(|node| {
        node.node_type == NodeType::Column && matches!(node.label.as_ref(), "0.00005D" | "0D")
    }));
}
