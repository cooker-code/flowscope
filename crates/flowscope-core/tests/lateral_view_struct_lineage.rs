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

#[test]
fn qualified_duplicate_posexplode_columns_keep_separate_roots() {
    let result = analyze_hive("SELECT p.pos AS left_pos, q.pos AS right_pos, left_value, q.right_value FROM db.t LATERAL VIEW posexplode(a) p AS pos, left_value LATERAL VIEW posexplode(b) q AS pos, right_value WHERE p.pos = q.pos");
    assert!(!result.summary.has_errors, "{:?}", result.issues);
    for (output, root, wrong) in [
        ("left_pos", "a", "b"),
        ("right_pos", "b", "a"),
        ("left_value", "a", "b"),
        ("right_value", "b", "a"),
    ] {
        let node = result
            .nodes
            .iter()
            .find(|n| n.node_type == NodeType::Column && n.label.as_ref() == output)
            .unwrap();
        assert!(
            has_physical_root(&result, &node.id, root),
            "{output}: {:?}",
            result.edges
        );
        assert!(!has_physical_root(&result, &node.id, wrong));
        assert!(result
            .edges
            .iter()
            .any(|e| e.to == node.id && e.edge_type == EdgeType::Derivation));
    }
    assert!(!result
        .nodes
        .iter()
        .any(|n| n.qualified_name.as_deref().is_some_and(|s| [
            "db.t.pos",
            "db.t.left_value",
            "db.t.right_value"
        ]
        .contains(&s))));
}

/// Stop at physical columns, including the previous-day self-source of an
/// INSERT OVERWRITE. Following through that node again would cross runs.
fn physical_sources(result: &flowscope_core::AnalyzeResult, output: &str) -> HashSet<String> {
    let nodes: HashMap<_, _> = result.nodes.iter().map(|n| (n.id.as_ref(), n)).collect();
    let mut pending = vec![output.to_string()];
    let mut visited = HashSet::new();
    let mut roots = HashSet::new();
    while let Some(current) = pending.pop() {
        if !visited.insert(current.clone()) {
            continue;
        }
        for edge in result.edges.iter().filter(|e| {
            e.to.as_ref() == current
                && matches!(e.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
        }) {
            let source = nodes[edge.from.as_ref()];
            if source.node_type != NodeType::Column {
                continue;
            }
            if let Some(name) = source
                .qualified_name
                .as_deref()
                .filter(|name| name.starts_with("dw_conan_dwd."))
            {
                roots.insert(name.to_string());
            } else {
                pending.push(source.id.to_string());
            }
        }
    }
    roots
}

#[test]
fn original_audit_559417_accepts_qualified_duplicate_positions() {
    let result = analyze_hive(include_str!("fixtures/hive_lateral_view_audit_559417.sql"));
    assert!(result.issues.is_empty(), "{:?}", result.issues);
    let json = serde_json::to_value(&result).unwrap();
    assert_eq!(json["sqlType"], "insert");
    assert_eq!(json["insertType"], "overwrite");
    let target = "dw_conan_dwd.dwd_conan_course_pedia_attend_da";
    assert_eq!(
        result
            .target_table
            .as_ref()
            .and_then(|n| n.qualified_name.as_deref()),
        Some(target)
    );
    assert_eq!(
        result
            .source_tables
            .iter()
            .filter_map(|t| t.qualified_name.as_deref())
            .collect::<HashSet<_>>(),
        HashSet::from([target, "dw_conan_dwd.dwd_conan_course_pedia_attend_di"])
    );
    assert!(!result.nodes.iter().any(|n| n
        .qualified_name
        .as_deref()
        .is_some_and(|s| s.ends_with(".index_1")
            || s.ends_with(".attend_dt")
            || s.ends_with(".formal_dt"))));
    for name in [
        "user_id",
        "package_id",
        "course_id",
        "is_attend",
        "is_finish",
        "is_review",
        "first_attend_tp",
        "first_attend_dt",
        "last_attend_tp",
        "last_attend_dt",
        "first_review_tp",
        "first_review_dt",
        "first_finish_tp",
        "first_finish_dt",
        "attend_dt_list",
        "formal_attend_dt_list",
    ] {
        let output = result
            .nodes
            .iter()
            .find(|n| n.qualified_name.as_deref() == Some(format!("{target}.{name}").as_str()))
            .unwrap();
        let expected = HashSet::from([
            format!("{target}.{name}"),
            format!("dw_conan_dwd.dwd_conan_course_pedia_attend_di.{name}"),
        ]);
        assert_eq!(
            physical_sources(&result, &output.id),
            expected,
            "target field {name}"
        );
    }
    for (name, root) in [
        ("attend_dt", "attend_dt_list"),
        ("formal_dt", "formal_attend_dt_list"),
    ] {
        let output = result
            .nodes
            .iter()
            .find(|n| n.label.as_ref() == name && n.qualified_name.is_none())
            .unwrap();
        assert_eq!(
            physical_sources(&result, &output.id),
            HashSet::from([
                format!("{target}.{root}"),
                format!("dw_conan_dwd.dwd_conan_course_pedia_attend_di.{root}")
            ])
        );
    }
    let load = result
        .nodes
        .iter()
        .find(|n| n.label.as_ref() == "load_datetime")
        .unwrap();
    assert!(physical_sources(&result, &load.id).is_empty());
}

#[test]
fn repeated_names_only_fail_when_an_ambiguous_reference_is_used() {
    let from =
        "FROM db.t LATERAL VIEW posexplode(a) p AS pos, va LATERAL VIEW posexplode(b) q AS pos, vb";
    for projection in ["va, vb", "p.pos, q.pos"] {
        let result = analyze_hive(&format!("SELECT {projection} {from}"));
        assert!(!result.summary.has_errors, "{:?}", result.issues);
    }
    for sql in [
        format!("SELECT pos {from}"),
        format!("SELECT va {from} WHERE pos = 0"),
        format!("SELECT va {from} LATERAL VIEW explode(array(pos)) r AS vc"),
    ] {
        let result = analyze_hive(&sql);
        assert!(result.summary.has_errors, "{sql}: {:?}", result.issues);
        assert!(result
            .issues
            .iter()
            .any(|i| i.code == "UNRESOLVED_REFERENCE" && i.message.contains("ambiguous")));
    }
}

#[test]
fn unknown_qualified_output_does_not_choose_a_udtf_input() {
    let result = analyze_hive("SELECT p.missing FROM db.t LATERAL VIEW explode(a) p AS value");
    assert!(result.summary.has_errors, "{:?}", result.issues);
    let output = result
        .nodes
        .iter()
        .find(|n| n.node_type == NodeType::Column && n.label.as_ref() == "missing")
        .unwrap();
    assert!(!has_physical_root(&result, &output.id, "a"));
    assert!(!result
        .nodes
        .iter()
        .any(|n| n.qualified_name.as_deref() == Some("db.t.missing")));
}

#[test]
fn constant_udtf_outputs_are_bound_without_physical_roots() {
    let result = analyze_hive("SELECT p.pos AS left_pos, q.pos AS right_pos, va, vb FROM db.t LATERAL VIEW posexplode(array('a')) p AS pos, va LATERAL VIEW posexplode(array('b')) q AS pos, vb WHERE p.pos = q.pos");
    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(!result.nodes.iter().any(|n| n
        .qualified_name
        .as_deref()
        .is_some_and(|s| s.starts_with("db.t."))));
}

#[test]
fn qualified_struct_members_and_chained_inputs_keep_roots() {
    let result = analyze_hive("SELECT e.r.goods AS goods, nested.goods AS again FROM db.t LATERAL VIEW explode(array(named_struct('goods', goods))) e AS r LATERAL VIEW explode(array(e.r)) e2 AS nested");
    assert!(!result.summary.has_errors, "{:?}", result.issues);
    for name in ["goods", "again"] {
        assert!(result
            .nodes
            .iter()
            .any(|n| n.label.as_ref() == name && has_physical_root(&result, &n.id, "goods")));
    }
}

#[test]
fn lateral_outputs_do_not_leak_into_sibling_selects() {
    let result = analyze_hive(
        "SELECT v FROM db.t LATERAL VIEW explode(a) p AS v UNION ALL SELECT v FROM db.other",
    );
    assert!(!result.summary.has_errors, "{:?}", result.issues);
    assert!(result
        .nodes
        .iter()
        .any(|n| n.qualified_name.as_deref() == Some("db.other.v")));
    assert!(!result
        .nodes
        .iter()
        .any(|n| n.qualified_name.as_deref() == Some("db.other.a")));
}

#[test]
fn qualified_repeated_outputs_preserve_window_roles() {
    let result = analyze_hive("SELECT first_value(p.va) OVER (PARTITION BY p.pos ORDER BY q.pos) AS picked FROM db.t LATERAL VIEW posexplode(a) p AS pos, va LATERAL VIEW posexplode(b) q AS pos, vb");
    assert!(!result.summary.has_errors, "{:?}", result.issues);
    let output = result
        .nodes
        .iter()
        .find(|n| n.label.as_ref() == "picked")
        .unwrap();
    assert!(has_physical_root(&result, &output.id, "a"));
    assert!(!has_physical_root(&result, &output.id, "b"));
    for (role, field) in [("partition", "a"), ("order", "b")] {
        assert!(result.edges.iter().any(|e| e.to == output.id
            && e.edge_type == EdgeType::WindowControl
            && e.metadata
                .as_ref()
                .and_then(|m| m.get("windowRole"))
                .and_then(|v| v.as_str())
                == Some(role)
            && result
                .nodes
                .iter()
                .any(|n| n.id == e.from && n.label.as_ref() == field)));
    }
}
