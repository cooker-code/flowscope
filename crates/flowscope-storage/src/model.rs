use flowscope_core::AnalyzeResult;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    #[default]
    ParseOnly,
    Observe,
    RecordUsage,
    Publish,
}
impl Action {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ParseOnly => "parse_only",
            Self::Observe => "observe",
            Self::RecordUsage => "record_usage",
            Self::Publish => "publish",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceContext {
    pub source_system: String,
    pub source_id: String,
    pub source_version: String,
    #[serde(default)]
    pub analysis_revision: u32,
    pub environment: String,
    #[serde(default = "publish_kind")]
    pub event_kind: String,
    #[serde(default)]
    pub task_name: String,
    #[serde(default)]
    pub external_target: Option<TableKey>,
}
fn publish_kind() -> String {
    "publish".into()
}
impl SourceContext {
    pub fn scope_key(&self) -> String {
        format!(
            "{}:{}:{}",
            self.environment, self.source_system, self.source_id
        )
    }
    pub fn version(&self) -> Result<i64, crate::StorageError> {
        self.source_version
            .parse::<i64>()
            .ok()
            .filter(|v| *v >= 0)
            .ok_or_else(|| {
                crate::StorageError::Invalid(
                    "sourceVersion must be a nonnegative integer revision".into(),
                )
            })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableKey {
    pub catalog: String,
    pub db_name: String,
    pub table_name: String,
}
impl TableKey {
    pub fn fqn(&self) -> String {
        format!("{}.{}.{}", self.catalog, self.db_name, self.table_name)
    }
    pub fn key(&self) -> String {
        format!(
            "table:{}",
            crate::digest(serde_json::to_vec(self).expect("table identity serializes"))
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageEvent {
    pub event_id: String,
    pub request_id: String,
    pub principal_id: String,
    pub principal_type: String,
    pub token_id: String,
    pub policy_revision: i64,
    pub action: Action,
    pub environment: String,
    pub observed_at: String,
    pub sql: String,
    pub dialect: String,
    pub parser_build: String,
    pub source: Option<SourceContext>,
    pub analysis: AnalyzeResult,
}
impl StorageEvent {
    pub fn stable_analysis(&self) -> Value {
        let mut value = serde_json::to_value(&self.analysis).expect("analysis serializes");
        if let Some(tables) = value
            .pointer_mut("/resolvedSchema/tables")
            .and_then(Value::as_array_mut)
        {
            for table in tables {
                if let Some(table) = table.as_object_mut() {
                    table.remove("updatedAt");
                }
            }
        }
        value
    }
    pub fn content_hash(&self) -> String {
        // Policy revisions/observation times can change on recovery. The accepted
        // event identity covers the caller, operation and immutable request.
        crate::digest(
            serde_json::to_vec(&(
                &self.principal_id,
                self.action,
                &self.sql,
                &self.dialect,
                &self.source,
                self.stable_analysis(),
                &self.environment,
                &self.parser_build,
            ))
            .expect("event serializes"),
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyOutcome {
    pub lineage_status: String,
    pub usage_status: String,
    pub reason: Option<String>,
}
impl ApplyOutcome {
    pub fn recorded() -> Self {
        Self {
            lineage_status: "not_requested".into(),
            usage_status: "not_requested".into(),
            reason: None,
        }
    }
    pub fn blocked(reason: impl Into<String>) -> Self {
        Self {
            lineage_status: "blocked".into(),
            usage_status: "not_requested".into(),
            reason: Some(reason.into()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entity {
    pub key: String,
    pub kind: String,
    pub table: Option<TableKey>,
    pub column: Option<String>,
    pub props: BTreeMap<String, Value>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Fact {
    pub key: String,
    pub from: String,
    pub to: String,
    pub kind: String,
    pub props: BTreeMap<String, Value>,
}
