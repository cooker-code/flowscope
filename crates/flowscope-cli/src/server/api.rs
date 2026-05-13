//! REST API handlers for serve mode.
//!
//! This module provides the API endpoints for the web UI to interact with
//! the FlowScope analysis engine.

use std::net::SocketAddr;
use std::{collections::BTreeMap, sync::Arc};

use axum::{
    extract::{ConnectInfo, Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use chrono::SecondsFormat;
use serde::{Deserialize, Serialize};

use super::audit::{
    extract_audit_flags, sha256_hex, truncate_result_json, AuditEntry,
};
use super::AppState;

/// Build the API router with all endpoints.
pub fn api_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/health", get(health))
        .route("/analyze", post(analyze))
        .route("/completion", post(completion))
        .route("/split", post(split))
        .route("/lint-fix", post(lint_fix))
        .route("/files", get(files))
        .route("/schema", get(schema))
        .route("/export/{format}", post(export))
        .route("/config", get(config))
        .route("/audit", get(audit_records))
        .route("/audit/files", get(audit_files))
        .route("/audit/{id}", get(audit_record_detail))
}

// === Request/Response types ===

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
    version: &'static str,
}

#[derive(Deserialize)]
struct AnalyzeRequest {
    sql: String,
    #[serde(default)]
    files: Option<Vec<flowscope_core::FileSource>>,
    #[serde(default)]
    hide_ctes: Option<bool>,
    #[serde(default)]
    enable_column_lineage: Option<bool>,
    #[serde(default)]
    template_mode: Option<String>,
}

#[derive(Deserialize)]
struct CompletionRequest {
    sql: String,
    #[serde(alias = "position")]
    cursor_offset: usize,
}

#[derive(Deserialize)]
struct SplitRequest {
    sql: String,
}

#[derive(Serialize)]
struct ConfigResponse {
    dialect: String,
    watch_dirs: Vec<String>,
    has_schema: bool,
    #[cfg(feature = "templating")]
    template_mode: Option<String>,
}

#[derive(Deserialize)]
struct ExportRequest {
    sql: String,
    #[serde(default)]
    files: Option<Vec<flowscope_core::FileSource>>,
}

#[derive(Deserialize)]
struct LintFixRequest {
    sql: String,
    #[serde(default, alias = "include_unsafe_fixes")]
    unsafe_fixes: bool,
    #[serde(default, alias = "legacyAstFixes")]
    legacy_ast_fixes: bool,
    #[serde(default, alias = "exclude_rules")]
    disabled_rules: Vec<String>,
    #[serde(default)]
    rule_configs: BTreeMap<String, serde_json::Value>,
}

#[derive(Serialize)]
struct LintFixResponse {
    sql: String,
    changed: bool,
    fix_counts: LintFixCountsResponse,
    skipped_due_to_comments: bool,
    skipped_due_to_regression: bool,
    skipped_counts: LintFixSkippedCountsResponse,
}

#[derive(Serialize)]
struct LintFixCountsResponse {
    total: usize,
}

#[derive(Serialize)]
struct LintFixSkippedCountsResponse {
    unsafe_skipped: usize,
    protected_range_blocked: usize,
    overlap_conflict_blocked: usize,
    display_only: usize,
    blocked_total: usize,
}

#[derive(Deserialize)]
struct AuditQueryParams {
    #[serde(default = "default_audit_limit")]
    limit: i64,
    #[serde(default)]
    offset: i64,
    from: Option<String>,
    to: Option<String>,
    endpoint: Option<String>,
}

fn default_audit_limit() -> i64 {
    50
}

#[derive(Serialize)]
struct AuditQueryResponse {
    total: i64,
    records: Vec<serde_json::Value>,
}

// === Handlers ===

/// GET /api/health - Health check with version
async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}

/// POST /api/analyze - Run lineage analysis
async fn analyze(
    State(state): State<Arc<AppState>>,
    ConnectInfo(client_addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<AnalyzeRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let start = std::time::Instant::now();
    let schema = state.schema.read().await.clone();

    // Build analysis options from request
    let options = if payload.hide_ctes.is_some() || payload.enable_column_lineage.is_some() {
        Some(flowscope_core::AnalysisOptions {
            hide_ctes: payload.hide_ctes,
            enable_column_lineage: payload.enable_column_lineage,
            ..Default::default()
        })
    } else {
        None
    };

    // Build template config if template mode is specified
    #[cfg(feature = "templating")]
    let template_config = resolve_template_config(payload.template_mode.as_deref(), state.as_ref());

    let request = flowscope_core::AnalyzeRequest {
        sql: payload.sql.clone(),
        files: payload.files.clone(),
        dialect: state.config.dialect,
        source_name: None,
        options,
        schema,
        #[cfg(feature = "templating")]
        template_config,
    };

    let result = flowscope_core::analyze(&request);
    let duration_ms = start.elapsed().as_millis() as u64;

    // Record audit entries if audit logging is enabled
    if let Some(ref audit) = state.audit {
        let ts = chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        let client_ip = client_addr.ip().to_string();
        let dialect = format!("{:?}", state.config.dialect);
        // Combine SQL text for flag detection (files mode joins all file content)
        let combined_sql: String = if let Some(ref files) = payload.files {
            files.iter().map(|f| f.content.as_str()).collect::<Vec<_>>().join("\n")
        } else {
            payload.sql.clone()
        };
        let (has_cte, has_union, stmt_count, table_count, sql_type) =
            extract_audit_flags(&result, &combined_sql);
        let (result_json, result_truncated) = truncate_result_json(&result);
        let success = !result.summary.has_errors;

        if let Some(ref files) = payload.files {
            // files[] mode: one audit record per file
            for file in files {
                let sql_hash = sha256_hex(&file.content);
                let sql_len = file.content.len();
                audit.record(AuditEntry {
                    ts: ts.clone(),
                    client_ip: client_ip.clone(),
                    endpoint: "/api/analyze".to_string(),
                    dialect: dialect.clone(),
                    file_name: Some(file.name.clone()),
                    sql_text: file.content.clone(),
                    sql_hash,
                    sql_len,
                    has_cte,
                    has_union,
                    success,
                    duration_ms,
                    stmt_count: Some(stmt_count),
                    table_count: Some(table_count),
                    sql_type: sql_type.clone(),
                    result_json: result_json.clone(),
                    result_truncated,
                    error_msg: None,
                });
            }
        } else {
            // Inline SQL mode
            let sql_hash = sha256_hex(&payload.sql);
            let sql_len = payload.sql.len();
            audit.record(AuditEntry {
                ts,
                client_ip,
                endpoint: "/api/analyze".to_string(),
                dialect,
                file_name: None,
                sql_text: payload.sql.clone(),
                sql_hash,
                sql_len,
                has_cte,
                has_union,
                success,
                duration_ms,
                stmt_count: Some(stmt_count),
                table_count: Some(table_count),
                sql_type,
                result_json,
                result_truncated,
                error_msg: None,
            });
        }
    }

    Ok(Json(result))
}

/// POST /api/completion - Get code completion items
async fn completion(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CompletionRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let schema = state.schema.read().await.clone();

    let request = flowscope_core::CompletionRequest {
        sql: payload.sql,
        cursor_offset: payload.cursor_offset,
        dialect: state.config.dialect,
        schema,
    };

    let result = flowscope_core::completion_items(&request);
    Ok(Json(result))
}

/// POST /api/split - Split SQL into statements
async fn split(
    State(state): State<Arc<AppState>>,
    ConnectInfo(client_addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<SplitRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let start = std::time::Instant::now();

    let request = flowscope_core::StatementSplitRequest {
        sql: payload.sql.clone(),
        dialect: state.config.dialect,
    };

    let result = flowscope_core::split_statements(&request);
    let duration_ms = start.elapsed().as_millis() as u64;

    if let Some(ref audit) = state.audit {
        let sql_hash = sha256_hex(&payload.sql);
        let sql_len = payload.sql.len();
        let stmt_count = result.statements.len();
        let success = result.error.is_none();
        let error_msg = result.error.clone();
        audit.record(AuditEntry {
            ts: chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            client_ip: client_addr.ip().to_string(),
            endpoint: "/api/split".to_string(),
            dialect: format!("{:?}", state.config.dialect),
            file_name: None,
            sql_text: payload.sql,
            sql_hash,
            sql_len,
            has_cte: false,
            has_union: false,
            success,
            duration_ms,
            stmt_count: Some(stmt_count),
            table_count: None,
            sql_type: None,
            result_json: None,
            result_truncated: false,
            error_msg,
        });
    }

    Ok(Json(result))
}

/// POST /api/lint-fix - Apply deterministic lint fixes to SQL text.
async fn lint_fix(
    State(state): State<Arc<AppState>>,
    ConnectInfo(client_addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<LintFixRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let start = std::time::Instant::now();

    let rule_configs = normalize_rule_configs(payload.rule_configs)
        .map_err(|err| (StatusCode::BAD_REQUEST, err))?;

    let lint_config = flowscope_core::LintConfig {
        enabled: true,
        disabled_rules: payload.disabled_rules,
        rule_configs,
    };

    let exec_result = crate::fix::apply_lint_fixes_with_runtime_options(
        &payload.sql,
        state.config.dialect,
        &lint_config,
        crate::fix::LintFixRuntimeOptions {
            include_unsafe_fixes: payload.unsafe_fixes,
            legacy_ast_fixes: payload.legacy_ast_fixes,
        },
    );

    let duration_ms = start.elapsed().as_millis() as u64;

    // Record audit entry before potentially returning an error
    if let Some(ref audit) = state.audit {
        let sql_hash = sha256_hex(&payload.sql);
        let sql_len = payload.sql.len();
        let (success, error_msg) = match &exec_result {
            Ok(_) => (true, None),
            Err(e) => (false, Some(e.to_string())),
        };
        audit.record(AuditEntry {
            ts: chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            client_ip: client_addr.ip().to_string(),
            endpoint: "/api/lint-fix".to_string(),
            dialect: format!("{:?}", state.config.dialect),
            file_name: None,
            sql_text: payload.sql.clone(),
            sql_hash,
            sql_len,
            has_cte: false,
            has_union: false,
            success,
            duration_ms,
            stmt_count: None,
            table_count: None,
            sql_type: None,
            result_json: None,
            result_truncated: false,
            error_msg,
        });
    }

    let execution = exec_result.map_err(|err| {
        eprintln!("flowscope: lint-fix failed: {err}");
        (
            StatusCode::BAD_REQUEST,
            "Failed to apply lint fixes".to_string(),
        )
    })?;
    let outcome = execution.outcome;
    let candidate_stats = execution.candidate_stats;

    let skipped_counts = LintFixSkippedCountsResponse {
        unsafe_skipped: candidate_stats.blocked_unsafe,
        protected_range_blocked: candidate_stats.blocked_protected_range,
        overlap_conflict_blocked: candidate_stats.blocked_overlap_conflict,
        display_only: candidate_stats.blocked_display_only,
        blocked_total: candidate_stats.blocked,
    };

    Ok(Json(LintFixResponse {
        sql: outcome.sql,
        changed: outcome.changed,
        fix_counts: LintFixCountsResponse {
            total: outcome.counts.total(),
        },
        skipped_due_to_comments: outcome.skipped_due_to_comments,
        skipped_due_to_regression: outcome.skipped_due_to_regression,
        skipped_counts,
    }))
}

/// GET /api/files - List watched files with content
async fn files(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let files = state.files.read().await;
    Json(files.clone())
}

/// GET /api/schema - Get schema metadata
async fn schema(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let schema = state.schema.read().await;
    Json(schema.clone())
}

/// POST /api/export/:format - Export to specified format
async fn export(
    State(state): State<Arc<AppState>>,
    ConnectInfo(client_addr): ConnectInfo<SocketAddr>,
    Path(format): Path<String>,
    Json(payload): Json<ExportRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let start = std::time::Instant::now();
    let schema = state.schema.read().await.clone();

    let request = flowscope_core::AnalyzeRequest {
        sql: payload.sql.clone(),
        files: payload.files.clone(),
        dialect: state.config.dialect,
        source_name: None,
        options: None,
        schema,
        #[cfg(feature = "templating")]
        template_config: state.config.template_config.clone(),
    };

    let result = flowscope_core::analyze(&request);
    let duration_ms = start.elapsed().as_millis() as u64;

    // Record audit entry for export
    if let Some(ref audit) = state.audit {
        let ts = chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        let client_ip = client_addr.ip().to_string();
        let dialect = format!("{:?}", state.config.dialect);
        let export_combined_sql: String = if let Some(ref files) = payload.files {
            files.iter().map(|f| f.content.as_str()).collect::<Vec<_>>().join("\n")
        } else {
            payload.sql.clone()
        };
        let (has_cte, has_union, stmt_count, table_count, sql_type) =
            extract_audit_flags(&result, &export_combined_sql);
        let success = !result.summary.has_errors;
        let endpoint = format!("/api/export/{format}");

        if let Some(ref files) = payload.files {
            for file in files {
                let sql_hash = sha256_hex(&file.content);
                let sql_len = file.content.len();
                audit.record(AuditEntry {
                    ts: ts.clone(),
                    client_ip: client_ip.clone(),
                    endpoint: endpoint.clone(),
                    dialect: dialect.clone(),
                    file_name: Some(file.name.clone()),
                    sql_text: file.content.clone(),
                    sql_hash,
                    sql_len,
                    has_cte,
                    has_union,
                    success,
                    duration_ms,
                    stmt_count: Some(stmt_count),
                    table_count: Some(table_count),
                    sql_type: sql_type.clone(),
                    result_json: None,
                    result_truncated: false,
                    error_msg: None,
                });
            }
        } else {
            let sql_hash = sha256_hex(&payload.sql);
            let sql_len = payload.sql.len();
            audit.record(AuditEntry {
                ts,
                client_ip,
                endpoint,
                dialect,
                file_name: None,
                sql_text: payload.sql.clone(),
                sql_hash,
                sql_len,
                has_cte,
                has_union,
                success,
                duration_ms,
                stmt_count: Some(stmt_count),
                table_count: Some(table_count),
                sql_type,
                result_json: None,
                result_truncated: false,
                error_msg: None,
            });
        }
    }

    match format.as_str() {
        "json" => {
            let output = flowscope_export::export_json(&result, false)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            Ok((
                [(axum::http::header::CONTENT_TYPE, "application/json")],
                output,
            )
                .into_response())
        }
        "mermaid" => {
            let output =
                flowscope_export::export_mermaid(&result, flowscope_export::MermaidView::Table)
                    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            Ok(([(axum::http::header::CONTENT_TYPE, "text/plain")], output).into_response())
        }
        "html" => {
            let output = flowscope_export::export_html(&result, "lineage", chrono::Utc::now())
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            Ok(([(axum::http::header::CONTENT_TYPE, "text/html")], output).into_response())
        }
        "csv" => {
            let bytes = flowscope_export::export_csv_bundle(&result)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            Ok((
                [(axum::http::header::CONTENT_TYPE, "application/zip")],
                bytes,
            )
                .into_response())
        }
        "xlsx" => {
            let bytes = flowscope_export::export_xlsx(&result)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            Ok((
                [(
                    axum::http::header::CONTENT_TYPE,
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                )],
                bytes,
            )
                .into_response())
        }
        _ => Err((
            StatusCode::BAD_REQUEST,
            format!("Unknown export format: {format}"),
        )),
    }
}

/// GET /api/config - Get server configuration
async fn config(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let has_schema = state.schema.read().await.is_some();

    Json(ConfigResponse {
        dialect: format!("{:?}", state.config.dialect),
        watch_dirs: state
            .config
            .watch_dirs
            .iter()
            .map(|p| p.display().to_string())
            .collect(),
        has_schema,
        #[cfg(feature = "templating")]
        template_mode: state
            .config
            .template_config
            .as_ref()
            .map(|cfg| template_mode_to_str(cfg.mode).to_string()),
    })
}

/// GET /api/audit - Query audit log records with optional filtering
async fn audit_records(
    State(state): State<Arc<AppState>>,
    Query(params): Query<AuditQueryParams>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let Some(ref _audit) = state.audit else {
        // Audit not enabled: return empty result
        return Ok(Json(AuditQueryResponse {
            total: 0,
            records: vec![],
        }));
    };

    let audit_path = match state.config.audit_log_path {
        Some(ref p) => p.clone(),
        None => {
            return Ok(Json(AuditQueryResponse {
                total: 0,
                records: vec![],
            }))
        }
    };

    let limit = params.limit.clamp(1, 500);
    let offset = params.offset.max(0);
    let from = params.from.clone();
    let to = params.to.clone();
    let endpoint_filter = params.endpoint.clone();

    let result = tokio::task::spawn_blocking(move || {
        super::audit::AuditWriter::query(
            &audit_path,
            limit,
            offset,
            from.as_deref(),
            to.as_deref(),
            endpoint_filter.as_deref(),
        )
    })
    .await
    .map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Audit query task error: {e}"),
        )
    })?
    .map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Audit query failed: {e}"),
        )
    })?;

    Ok(Json(AuditQueryResponse {
        total: result.0,
        records: result.1,
    }))
}

/// GET /api/audit/files - List distinct files from the audit log (latest record per file)
async fn audit_files(
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let Some(ref _audit) = state.audit else {
        // Audit not enabled: return empty array
        return Ok(Json(Vec::<serde_json::Value>::new()));
    };

    let audit_path = match state.config.audit_log_path {
        Some(ref p) => p.clone(),
        None => return Ok(Json(Vec::<serde_json::Value>::new())),
    };

    let records = tokio::task::spawn_blocking(move || {
        super::audit::AuditWriter::query_files(&audit_path)
    })
    .await
    .map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Audit files task error: {e}"),
        )
    })?
    .map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Audit files query failed: {e}"),
        )
    })?;

    Ok(Json(records))
}

/// GET /api/audit/:id - Fetch a single audit record with sql_text and result_json
async fn audit_record_detail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let audit_path = match state.config.audit_log_path {
        Some(ref p) => p.clone(),
        None => {
            return Err((StatusCode::NOT_FOUND, "Audit logging is not enabled".to_string()));
        }
    };

    let result = tokio::task::spawn_blocking(move || {
        super::audit::AuditWriter::query_one(&audit_path, id)
    })
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Task error: {e}")))?
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Query failed: {e}")))?;

    match result {
        Some(record) => Ok(Json(record).into_response()),
        None => Err((StatusCode::NOT_FOUND, format!("Audit record {id} not found"))),
    }
}

fn normalize_rule_configs(
    raw_configs: BTreeMap<String, serde_json::Value>,
) -> Result<BTreeMap<String, serde_json::Value>, String> {
    let mut rule_configs = BTreeMap::new();
    let mut indentation_legacy = serde_json::Map::new();

    for (rule_ref, options) in raw_configs {
        if options.is_object() {
            rule_configs.insert(rule_ref, options);
            continue;
        }

        // SQLFluff compatibility: support legacy indentation keys at root.
        if matches!(
            rule_ref.to_ascii_lowercase().as_str(),
            "indent_unit" | "tab_space_size" | "indented_joins" | "indented_using_on"
        ) {
            indentation_legacy.insert(rule_ref, options);
            continue;
        }

        return Err(format!(
            "'rule_configs' entry for '{rule_ref}' must be a JSON object"
        ));
    }

    if !indentation_legacy.is_empty() {
        let merged = match rule_configs.remove("indentation") {
            Some(serde_json::Value::Object(existing)) => {
                let mut merged = existing;
                for (key, value) in indentation_legacy {
                    merged.insert(key, value);
                }
                merged
            }
            Some(other) => {
                return Err(format!(
                    "'rule_configs' entry for 'indentation' must be a JSON object, found {other}"
                ));
            }
            None => indentation_legacy,
        };

        rule_configs.insert("indentation".to_string(), serde_json::Value::Object(merged));
    }

    Ok(rule_configs)
}

#[cfg(feature = "templating")]
fn resolve_template_config(
    mode: Option<&str>,
    state: &AppState,
) -> Option<flowscope_core::TemplateConfig> {
    match mode {
        Some("raw") => None,
        Some("jinja") => Some(build_template_config(
            flowscope_core::TemplateMode::Jinja,
            state,
        )),
        Some("dbt") => Some(build_template_config(
            flowscope_core::TemplateMode::Dbt,
            state,
        )),
        Some(_) => state.config.template_config.clone(),
        None => state.config.template_config.clone(),
    }
}

#[cfg(feature = "templating")]
fn build_template_config(
    template_mode: flowscope_core::TemplateMode,
    state: &AppState,
) -> flowscope_core::TemplateConfig {
    let context = state
        .config
        .template_config
        .as_ref()
        .map(|cfg| cfg.context.clone())
        .unwrap_or_default();

    flowscope_core::TemplateConfig {
        mode: template_mode,
        context,
    }
}

#[cfg(feature = "templating")]
fn template_mode_to_str(mode: flowscope_core::TemplateMode) -> &'static str {
    match mode {
        flowscope_core::TemplateMode::Raw => "raw",
        flowscope_core::TemplateMode::Jinja => "jinja",
        flowscope_core::TemplateMode::Dbt => "dbt",
    }
}
