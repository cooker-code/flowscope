use flowscope_core::{analyze, AnalyzeRequest, AnalyzeResult, EdgeType};
use std::collections::BTreeSet;

fn run(sql: &str) -> AnalyzeResult {
    let request: AnalyzeRequest = serde_json::from_value(serde_json::json!({
        "dialect": "hive", "sql": sql, "sourceName":"alias-test"
    }))
    .unwrap();
    let result = analyze(&request);
    assert!(!result.summary.has_errors, "{:?}", result.issues);
    result
}

fn hints(result: &AnalyzeResult) -> Vec<&str> {
    result
        .issues
        .iter()
        .filter(|issue| issue.code == "HIVE_ALIAS_BACKTICKS")
        .map(|issue| issue.message.as_str())
        .collect()
}

#[test]
fn named_struct_inputs_match_explicit_backticks() {
    let sql = "SELECT COUNT(DISTINCT TO_JSON(STRUCT(net_gmv AS a, pay_gmv AS gross,
        season_user_from AS from, duration AS d, season_pay_dt AS dt, season_pay_tp AS tp)))
        AS versions FROM op_source";
    let bare = run(sql);
    let quoted = run(&sql
        .replace(" AS from,", " AS `from`,")
        .replace(" AS versions", " AS `versions`"));
    assert_eq!(hints(&bare).len(), 2);
    assert!(hints(&quoted).is_empty());
    let edges = |result: &AnalyzeResult| {
        result
            .edges
            .iter()
            .map(|e| e.id.to_string())
            .collect::<BTreeSet<_>>()
    };
    assert_eq!(edges(&bare), edges(&quoted));
    let sink = bare
        .nodes
        .iter()
        .find(|n| n.label.as_ref() == "versions")
        .unwrap();
    let sources: BTreeSet<_> = bare
        .edges
        .iter()
        .filter(|e| e.to == sink.id && e.edge_type == EdgeType::Derivation)
        .map(|e| {
            bare.nodes
                .iter()
                .find(|n| n.id == e.from)
                .unwrap()
                .label
                .as_ref()
        })
        .collect();
    assert_eq!(
        sources,
        BTreeSet::from([
            "net_gmv",
            "pay_gmv",
            "season_user_from",
            "duration",
            "season_pay_dt",
            "season_pay_tp"
        ])
    );
}

#[test]
fn chinese_and_keyword_aliases_across_scopes() {
    let bare = "WITH 汇总 AS (SELECT 来源.amount AS from FROM orders 来源)
        SELECT 明细.`from` 收入 FROM (SELECT * FROM 汇总) AS 明细";
    let result = run(bare);
    for alias in ["汇总", "来源", "from", "收入", "明细"] {
        assert_eq!(
            hints(&result)
                .iter()
                .filter(|m| m.contains(&format!("`{alias}`")))
                .count(),
            1
        );
    }
    let quoted = run(
        "WITH `汇总` AS (SELECT 来源.amount AS `from` FROM orders `来源`)
        SELECT 明细.`from` `收入` FROM (SELECT * FROM `汇总`) AS `明细`",
    );
    assert!(hints(&quoted).is_empty());
    assert_eq!(
        result.edges.iter().map(|e| &e.id).collect::<BTreeSet<_>>(),
        quoted.edges.iter().map(|e| &e.id).collect()
    );
}

#[test]
fn keyword_alias_and_orphan_as_can_coexist() {
    let result = run(
        "SELECT STRUCT(x AS from /* member */) AS normal_col, CAST(y AS STRING) AS
        FROM src WHERE y <> 'AS from' /* AS 中文 */",
    );
    assert_eq!(hints(&result).len(), 1);
    assert!(hints(&result)[0].contains("`from`"));
}

#[test]
fn implicit_keyword_aliases_require_a_clear_boundary() {
    let result = run("SELECT t.amount order FROM src t LEFT JOIN dim group WHERE t.amount > 0");
    assert_eq!(hints(&result).len(), 2);
    let quoted = run("SELECT t.amount `order` FROM src t LEFT JOIN dim `group` WHERE t.amount > 0");
    assert!(hints(&quoted).is_empty());
    assert_eq!(
        result.edges.iter().map(|e| &e.id).collect::<BTreeSet<_>>(),
        quoted.edges.iter().map(|e| &e.id).collect()
    );
    let result = run("SELECT amount FROM orders ORDER BY amount");
    assert!(hints(&result).is_empty());
}
