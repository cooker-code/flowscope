//! Original production inputs: audit IDs are fixture names, not Change task IDs.
//! No test-side SQL rewrites: both entry points exercise the shared Hive pipeline.

use flowscope_core::{
    analyze, AnalyzeRequest, AnalyzeResult, Dialect, EdgeType, FileSource, NodeType,
    SchemaMetadata, Severity,
};
use sqlparser::ast::{Expr, GroupByExpr, Query, SetExpr, Statement, TableFactor};
use std::collections::{BTreeSet, HashMap, HashSet};

#[derive(Default)]
struct SyntaxFacts {
    values: Vec<(String, usize, Vec<String>, usize)>,
    grouping_sets: Vec<Vec<usize>>,
}

impl SyntaxFacts {
    fn query(&mut self, query: &Query) {
        if let Some(with) = &query.with {
            for cte in &with.cte_tables {
                self.query(&cte.query);
            }
        }
        self.body(&query.body);
    }

    fn body(&mut self, body: &SetExpr) {
        match body {
            SetExpr::Select(select) => {
                if let GroupByExpr::Expressions(expressions, _) = &select.group_by {
                    let sets: Vec<_> = expressions
                        .iter()
                        .filter_map(|expr| match expr {
                            Expr::GroupingSets(sets) => Some(sets.len()),
                            _ => None,
                        })
                        .collect();
                    if !sets.is_empty() {
                        self.grouping_sets.push(sets);
                    }
                }
                for from in &select.from {
                    self.relation(&from.relation);
                    for join in &from.joins {
                        self.relation(&join.relation);
                    }
                }
            }
            SetExpr::Query(query) => self.query(query),
            SetExpr::SetOperation { left, right, .. } => {
                self.body(left);
                self.body(right);
            }
            _ => {}
        }
    }

    fn relation(&mut self, relation: &TableFactor) {
        if let TableFactor::Derived {
            subquery, alias, ..
        } = relation
        {
            if let SetExpr::Values(values) = subquery.body.as_ref() {
                let alias = alias
                    .as_ref()
                    .expect("original VALUES has explicit aliases");
                let columns: Vec<_> = alias
                    .columns
                    .iter()
                    .map(|col| col.name.value.clone())
                    .collect();
                assert!(
                    values.rows.iter().all(|row| row.len() == columns.len()),
                    "all VALUES rows must retain their declared width"
                );
                let typed_nulls = values.rows.iter().flatten().filter(|expr| {
                    matches!(expr, Expr::Cast { expr, .. } if expr.to_string() == "NULL")
                }).count();
                self.values.push((
                    alias.name.value.clone(),
                    values.rows.len(),
                    columns,
                    typed_nulls,
                ));
            }
            self.query(subquery);
        }
    }
}

fn syntax_facts(id: u32) -> SyntaxFacts {
    let input = request(id, false);
    let sql = flowscope_core::hive_preprocess::preprocess(&input.sql);
    let statements = flowscope_core::parse_sql_with_dialect(&sql, Dialect::Hive).unwrap();
    let mut facts = SyntaxFacts::default();
    for statement in statements {
        match statement {
            Statement::Query(query) => facts.query(&query),
            Statement::Insert(insert) => {
                if let Some(query) = insert.source {
                    facts.query(&query);
                }
            }
            _ => {}
        }
    }
    facts
}

const CASES: [(u32, &str); 7] = [
    (
        558128,
        include_str!("fixtures/hive_compat_original/558128.sql"),
    ),
    (
        557486,
        include_str!("fixtures/hive_compat_original/557486.sql"),
    ),
    (
        556525,
        include_str!("fixtures/hive_compat_original/556525.sql"),
    ),
    (
        557826,
        include_str!("fixtures/hive_compat_original/557826.sql"),
    ),
    (
        557557,
        include_str!("fixtures/hive_compat_original/557557.sql"),
    ),
    (
        557500,
        include_str!("fixtures/hive_compat_original/557500.sql"),
    ),
    (
        557728,
        include_str!("fixtures/hive_compat_original/557728.sql"),
    ),
];

fn request(id: u32, files_mode: bool) -> AnalyzeRequest {
    let sql = CASES.iter().find(|(case_id, _)| *case_id == id).unwrap().1;
    AnalyzeRequest {
        sql: if files_mode {
            String::new()
        } else {
            sql.to_string()
        },
        files: files_mode.then(|| {
            vec![FileSource {
                name: format!("{id}.sql"),
                content: sql.to_string(),
            }]
        }),
        dialect: Dialect::Hive,
        source_name: Some(format!("audit_{id}")),
        options: None,
        schema: None,
        #[cfg(feature = "templating")]
        template_config: None,
    }
}

#[rstest::rstest]
#[case(558128)]
#[case(557486)]
#[case(556525)]
#[case(557826)]
#[case(557557)]
#[case(557500)]
#[case(557728)]
fn original_sql_uses_shared_hive_entry_point(#[case] id: u32) {
    for files_mode in [false, true] {
        let result = analyze(&request(id, files_mode));
        let errors: Vec<_> = result
            .issues
            .iter()
            .filter(|issue| {
                issue.severity == Severity::Error
                // 557486 deliberately writes two different physical targets.
                && !(id == 557486 && issue.code == "MULTIPLE_TARGET_TABLES")
            })
            .collect();
        assert!(
            errors.is_empty(),
            "audit={id} files={files_mode}: {errors:?}"
        );
        assert!(
            !result.statements.is_empty(),
            "audit={id} must retain its statements"
        );
        assert!(
            !result.nodes.is_empty(),
            "audit={id} must retain its lineage"
        );
    }
}

#[test]
fn original_values_preserve_every_row_column_alias_and_typed_null() {
    let model = syntax_facts(558128);
    assert_eq!(model.values.len(), 1);
    let (alias, rows, columns, typed_nulls) = &model.values[0];
    assert_eq!(alias, "v");
    assert_eq!(*rows, 431);
    assert_eq!(
        columns,
        &[
            "model_version",
            "model_stage",
            "param_type",
            "feature_name",
            "feature_value",
            "mapped_value",
            "raw_coefficient",
            "effective_coefficient",
            "impute_value",
            "scale_value",
            "param_value",
            "param_text",
            "sort_order",
            "training_start_dt",
            "training_end_dt",
            "created_at",
        ]
    );
    assert_eq!(*typed_nulls, 884);

    let finance = syntax_facts(556525);
    assert_eq!(
        finance.values,
        vec![(
            "history".to_string(),
            17,
            [
                "category",
                "channel",
                "last_legacy_settled_month",
                "legacy_carry_start_month",
                "legacy_carry_end_month",
            ]
            .map(str::to_string)
            .to_vec(),
            10
        )]
    );

    let policy = syntax_facts(557486);
    let shapes: Vec<_> = policy
        .values
        .iter()
        .map(|(alias, rows, columns, nulls)| (alias.as_str(), *rows, columns.len(), *nulls))
        .collect();
    assert_eq!(
        shapes,
        vec![
            ("p", 173, 14, 0),
            ("h", 2, 4, 0),
            ("t", 17, 3, 0),
            ("p", 201, 4, 36),
            ("p", 173, 14, 0),
            ("t", 35, 6, 0),
        ]
    );
    assert_eq!(
        policy.values[3].2,
        ["source_row", "platform_name", "policy_keyfrom", "tax_rate"]
    );
}

#[test]
fn original_weekly_and_daily_grouping_sets_keep_their_cross_product() {
    let facts = syntax_facts(557728);
    assert_eq!(facts.grouping_sets, vec![vec![368, 2, 2], vec![368, 2, 2]]);
    for factors in facts.grouping_sets {
        assert_eq!(factors.iter().product::<usize>(), 1472);
    }
    // Explicit empty sets in each optional dimension create subtotal NULLs.
    let sql = flowscope_core::hive_preprocess::preprocess(&request(557728, false).sql);
    assert_eq!(sql.matches("GROUPING SETS ((), (subject_name))").count(), 2);
    assert_eq!(
        sql.matches("GROUPING SETS ((), (redeem_entry_type))")
            .count(),
        2
    );
    assert!(!sql.contains("GROUP BY 1"));
    assert_eq!(syntax_facts(556525).grouping_sets, vec![vec![2]]);
}

// DDLs point-read from hive_f04 on 2026-10-30. schema.json contains their
// declared columns followed by partition columns, independently extracted
// using SQLGlot's Spark DDL AST. No columns are inferred from workload SQL.
fn frozen_schema() -> SchemaMetadata {
    serde_json::from_str(include_str!("fixtures/hive_compat_original/schema.json")).unwrap()
}

fn with_schema(id: u32) -> AnalyzeResult {
    let mut input = request(id, false);
    input.schema = Some(frozen_schema());
    analyze(&input)
}

fn physical_value_roots(result: &AnalyzeResult, label: &str) -> BTreeSet<String> {
    let nodes: HashMap<_, _> = result
        .nodes
        .iter()
        .map(|node| (node.id.as_ref(), node))
        .collect();
    let sources: HashSet<_> = result
        .source_tables
        .iter()
        .map(|table| table.id.as_str())
        .collect();
    let mut pending: Vec<_> = result
        .nodes
        .iter()
        .filter(|node| node.node_type == NodeType::Column && node.label.as_ref() == label)
        .map(|node| node.id.as_ref())
        .collect();
    assert!(!pending.is_empty(), "missing output {label}");
    let mut seen = HashSet::new();
    let mut roots = BTreeSet::new();
    while let Some(id) = pending.pop() {
        if !seen.insert(id) {
            continue;
        }
        let node = nodes[id];
        let mut physical = false;
        for owner in result.edges.iter().filter(|edge| {
            edge.to.as_ref() == id
                && edge.edge_type == EdgeType::Ownership
                && sources.contains(edge.from.as_ref())
        }) {
            let table = nodes[owner.from.as_ref()];
            roots.insert(format!(
                "{}.{}",
                table.qualified_name.as_ref().unwrap(),
                node.label
            ));
            physical = true;
        }
        if !physical {
            pending.extend(
                result
                    .edges
                    .iter()
                    .filter(|edge| {
                        edge.to.as_ref() == id
                            && matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
                    })
                    .map(|edge| edge.from.as_ref()),
            );
        }
    }
    roots
}

#[rstest::rstest]
#[case(558128, "temp.tmk_bpo_new_stock_model_2_0_sql_param_da", 16)]
#[case(557486, "dw_conan_ads.tmp_biz1_cpa_order_settlement_policy", 42)]
#[case(
    557486,
    "dw_conan_ads.ads_biz1_cpa_order_settlement_cost_detail_da",
    21
)]
#[case(556525, "dw_conan_ads.ads_conan_service_try_order_cost_da", 50)]
#[case(
    557826,
    "dw_conan_ads.ads_eng_telesales_drop_stock_rescore_delta_di",
    44
)]
#[case(
    557557,
    "dw_conan_ads.ads_eng_telesales_new_stock_rescore_delta_di",
    45
)]
#[case(557500, "dw_conan_ads.ads_finance_sci_season_pushed_left_ma", 7)]
fn original_insert_positions_follow_frozen_target_ddl(
    #[case] id: u32,
    #[case] target: &str,
    #[case] width: usize,
) {
    let result = with_schema(id);
    let table = result
        .nodes
        .iter()
        .find(|node| {
            node.node_type == NodeType::Table && node.qualified_name.as_deref() == Some(target)
        })
        .expect("physical INSERT target");
    let mapping = &table.metadata.as_ref().expect("target metadata")["insertTargetMapping"];
    assert_eq!(mapping["status"], "resolved", "audit={id}: {mapping}");
    assert_eq!(mapping["outputCount"], width, "audit={id}");
    assert_eq!(mapping["columns"].as_array().unwrap().len(), width);
    assert!(
        !mapping["columns"]
            .as_array()
            .unwrap()
            .iter()
            .any(|column| column == "dt"),
        "static partition dt must not shift the output positions"
    );
    if matches!(id, 557826 | 557557) {
        assert_eq!(mapping["columns"][width - 1], "batch_no");
    }
    for (position, column) in mapping["columns"].as_array().unwrap().iter().enumerate() {
        assert!(
            result.nodes.iter().any(
                |node| node.metadata.as_ref().is_some_and(|metadata| metadata
                    .get("insertTarget")
                    .is_some_and(|destination| destination["table"] == target
                        && destination["column"] == *column
                        && destination["position"] == position + 1))
            ),
            "missing destination position {} for {target}",
            position + 1
        );
    }
    if id == 558128 {
        assert!(
            result.source_tables.is_empty(),
            "constant-only inline table has no physical sources"
        );
    }
}

#[rstest::rstest]
#[case(557826, "dw_conan_ads.ads_eng_telesales_drop_stock_score_state_da")]
#[case(557557, "dw_conan_ads.ads_eng_telesales_new_stock_score_state_da")]
fn original_expiry_flag_keeps_array_sources_and_excludes_lambda_locals(
    #[case] id: u32,
    #[case] table: &str,
) {
    let result = with_schema(id);
    assert_eq!(
        physical_value_roots(&result, "touch_expire_flag"),
        [
            format!("{table}.touch_dt_array_4m"),
            format!("{table}.connect_dt_array_4m")
        ]
        .into_iter()
        .collect()
    );
}

#[test]
fn original_sci_exists_keeps_collection_and_external_captures() {
    let result = with_schema(557500);
    let expected = [
        "order_list",
        "receipt_list",
        "cur_total_weekcount",
        "cur_left_weekcount",
        // last_total participates in temp_settled, then allocation/search_state.
        "cur_get_weekcount",
        "cur_refund_weekcount",
        "last_left_weekcount",
        "last_total_weekcount",
        "settled_weekcount",
        "settled_fee",
    ]
    .map(|column| format!("dw_conan_ads.ads_finance_sci_user_season_ma.{column}"))
    .into_iter()
    .collect();
    assert_eq!(physical_value_roots(&result, "dict_special"), expected);
}

#[rstest::rstest]
#[case(558128, vec![(431, 16)])]
#[case(557486, vec![(2, 4), (17, 3), (35, 6), (173, 28), (201, 4)])]
#[case(556525, vec![(17, 5)])]
fn original_values_provenance_survives_in_serialized_graph(
    #[case] id: u32,
    #[case] expected: Vec<(usize, usize)>,
) {
    let result = analyze(&request(id, false));
    let mut counts = std::collections::BTreeMap::new();
    let mut typed_nulls = 0;
    for node in &result.nodes {
        if let Some(values) = node
            .metadata
            .as_ref()
            .and_then(|metadata| metadata.get("columnValues"))
        {
            let values = values
                .as_array()
                .expect("columnValues is an ordered expression array");
            *counts.entry(values.len()).or_insert(0) += 1;
            typed_nulls += values
                .iter()
                .filter(|value| {
                    value
                        .as_str()
                        .is_some_and(|expression| expression.starts_with("CAST(NULL AS "))
                })
                .count();
        }
    }
    assert_eq!(counts.into_iter().collect::<Vec<_>>(), expected);
    assert_eq!(
        typed_nulls,
        match id {
            558128 => 884,
            557486 => 36,
            556525 => 10,
            _ => unreachable!(),
        }
    );
}

#[test]
fn original_grouping_keeps_dimension_and_measure_value_roots_separate() {
    let result = analyze(&request(557728, false));
    let mut branch_keys = BTreeSet::new();
    for group in result
        .nodes
        .iter()
        .filter_map(|node| node.metadata.as_ref())
        .filter_map(|metadata| metadata.get("groupBy"))
        .flat_map(|groups| groups.as_array().unwrap())
    {
        let expressions = group["expressions"].as_array().unwrap();
        if expressions.len() == 3 && expressions[0]["kind"] == "groupingSets" {
            assert_eq!(
                expressions
                    .iter()
                    .map(|expr| expr["sets"].as_array().unwrap().len())
                    .collect::<Vec<_>>(),
                vec![368, 2, 2]
            );
            assert_eq!(expressions[1]["sets"][0], serde_json::json!([]));
            assert_eq!(expressions[2]["sets"][0], serde_json::json!([]));
            branch_keys.insert(expressions[0]["sets"][0][0].as_str().unwrap().to_string());
        }
    }
    assert_eq!(
        branch_keys,
        ["week_dt".to_string(), "pay_dt".to_string()]
            .into_iter()
            .collect(),
        "weekly and daily UNION branches must both retain grouping metadata"
    );
    let table = "dw_conan_ads.ads_commerce_try_order_detail_wide_da_v1";
    for (label, columns) in [
        ("subject_name", vec!["subject_name"]),
        (
            "redeem_entry_type",
            vec![
                "redeem_funnel_node",
                "redeem_funnel_stage",
                "has_jingyu_auth_callback",
            ],
        ),
        ("redeem_success_order_num", vec!["is_valid_redeem_order"]),
    ] {
        assert_eq!(
            physical_value_roots(&result, label),
            columns
                .into_iter()
                .map(|column| format!("{table}.{column}"))
                .collect(),
            "{label}"
        );
    }
}
