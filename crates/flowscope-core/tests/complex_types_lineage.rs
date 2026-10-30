use flowscope_core::{
    analyze, AnalyzeRequest, ColumnSchema, Dialect, EdgeType, NodeType, SchemaMetadata, SchemaTable,
};
use std::collections::HashSet;

fn column(name: &str) -> ColumnSchema {
    ColumnSchema {
        name: name.to_string(),
        data_type: None,
        is_primary_key: None,
        foreign_key: None,
    }
}

#[test]
fn hive_complex_cast_keeps_value_window_and_target_lineage() {
    let sql = r#"
            INSERT OVERWRITE TABLE target_table
            SELECT
                CAST(src.payload AS ARRAY<STRUCT<item_id:STRING, attrs:MAP<STRING,ARRAY<INT>>>>) AS result,
                FIRST_VALUE(src.value) OVER (
                    PARTITION BY src.partition_key
                    ORDER BY src.order_key
                ) AS first_value
            FROM source_table src
        "#;
    let result = analyze(&AnalyzeRequest {
        sql: sql.to_string(),
        files: None,
        dialect: Dialect::Hive,
        source_name: Some("complex_types_lineage".to_string()),
        options: None,
        schema: Some(SchemaMetadata {
            tables: vec![
                SchemaTable {
                    catalog: None,
                    schema: None,
                    name: "source_table".to_string(),
                    columns: ["payload", "value", "partition_key", "order_key"]
                        .iter()
                        .map(|name| column(name))
                        .collect(),
                },
                SchemaTable {
                    catalog: None,
                    schema: None,
                    name: "target_table".to_string(),
                    columns: ["result", "first_value"]
                        .iter()
                        .map(|name| column(name))
                        .collect(),
                },
            ],
            allow_implied: true,
            ..Default::default()
        }),
        #[cfg(feature = "templating")]
        template_config: None,
    });

    assert!(!result.summary.has_errors, "{:?}", result.issues);

    let nodes_by_id: std::collections::HashMap<_, _> =
        result.nodes.iter().map(|node| (&node.id, node)).collect();
    let result_column = result
        .nodes
        .iter()
        .find(|node| node.node_type == NodeType::Column && node.label.as_ref() == "result")
        .expect("complex CAST output column");
    let first_value = result
        .nodes
        .iter()
        .find(|node| node.node_type == NodeType::Column && node.label.as_ref() == "first_value")
        .expect("window output column");

    assert!(result.edges.iter().any(|edge| {
        edge.to == result_column.id
            && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
            && nodes_by_id
                .get(&edge.from)
                .is_some_and(|node| node.label.as_ref() == "payload")
    }));
    assert!(result.edges.iter().any(|edge| {
        edge.to == first_value.id
            && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
            && nodes_by_id
                .get(&edge.from)
                .is_some_and(|node| node.label.as_ref() == "value")
    }));

    let controls: HashSet<_> = result
        .edges
        .iter()
        .filter(|edge| edge.to == first_value.id && edge.edge_type == EdgeType::WindowControl)
        .filter_map(|edge| nodes_by_id.get(&edge.from))
        .map(|node| node.label.to_string())
        .collect();
    assert_eq!(
        controls,
        HashSet::from(["partition_key".to_string(), "order_key".to_string()])
    );

    let physical_columns: HashSet<_> = result
        .nodes
        .iter()
        .filter(|node| node.node_type == NodeType::Column)
        .map(|node| node.label.to_string())
        .collect();
    assert!(!physical_columns.contains("item_id"));
    assert!(!physical_columns.contains("attrs"));

    for (label, target_column, position) in
        [("result", "result", 1), ("first_value", "first_value", 2)]
    {
        let node = result
            .nodes
            .iter()
            .find(|node| {
                node.label.as_ref() == label
                    && node
                        .metadata
                        .as_ref()
                        .is_some_and(|metadata| metadata.contains_key("insertTarget"))
            })
            .expect("insert target mapping");
        let mapping = &node.metadata.as_ref().unwrap()["insertTarget"];
        assert_eq!(mapping["column"], target_column);
        assert_eq!(mapping["position"], position);
    }
}

#[test]
fn hive_aggregate_struct_member_keeps_root_value_lineage() {
    let result = analyze(&AnalyzeRequest {
        sql: r#"
            SELECT aggregate(
                transform(periods, (p, i) -> named_struct('items', p.weeks, 'idx', i)),
                named_struct('items', start_idx),
                (acc, item) -> acc
            ).items AS allocated_push_orders
            FROM source_table
        "#
        .to_string(),
        files: None,
        dialect: Dialect::Hive,
        source_name: Some("compound_field_access_lineage".to_string()),
        options: None,
        schema: Some(SchemaMetadata {
            tables: vec![SchemaTable {
                catalog: None,
                schema: None,
                name: "source_table".to_string(),
                columns: ["periods", "start_idx"]
                    .iter()
                    .map(|name| column(name))
                    .collect(),
            }],
            allow_implied: true,
            ..Default::default()
        }),
        #[cfg(feature = "templating")]
        template_config: None,
    });

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let nodes_by_id: std::collections::HashMap<_, _> =
        result.nodes.iter().map(|node| (&node.id, node)).collect();
    let output = result
        .nodes
        .iter()
        .find(|node| {
            node.node_type == NodeType::Column && node.label.as_ref() == "allocated_push_orders"
        })
        .expect("aggregate struct member output column");

    let roots: HashSet<_> = result
        .edges
        .iter()
        .filter(|edge| {
            edge.to == output.id
                && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
        })
        .filter_map(|edge| nodes_by_id.get(&edge.from))
        .map(|node| node.label.to_string())
        .collect();
    assert_eq!(
        roots,
        HashSet::from(["periods".to_string(), "start_idx".to_string()])
    );
    assert!(!roots.contains("items"));
    assert!(!roots.contains("idx"));
}

#[test]
fn hive_lambda_boolean_predicate_keeps_bindings_out_of_physical_lineage() {
    let result = analyze(&AnalyzeRequest {
        sql: r#"
            SELECT filter(
                push_units,
                u -> u.goods = goods_key AND u.level = level_key OR u.sale = sale_key
            ) AS matching_units
            FROM source_table
        "#
        .to_string(),
        files: None,
        dialect: Dialect::Hive,
        source_name: Some("hive_lambda_boolean_lineage".to_string()),
        options: None,
        schema: Some(SchemaMetadata {
            tables: vec![SchemaTable {
                catalog: None,
                schema: None,
                name: "source_table".to_string(),
                columns: ["push_units", "goods_key", "level_key", "sale_key"]
                    .iter()
                    .map(|name| column(name))
                    .collect(),
            }],
            allow_implied: true,
            ..Default::default()
        }),
        #[cfg(feature = "templating")]
        template_config: None,
    });

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let nodes_by_id: std::collections::HashMap<_, _> =
        result.nodes.iter().map(|node| (&node.id, node)).collect();
    let output = result
        .nodes
        .iter()
        .find(|node| node.node_type == NodeType::Column && node.label.as_ref() == "matching_units")
        .expect("filter output column");
    let roots: HashSet<_> = result
        .edges
        .iter()
        .filter(|edge| {
            edge.to == output.id
                && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
        })
        .filter_map(|edge| nodes_by_id.get(&edge.from))
        .map(|node| node.label.to_string())
        .collect();
    assert_eq!(
        roots,
        HashSet::from([
            "push_units".to_string(),
            "goods_key".to_string(),
            "level_key".to_string(),
            "sale_key".to_string(),
        ])
    );
    assert!(!roots.contains("u"));
    assert!(!roots.contains("goods"));
    assert!(!roots.contains("level"));
    assert!(!roots.contains("sale"));
}
