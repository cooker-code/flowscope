use crate::{digest, Entity, Fact, StorageEvent, TableKey};
use flowscope_core::{CanonicalName, EdgeType, NodeType};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub artifact_id: String,
    pub sql_md5: String,
    pub entities: BTreeMap<String, Entity>,
    pub facts: BTreeMap<String, Fact>,
    pub reads: BTreeSet<TableKey>,
    pub target: Option<TableKey>,
    pub references: Vec<(String, String, Option<TableKey>)>,
    pub issues: Vec<String>,
}
fn table(c: &CanonicalName) -> Option<TableKey> {
    let schema = c.schema.as_ref().filter(|s| !s.is_empty())?;
    Some(TableKey {
        catalog: c.catalog.clone().unwrap_or_else(|| "hive".into()),
        db_name: schema.clone(),
        table_name: c.name.clone(),
    })
}
fn table_ref(r: &flowscope_core::TableRef) -> Option<TableKey> {
    r.canonical_name.as_ref().and_then(table)
}
fn props(value: Value) -> BTreeMap<String, Value> {
    value
        .as_object()
        .expect("object properties")
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}
fn physical_roots(
    id: &str,
    event: &StorageEvent,
    tables: &BTreeMap<String, TableKey>,
    target: &Option<TableKey>,
) -> BTreeSet<TableKey> {
    let mut pending = vec![id.to_string()];
    let mut seen = BTreeSet::new();
    let mut roots = BTreeSet::new();
    while let Some(id) = pending.pop() {
        if !seen.insert(id.clone()) {
            continue;
        }
        if let Some(t) = tables.get(&id) {
            if Some(t) != target.as_ref() {
                roots.insert(t.clone());
                continue;
            }
        }
        pending.extend(
            event
                .analysis
                .edges
                .iter()
                .filter(|e| {
                    e.to.as_ref() == id
                        && matches!(e.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
                })
                .map(|e| e.from.to_string()),
        );
    }
    roots
}
impl Snapshot {
    fn entity(&mut self, e: Entity) {
        self.entities.insert(e.key.clone(), e);
    }
    fn add_table(&mut self, t: &TableKey) {
        self.entity(Entity {
            key: t.key(),
            kind: "table".into(),
            table: Some(t.clone()),
            column: None,
            props: BTreeMap::new(),
        });
    }
    fn fact(&mut self, from: String, to: String, kind: &str, p: BTreeMap<String, Value>) {
        let key = digest(serde_json::to_vec(&(&from, &to, kind, &p)).expect("fact serializes"));
        self.facts.insert(
            key.clone(),
            Fact {
                key,
                from,
                to,
                kind: kind.into(),
                props: p,
            },
        );
    }
}

pub fn normalize(event: &StorageEvent) -> Snapshot {
    use md5::{Digest, Md5};
    let result = &event.analysis;
    let sql_md5 = format!("{:x}", Md5::digest(event.sql.as_bytes()));
    let artifact_id = digest(
        serde_json::to_vec(&(
            &event.environment,
            &event.parser_build,
            &event.dialect,
            &event.sql,
            event.stable_analysis(),
            &event.source,
        ))
        .expect("artifact serializes"),
    );
    let mut s = Snapshot {
        artifact_id: artifact_id.clone(),
        sql_md5,
        entities: BTreeMap::new(),
        facts: BTreeMap::new(),
        reads: BTreeSet::new(),
        target: result.target_table.as_ref().and_then(table_ref),
        references: vec![],
        issues: vec![],
    };
    let mut node_tables = BTreeMap::new();
    for n in &result.nodes {
        if n.node_type.is_table_or_view() {
            let t = n.canonical_name.as_ref().and_then(table);
            s.references.push((
                n.qualified_name.as_deref().unwrap_or(&n.label).to_string(),
                "read".into(),
                t.clone(),
            ));
            if let Some(t) = t {
                node_tables.insert(n.id.to_string(), t.clone());
                s.add_table(&t);
            } else {
                s.issues.push(format!("unqualified_table:{}", n.label));
            }
        }
    }
    for r in &result.source_tables {
        if let Some(t) = table_ref(r) {
            s.reads.insert(t.clone());
            s.add_table(&t);
        } else {
            s.issues.push("unqualified_source_table".into());
        }
    }
    if let Some(t) = s.target.clone() {
        s.add_table(&t);
        s.references
            .push((t.fqn(), "declared_write".into(), Some(t)));
    }
    // References used for personal footprints follow core's read/write classification.
    s.references.retain(|(_, role, t)| {
        role == "declared_write" || t.as_ref().is_none_or(|k| s.reads.contains(k))
    });
    let owners: BTreeMap<_, _> = result
        .edges
        .iter()
        .filter(|e| e.edge_type == EdgeType::Ownership)
        .map(|e| (e.to.to_string(), e.from.to_string()))
        .collect();
    let mut ownerships: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for edge in &result.edges {
        if edge.edge_type == EdgeType::Ownership {
            ownerships
                .entry(edge.to.as_ref())
                .or_default()
                .insert(edge.from.as_ref());
        }
        if edge.approximate == Some(true) {
            s.issues.push("approximate_lineage".into());
        }
    }
    if ownerships.values().any(|v| v.len() != 1) {
        s.issues.push("ambiguous_column_owner".into());
    }
    let nodes: BTreeMap<_, _> = result.nodes.iter().map(|n| (n.id.to_string(), n)).collect();
    let mut ids: BTreeMap<String, String> = node_tables
        .iter()
        .map(|(id, t)| (id.clone(), t.key()))
        .collect();
    let mut output_key = None;
    if result
        .nodes
        .iter()
        .filter(|n| n.node_type == NodeType::Output)
        .count()
        > 1
    {
        s.issues.push("multiple_logical_outputs".into());
    }
    if result.statements.iter().any(|s| {
        !["SELECT", "INSERT", "WITH"].contains(&s.statement_type.to_ascii_uppercase().as_str())
    }) {
        s.issues.push("unsupported_statement_kind".into());
    }
    for n in &result.nodes {
        if matches!(n.node_type, NodeType::Cte | NodeType::Output) {
            let kind = if n.node_type == NodeType::Cte {
                "cte"
            } else if event
                .source
                .as_ref()
                .is_some_and(|c| c.source_system == "mario")
            {
                "template"
            } else if event
                .source
                .as_ref()
                .is_some_and(|c| c.source_system == "change-export")
            {
                "sync"
            } else {
                "output"
            };
            let key = if matches!(kind, "template" | "sync") {
                if event
                    .source
                    .as_ref()
                    .and_then(|c| c.source_id.parse::<i64>().ok())
                    .is_none_or(|id| id <= 0)
                {
                    s.issues.push("invalid_scheduled_output_id".into());
                }
                if kind == "sync"
                    && event
                        .source
                        .as_ref()
                        .and_then(|c| c.external_target.as_ref())
                        .is_none()
                {
                    s.issues
                        .push("sync_requires_explicit_external_target".into());
                }
                format!(
                    "{kind}:{}",
                    event.source.as_ref().expect("source").scope_key()
                )
            } else {
                format!("{artifact_id}::{}", n.id)
            };
            if n.node_type == NodeType::Output {
                output_key = Some(key.clone());
            }
            ids.insert(n.id.to_string(), key.clone());
            s.entity(Entity{key,kind:kind.into(),table:None,column:None,props:props(json!({"label":n.label,"node_id":n.id,"payload_json":serde_json::to_string(n).expect("node"),"sql_md5":s.sql_md5}))});
        }
    }
    for n in &result.nodes {
        if n.node_type != NodeType::Column {
            continue;
        }
        let owner = owners.get(n.id.as_ref());
        let owner_table = owner.and_then(|id| node_tables.get(id));
        let is_sink = owner_table.is_some_and(|t| Some(t) == s.target.as_ref());
        let physical = owner_table.filter(|_| !is_sink);
        let key = if let Some(t) = physical {
            format!("physical:{}:{}", t.key(), n.label)
        } else {
            format!("{artifact_id}::{}", n.id)
        };
        if n.label.contains('*') {
            s.issues.push("unexpanded_star".into());
        }
        ids.insert(n.id.to_string(), key.clone());
        s.entity(Entity{key:key.clone(),kind:if physical.is_some(){"physical"}else{"derived"}.into(),table:physical.cloned(),column:Some(n.label.to_string()),props:props(json!({"label":n.label,"expression":n.expression,"payload_json":serde_json::to_string(n).expect("node"),"sql_md5":s.sql_md5,"col_name":n.label}))});
        if is_sink {
            let t = owner_table.expect("sink table");
            let mapped = n
                .metadata
                .as_ref()
                .and_then(|m| m.get("insertTarget"))
                .and_then(|m| m.get("column"))
                .and_then(Value::as_str);
            let target_column = mapped.unwrap_or(&n.label);
            if result.sql_type == flowscope_core::SqlType::Insert && mapped.is_none() {
                s.issues.push("unresolved_insert_target_mapping".into());
            }
            let physical_key = format!("physical:{}:{}", t.key(), target_column);
            s.entity(Entity {
                key: physical_key.clone(),
                kind: "physical".into(),
                table: Some(t.clone()),
                column: Some(target_column.to_string()),
                props: props(json!({"col_name":target_column})),
            });
            s.fact(
                key,
                physical_key.clone(),
                "DERIVES_COL",
                props(json!({"edge_type":"target_map"})),
            );
            s.fact(physical_key, t.key(), "REF_TABLE_COL", BTreeMap::new());
        }
    }
    // Only schema-backed columns become formal physical metadata. Preserve all
    // inferred information in the immutable analysis even when activation blocks.
    let schema_tables = result
        .resolved_schema
        .as_ref()
        .map(|s| s.tables.as_slice())
        .unwrap_or_default();
    for entity in s
        .entities
        .values_mut()
        .filter(|n| n.kind == "table" || n.kind == "physical")
    {
        let t = entity.table.as_ref().expect("physical table identity");
        let candidates: Vec<_> = schema_tables
            .iter()
            .filter(|m| {
                m.schema.as_deref() == Some(&t.db_name)
                    && m.name == t.table_name
                    && m.catalog.as_deref().unwrap_or("hive") == t.catalog
            })
            .collect();
        if candidates.len() != 1 {
            s.issues.push(format!("pending_metadata:{}", t.fqn()));
            continue;
        }
        let metadata = candidates[0];
        if metadata.origin == flowscope_core::SchemaOrigin::Implied
            && metadata.source_statement_index.is_none()
        {
            s.issues.push(format!("pending_metadata:{}", t.fqn()));
            continue;
        }
        if let Some(column) = &entity.column {
            if let Some(c) = metadata.columns.iter().find(|c| c.name == *column) {
                if let Some(dtype) = &c.data_type {
                    entity.props.insert("data_type".into(), json!(dtype));
                }
            } else {
                s.issues
                    .push(format!("unknown_physical_column:{}.{}", t.fqn(), column));
            }
        }
    }
    let sink = s.target.as_ref().map(TableKey::key).or(output_key);
    if let Some(sink) = sink {
        for t in s.reads.clone() {
            if t.key() != sink {
                let filters = serde_json::to_string(
                    &result
                        .nodes
                        .iter()
                        .filter(|n| node_tables.get(n.id.as_ref()) == Some(&t))
                        .flat_map(|n| &n.filters)
                        .collect::<Vec<_>>(),
                )
                .expect("filters");
                s.fact(t.key(),sink.clone(),"READS_FROM",props(json!({"filters_md5":format!("{:x}",Md5::digest(if filters=="[]" {b"".as_slice()}else{filters.as_bytes()})),"filters_json":filters})));
            }
        }
    } else if event.action == crate::Action::Publish {
        s.issues.push("unsupported_sink".into());
    }
    for e in &result.edges {
        let (Some(from), Some(to)) = (ids.get(e.from.as_ref()), ids.get(e.to.as_ref())) else {
            s.issues.push("missing_edge_endpoint".into());
            continue;
        };
        let from_node = nodes.get(e.from.as_ref());
        let to_node = nodes.get(e.to.as_ref());
        let mut p = props(
            json!({"edge_id":format!("{}::{}",artifact_id,e.id),"edge_type":serde_json::to_value(e.edge_type).expect("edge type"),"operation":e.operation,"expression":e.expression,"join_type":e.join_type,"join_condition":e.join_condition,"metadata_json":serde_json::to_string(&e.metadata).expect("metadata"),"statement_ids":e.statement_ids}),
        );
        if e.join_type.is_some() || e.edge_type == EdgeType::JoinDependency {
            let current_direction = node_tables.contains_key(e.from.as_ref())
                && (node_tables.get(e.to.as_ref()) == s.target.as_ref()
                    || to_node
                        .is_some_and(|n| matches!(n.node_type, NodeType::Output | NodeType::Cte)));
            let (left_id, right_id) = if current_direction {
                (e.to.as_ref(), e.from.as_ref())
            } else {
                (e.from.as_ref(), e.to.as_ref())
            };
            let right = physical_roots(right_id, event, &node_tables, &s.target);
            let mut left = physical_roots(left_id, event, &node_tables, &s.target);
            left.retain(|t| !right.contains(t));
            if left.len() == 1 && right.len() == 1 {
                s.fact(
                    left.first().expect("left root").key(),
                    right.first().expect("right root").key(),
                    "JOINS_WITH",
                    p.clone(),
                );
            } else {
                s.issues.push("ambiguous_join_scope".into());
            }
        }
        match e.edge_type {
            EdgeType::Ownership => {
                if to_node.is_some_and(|n| n.node_type == NodeType::Column)
                    && node_tables
                        .get(e.from.as_ref())
                        .is_none_or(|t| Some(t) != s.target.as_ref())
                {
                    s.fact(to.clone(), from.clone(), "REF_TABLE_COL", p);
                }
            }
            EdgeType::DataFlow | EdgeType::Derivation => {
                if from_node.is_some_and(|n| n.node_type == NodeType::Column)
                    && to_node.is_some_and(|n| n.node_type == NodeType::Column)
                {
                    s.fact(from.clone(), to.clone(), "DERIVES_COL", p);
                } else if to_node.is_some_and(|n| n.node_type == NodeType::Cte) {
                    s.fact(from.clone(), to.clone(), "REF_TEP", p);
                }
            }
            EdgeType::WindowControl => {
                if let Some(role) = e
                    .metadata
                    .as_ref()
                    .and_then(|m| m.get("windowRole"))
                    .and_then(Value::as_str)
                {
                    p.insert("dependency_kind".into(), json!(format!("window_{role}")));
                }
                s.fact(from.clone(), to.clone(), "CONTROLS_COL", p);
            }
            EdgeType::JoinDependency => {}
            EdgeType::CrossStatement => s.issues.push("unsupported_cross_statement".into()),
        }
    }
    s.issues.sort();
    s.issues.dedup();
    s
}
