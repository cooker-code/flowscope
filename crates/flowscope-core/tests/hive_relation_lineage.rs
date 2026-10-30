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

fn request(sql: &str, tables: Vec<SchemaTable>) -> AnalyzeRequest {
    request_with_dialect(sql, tables, Dialect::Hive)
}

fn request_with_dialect(sql: &str, tables: Vec<SchemaTable>, dialect: Dialect) -> AnalyzeRequest {
    AnalyzeRequest {
        sql: sql.to_string(),
        files: None,
        dialect,
        source_name: Some("hive_relation_lineage".to_string()),
        options: None,
        schema: Some(SchemaMetadata {
            tables,
            allow_implied: false,
            ..Default::default()
        }),
        #[cfg(feature = "templating")]
        template_config: None,
    }
}

#[test]
fn ordinary_hive_select_and_group_by_do_not_add_grouping_metadata() {
    for sql in [
        "SELECT region, SUM(amount) AS total_amount FROM source_table GROUP BY region",
        "SELECT region, amount FROM source_table",
    ] {
        let result = analyze(&request(
            sql,
            vec![SchemaTable {
                catalog: None,
                schema: None,
                name: "source_table".to_string(),
                columns: ["region", "amount"]
                    .iter()
                    .map(|name| column(name))
                    .collect(),
            }],
        ));
        assert!(!result.summary.has_errors, "{:?}", result.issues);
        assert!(result.nodes.iter().all(|node| {
            node.metadata
                .as_ref()
                .and_then(|metadata| metadata.get("groupBy"))
                .is_none()
        }));
    }
}

#[test]
fn non_hive_grouping_sets_do_not_gain_hive_grouping_metadata() {
    let result = analyze(&request_with_dialect(
        "SELECT region, SUM(amount) AS total_amount FROM source_table GROUP BY GROUPING SETS ((region), ())",
        vec![SchemaTable {
            catalog: None,
            schema: None,
            name: "source_table".to_string(),
            columns: ["region", "amount"].iter().map(|name| column(name)).collect(),
        }],
        Dialect::Postgres,
    ));
    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(result.nodes.iter().all(|node| {
        node.metadata
            .as_ref()
            .and_then(|metadata| metadata.get("groupBy"))
            .is_none()
    }));
    assert!(
        !result.nodes.iter().any(|node| {
            node.label.as_ref() == "region"
                && node
                    .aggregation
                    .as_ref()
                    .is_some_and(|aggregation| aggregation.is_grouping_key)
        }),
        "non-Hive GROUPING SETS must retain its existing whole-expression grouping-key behavior"
    );
}

#[test]
fn values_relation_retains_rows_and_closes_select_star_insert_lineage() {
    let result = analyze(&request(
        r#"
            INSERT OVERWRITE TABLE target_table (id, label)
            SELECT * FROM VALUES
                (CAST(NULL AS INT), 'first'), (2, 'second')
            AS seed(id, label)
        "#,
        vec![SchemaTable {
            catalog: None,
            schema: None,
            name: "target_table".to_string(),
            columns: ["id", "label"].iter().map(|name| column(name)).collect(),
        }],
    ));

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(result.source_tables.is_empty(), "VALUES is not physical");
    let value_rows: HashSet<_> = result
        .nodes
        .iter()
        .filter_map(|node| {
            node.metadata
                .as_ref()?
                .get("columnValues")
                .map(|values| (node.label.to_string(), values.clone()))
        })
        .collect();
    assert!(value_rows.contains(&(
        "id".to_string(),
        serde_json::json!(["CAST(NULL AS INT)", "2"]),
    )));
    assert!(value_rows.contains(&(
        "label".to_string(),
        serde_json::json!(["'first'", "'second'"]),
    )));
    for (name, position) in [("id", 1), ("label", 2)] {
        assert!(result.nodes.iter().any(|node| {
            node.label.as_ref() == name
                && node
                    .metadata
                    .as_ref()
                    .and_then(|metadata| metadata.get("insertTarget"))
                    .is_some_and(|target| {
                        target["table"] == "target_table" && target["position"] == position
                    })
        }));
    }
}

#[test]
fn values_relation_rejects_alias_width_mismatch() {
    let result = analyze(&request(
        "SELECT * FROM VALUES (1, 2), (3) AS seed(first, second)",
        Vec::new(),
    ));
    assert!(result.summary.has_errors);
    assert!(result
        .issues
        .iter()
        .any(|issue| issue.code == "INVALID_REQUEST"));
}

#[test]
fn array_exists_keeps_collection_and_captures_not_lambda_bindings() {
    let result = analyze(&request(
        r#"
            SELECT exists(
                push_groups,
                g -> g.weeks < outer_weeks AND g.bucket = bucket_key
            ) AS has_matching_group
            FROM source_table
        "#,
        vec![SchemaTable {
            catalog: None,
            schema: None,
            name: "source_table".to_string(),
            columns: ["push_groups", "outer_weeks", "bucket_key"]
                .iter()
                .map(|name| column(name))
                .collect(),
        }],
    ));

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let nodes_by_id: std::collections::HashMap<_, _> =
        result.nodes.iter().map(|node| (&node.id, node)).collect();
    let output = result
        .nodes
        .iter()
        .find(|node| node.label.as_ref() == "has_matching_group")
        .expect("array exists output");
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
            "push_groups".to_string(),
            "outer_weeks".to_string(),
            "bucket_key".to_string(),
        ])
    );
    let physical_labels: HashSet<_> = result
        .nodes
        .iter()
        .filter(|node| node.node_type == NodeType::Column)
        .map(|node| node.label.to_string())
        .collect();
    for lambda_local in ["g", "weeks", "bucket"] {
        assert!(!physical_labels.contains(lambda_local));
    }
}

#[test]
fn parallel_grouping_sets_keep_structure_without_control_value_edges() {
    let result = analyze(&request(
        r#"
            SELECT region, subject_name, SUM(amount) AS total_amount
            FROM source_table
            GROUP BY GROUPING SETS ((region, subject_name), ()),
                     GROUPING SETS ((), (subject_name))
        "#,
        vec![SchemaTable {
            catalog: None,
            schema: None,
            name: "source_table".to_string(),
            columns: ["region", "subject_name", "amount"]
                .iter()
                .map(|name| column(name))
                .collect(),
        }],
    ));

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let nodes_by_id: std::collections::HashMap<_, _> =
        result.nodes.iter().map(|node| (&node.id, node)).collect();
    let total = result
        .nodes
        .iter()
        .find(|node| node.label.as_ref() == "total_amount")
        .expect("aggregate output");
    let roots: HashSet<_> = result
        .edges
        .iter()
        .filter(|edge| {
            edge.to == total.id
                && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
        })
        .filter_map(|edge| nodes_by_id.get(&edge.from))
        .map(|node| node.label.to_string())
        .collect();
    assert_eq!(roots, HashSet::from(["amount".to_string()]));

    let group_by = result
        .nodes
        .iter()
        .find_map(|node| node.metadata.as_ref()?.get("groupBy"))
        .expect("grouping metadata belongs to the query result relation");
    let group_by = group_by.as_array().expect("grouping metadata sequence");
    assert_eq!(group_by.len(), 1);
    let group_by = &group_by[0];
    let expressions = group_by["expressions"]
        .as_array()
        .expect("group expressions");
    assert_eq!(expressions.len(), 2, "parallel sets stay separate");
    assert_eq!(expressions[0]["kind"], "groupingSets");
    assert_eq!(expressions[1]["kind"], "groupingSets");
    assert!(expressions[0]["sets"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!([])));
    assert!(expressions[1]["sets"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!([])));
}

#[test]
fn grouping_sets_modifier_keeps_its_leaf_and_empty_set() {
    let result = analyze(&request(
        r#"
            SELECT region, SUM(amount) AS total_amount
            FROM source_table
            GROUP BY region GROUPING SETS ((subject_name), ())
        "#,
        vec![SchemaTable {
            catalog: None,
            schema: None,
            name: "source_table".to_string(),
            columns: ["region", "subject_name", "amount"]
                .iter()
                .map(|name| column(name))
                .collect(),
        }],
    ));

    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let group_by = result
        .nodes
        .iter()
        .find_map(|node| node.metadata.as_ref()?.get("groupBy"))
        .and_then(|metadata| metadata.as_array())
        .and_then(|groupings| groupings.first())
        .expect("grouping metadata");
    assert_eq!(group_by["modifiers"][0]["kind"], "groupingSets");
    assert_eq!(
        group_by["modifiers"][0]["sets"],
        serde_json::json!([["subject_name"], []])
    );
}
