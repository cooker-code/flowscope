use flowscope_core::{analyze, AnalyzeRequest, AnalyzeResult, Dialect, FileSource};

fn request(sql: &str) -> AnalyzeRequest {
    AnalyzeRequest {
        sql: sql.to_owned(),
        files: None,
        dialect: Dialect::Hive,
        source_name: None,
        options: None,
        schema: None,
        #[cfg(feature = "templating")]
        template_config: None,
    }
}

fn fingerprint(sql: &str) -> String {
    analyze(&request(sql))
        .sql_fingerprint
        .expect("tokenizable SQL has a fingerprint")
}

#[test]
fn json_adds_versioned_fingerprint_and_reads_legacy_results() {
    let result = analyze(&request("SELECT user_id FROM users"));
    let mut json = serde_json::to_value(&result).unwrap();
    let value = json["sqlFingerprint"].as_str().unwrap();
    assert_eq!(value.len(), 64);
    assert!(value
        .bytes()
        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()));
    assert_eq!(json["sqlFingerprintVersion"], "flowscope-sql-v1");
    json.as_object_mut().unwrap().remove("sqlFingerprint");
    json.as_object_mut()
        .unwrap()
        .remove("sqlFingerprintVersion");
    let legacy: AnalyzeResult = serde_json::from_value(json).unwrap();
    assert!(legacy.sql_fingerprint.is_none());
    assert!(legacy.sql_fingerprint_version.is_none());
}

#[test]
fn formatting_comments_case_and_trailing_semicolons_do_not_change_identity() {
    assert_eq!(
        fingerprint("SELECT user_id, other['ip'] FROM logs WHERE kind = 'event'"),
        fingerprint("-- 普通说明\n select USER_ID , /* detail */ OTHER [ 'ip' ]\n from LOGS where KIND='event';;;")
    );
}

#[test]
fn ignores_only_known_resource_settings_at_statement_boundaries() {
    let base = "SELECT user_id FROM logs";
    assert_eq!(
        fingerprint(base),
        fingerprint(&format!("/* resource */ SET\n mapreduce.reduce.memory.mb=8192; SET spark.executor.cores=4; {base}; SET hive.exec.parallel=true;"))
    );
    // Semicolons and SET inside string literals cannot become directives.
    assert_ne!(
        fingerprint("SELECT 'set mapreduce.reduce.memory.mb=8192;' FROM logs"),
        fingerprint("SELECT '' FROM logs")
    );
    for setting in [
        "SET hive.local.time.zone='UTC'",
        "SET mapreduce.job.output.key.class='custom.Class'",
        "SET unknown.option='a'",
        "USE other_database",
        "ADD JAR 'business_udf.jar'",
    ] {
        assert_ne!(
            fingerprint(base),
            fingerprint(&format!("{setting}; {base}"))
        );
    }
}

#[test]
fn parameter_names_normalize_but_reference_relationships_survive() {
    assert_eq!(
        fingerprint("SELECT id FROM t WHERE dt='${date}' AND previous=date_sub('${date}',1)"),
        fingerprint(
            "SELECT id FROM t WHERE dt='{{bizdate}}' AND previous=date_sub('{{{bizdate}}}',1)"
        )
    );
    assert_ne!(
        fingerprint("SELECT id FROM t WHERE dt='${date}' AND other_dt='${date}'"),
        fingerprint("SELECT id FROM t WHERE dt='${start}' AND other_dt='${end}'")
    );
    assert_eq!(
        fingerprint("SELECT id FROM ${database}.${table} WHERE n=${number}"),
        fingerprint("SELECT id FROM {{db}}.{{tb}} WHERE n={{{count}}}")
    );
    assert_eq!(
        fingerprint("SELECT id FROM ${database}.${table} WHERE n=${number}"),
        fingerprint("SELECT id FROM ${ db }.${ tb } WHERE n=${ count }")
    );
}

#[test]
fn embedded_parameters_keep_fixed_string_fragments() {
    assert_eq!(
        fingerprint("SELECT id FROM t WHERE path LIKE '/${date}/%'"),
        fingerprint("SELECT id FROM t WHERE path LIKE '/{{bizdate}}/%'")
    );
    assert_ne!(
        fingerprint("SELECT id FROM t WHERE path LIKE '%${date}%'"),
        fingerprint("SELECT id FROM t WHERE path LIKE '${date}'")
    );
    // A literal matching our framing vocabulary cannot impersonate a parameter.
    assert_ne!(
        fingerprint("SELECT '${date}'"),
        fingerprint("SELECT 'parameter0'")
    );
}

#[test]
fn fixed_business_literals_map_keys_expressions_and_sources_remain_distinct() {
    let base = "SELECT other['ip'] AS ip FROM ods.request WHERE kind='event' AND n=1";
    for changed in [
        base.replace("['ip']", "['ua']"),
        base.replace("'event'", "'expose'"),
        base.replace("n=1", "n=2"),
        base.replace("ods.request", "ods.request_di"),
        base.replace("other['ip']", "lower(other['ip'])"),
    ] {
        assert_ne!(fingerprint(base), fingerprint(&changed), "{changed}");
    }
    assert_ne!(
        fingerprint("SELECT id FROM a UNION ALL SELECT id FROM b"),
        fingerprint("SELECT id FROM a UNION SELECT id FROM b")
    );
}

#[test]
fn does_not_guess_parameters_from_rendered_literal_values() {
    assert_ne!(
        fingerprint("SELECT id FROM t WHERE dt='2026-10-29'"),
        fingerprint("SELECT id FROM t WHERE dt='2026-10-30'")
    );
}

#[test]
fn preserves_template_expressions_and_macro_arguments() {
    assert_ne!(
        fingerprint("SELECT {{ x + 1 }}"),
        fingerprint("SELECT {{ x + 2 }}")
    );
    assert_ne!(
        fingerprint("SELECT id FROM {{ ref('orders') }}"),
        fingerprint("SELECT id FROM {{ ref('refunds') }}")
    );
}

#[test]
fn hints_and_literal_text_are_not_discarded_as_ordinary_comments() {
    assert_ne!(
        fingerprint("SELECT /*+ MAPJOIN(t) */ id FROM t"),
        fingerprint("SELECT id FROM t")
    );
    assert_ne!(fingerprint("SELECT '-- x'"), fingerprint("SELECT '-- y'"));
    assert_ne!(
        fingerprint("SELECT 'a; b'"),
        fingerprint("SELECT 'a'; SELECT 'b'")
    );
    assert_ne!(fingerprint(r"SELECT '\\n'"), fingerprint(r"SELECT '\n'"));
}

#[test]
fn hive_string_quote_styles_normalize_but_identifier_case_and_quoting_are_conservative() {
    assert_eq!(
        fingerprint("SELECT 'hello'"),
        fingerprint("SELECT \"hello\"")
    );
    let mut upper = request("SELECT \"Name\" FROM users");
    upper.dialect = Dialect::Postgres;
    let mut lower = upper.clone();
    lower.sql = "SELECT \"name\" FROM users".to_owned();
    assert_ne!(
        analyze(&upper).sql_fingerprint,
        analyze(&lower).sql_fingerprint
    );
    lower.sql = "SELECT Name FROM users".to_owned();
    assert_ne!(
        analyze(&upper).sql_fingerprint,
        analyze(&lower).sql_fingerprint
    );
}

#[test]
fn all_files_and_inline_sql_participate_in_analysis_order() {
    let mut multi = request("SELECT id FROM third");
    multi.files = Some(vec![
        FileSource {
            name: "a.sql".into(),
            content: "SELECT id FROM first".into(),
        },
        FileSource {
            name: "b.sql".into(),
            content: "SELECT id FROM second".into(),
        },
    ]);
    let original = analyze(&multi).sql_fingerprint.unwrap();
    let mut renamed = multi.clone();
    renamed.files.as_mut().unwrap()[0].name = "renamed.sql".into();
    assert_eq!(Some(original.clone()), analyze(&renamed).sql_fingerprint);
    for index in 0..2 {
        let mut changed = multi.clone();
        changed.files.as_mut().unwrap()[index].content = "SELECT id FROM changed".into();
        assert_ne!(Some(original.clone()), analyze(&changed).sql_fingerprint);
    }
    multi.sql = "SELECT id FROM changed_inline".into();
    assert_ne!(Some(original), analyze(&multi).sql_fingerprint);
}

#[test]
fn single_file_and_inline_template_match_without_source_name_in_identity() {
    let sql = "SELECT id FROM t WHERE dt='${date}'";
    let mut file = request("");
    file.files = Some(vec![FileSource {
        name: "22679.hql".into(),
        content: sql.into(),
    }]);
    assert_eq!(Some(fingerprint(sql)), analyze(&file).sql_fingerprint);
}

#[test]
fn shared_parameter_relationships_are_preserved_across_files() {
    let mut input = request("SELECT '${date}'");
    input.files = Some(vec![FileSource {
        name: "first.sql".into(),
        content: "SELECT '${date}'".into(),
    }]);
    let shared = analyze(&input).sql_fingerprint;
    input.sql = "SELECT '${other_date}'".into();
    assert_ne!(shared, analyze(&input).sql_fingerprint);
}

#[cfg(feature = "templating")]
#[test]
fn runtime_template_values_are_not_part_of_template_identity() {
    use flowscope_core::{TemplateConfig, TemplateMode};
    let mut input = request("SELECT id FROM t WHERE dt='{{date}}'");
    input.dialect = Dialect::Generic;
    input.template_config = Some(TemplateConfig {
        mode: TemplateMode::Jinja,
        context: [("date".into(), serde_json::json!("2026-10-29"))]
            .into_iter()
            .collect(),
    });
    let first = analyze(&input);
    assert!(!first.summary.has_errors);
    input
        .template_config
        .as_mut()
        .unwrap()
        .context
        .insert("date".into(), serde_json::json!("2026-10-30"));
    let second = analyze(&input);
    assert!(!second.summary.has_errors);
    assert_eq!(first.sql_fingerprint, second.sql_fingerprint);
}

#[test]
fn empty_and_untokenizable_inputs_have_no_misleading_fallback_digest() {
    for sql in [
        "",
        "-- comment only",
        ";;;",
        "SET mapreduce.reduce.memory.mb=4096;",
        "SELECT 'unterminated",
    ] {
        let result = analyze(&request(sql));
        assert!(result.sql_fingerprint.is_none(), "{sql}");
        assert!(result.sql_fingerprint_version.is_none(), "{sql}");
    }
    let mut files = request("SELECT 1");
    files.files = Some(vec![FileSource {
        name: "bad.sql".into(),
        content: "SELECT 'unterminated".into(),
    }]);
    assert!(analyze(&files).sql_fingerprint.is_none());
}

#[test]
fn dialect_is_part_of_the_fingerprint_contract() {
    let hive = request("SELECT id FROM t");
    let mut postgres = hive.clone();
    postgres.dialect = Dialect::Postgres;
    assert_ne!(
        analyze(&hive).sql_fingerprint,
        analyze(&postgres).sql_fingerprint
    );
}

#[test]
fn missing_resource_semicolon_cannot_hide_following_sql() {
    assert_ne!(
        fingerprint("SET hive.exec.parallel=true\nSELECT id FROM first_table"),
        fingerprint("SET hive.exec.parallel=true\nSELECT id FROM second_table")
    );
}

#[test]
fn task_22679_preserves_logic_changes_without_resource_or_parameter_churn() {
    let sql = include_str!("fixtures/sql_fingerprint/22679.hql");
    let original = analyze(&request(sql));
    assert!(!original.summary.has_errors);
    let hash = original.sql_fingerprint.unwrap();
    // Pin v1 output so normalization drift requires an explicit contract review.
    assert_eq!(
        hash,
        "ac38dc0f184fc56d38a47e770ef48b4c3b6dda5f25bf7e300648040fb322fd27"
    );
    for same in [
        format!("-- 新增普通说明\n{sql}"),
        sql.replace("memory.mb=4096", "memory.mb=8192"),
        sql.replace("${date}", "${bizdate}"),
    ] {
        assert_eq!(hash, fingerprint(&same));
    }
    for different in [
        sql.replace("ods_pedia_request_di\n", "ods_pedia_request\n"),
        sql.replace("other['ip']", "other['ua']"),
        sql.replace("'event'", "'other'"),
    ] {
        assert_ne!(hash, fingerprint(&different));
    }
}
