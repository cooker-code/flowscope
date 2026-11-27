use crate::changes::{BusinessObject, BusinessObjects};
use crate::{
    digest, normalize, publication_rejection, Action, ApplyOutcome, GraphChanges, LineageStore,
    Snapshot, StorageError, StorageEvent,
};
use neo4rs::{query, BoltType, Graph, Txn};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const BATCH_SIZE: usize = 256;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Neo4jConfig {
    pub uri: String,
    pub user: String,
    #[serde(default = "password_env")]
    pub password_env: String,
    #[serde(default = "database")]
    pub database: String,
    #[serde(default = "environment")]
    pub environment: String,
}
fn password_env() -> String {
    "FLOWSCOPE_NEO4J_PASSWORD".into()
}
fn database() -> String {
    "neo4j".into()
}
fn environment() -> String {
    "prod".into()
}

#[derive(Clone)]
pub struct Neo4jStore {
    graph: Graph,
    environment: String,
}
fn bolt(value: Value) -> BoltType {
    value
        .try_into()
        .expect("JSON properties are Bolt-compatible")
}
async fn one(tx: &mut Txn, q: neo4rs::Query) -> Result<neo4rs::Row, StorageError> {
    let mut rows = tx.execute(q).await?;
    let row = rows
        .next(tx.handle())
        .await?
        .ok_or_else(|| StorageError::Invalid("graph endpoint missing".into()))?;
    while rows.next(tx.handle()).await?.is_some() {}
    Ok(row)
}
fn version_value(row: &neo4rs::Row, key: &str) -> Result<i64, StorageError> {
    row.get::<String>(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| StorageError::Invalid("stored source version missing".into()))
}
impl Neo4jStore {
    pub async fn connect(config: &Neo4jConfig, password: &str) -> Result<Self, StorageError> {
        if config.uri.contains('@') || config.environment.is_empty() {
            return Err(StorageError::Invalid(
                "URI must not embed credentials; environment is required".into(),
            ));
        }
        let cfg = neo4rs::ConfigBuilder::default()
            .uri(&config.uri)
            .user(&config.user)
            .password(password)
            .db(config.database.as_str())
            .max_connections(8)
            .build()?;
        let store = Self {
            graph: Graph::connect(cfg).await?,
            environment: config.environment.clone(),
        };
        for (label, key) in [
            ("LINEAGE_ENTITY", "lineage_key"),
            ("LINEAGE_SCOPE", "scope_key"),
            ("LINEAGE_EVENT", "event_id"),
            ("LINEAGE_REVISION", "revision_id"),
            ("LINEAGE_FACT", "fact_key"),
            ("LINEAGE_EDGE", "edge_key"),
            ("LINEAGE_ENTITY_LOCK", "lineage_key"),
            ("QUERY_ACTOR", "principal_id"),
            ("QUERY_EVENT", "event_id"),
            ("TABLE_REFERENCE", "reference_key"),
            ("LINEAGE_STORE", "store_id"),
        ] {
            store.graph.run(query(&format!("CREATE CONSTRAINT flowscope_{}_uk IF NOT EXISTS FOR (n:{label}) REQUIRE n.{key} IS UNIQUE",label.to_lowercase()))).await?;
        }
        for (name, label, keys) in [
            (
                "m_table_uk",
                "M_TABLE",
                "(n.catalog,n.db_name,n.table_name)",
            ),
            (
                "m_col_physical_uk",
                "Physical",
                "(n.catalog,n.db_name,n.table_name,n.col_name)",
            ),
            ("cte_uid_uk", "CTE", "n.fs_uid"),
            ("derived_col_uid_uk", "Derived", "n.fs_uid"),
        ] {
            store.graph.run(query(&format!("CREATE CONSTRAINT {name} IF NOT EXISTS FOR (n:{label}) REQUIRE {keys} IS UNIQUE"))).await?;
        }
        // Fact identity alone cannot serve edge projection or scope replacement.
        // Prepare and await these indexes before accepting any transactions.
        for (name, label, keys) in [
            ("flowscope_fact_edge", "LINEAGE_FACT", "n.edge_key"),
            (
                "flowscope_fact_scope_active",
                "LINEAGE_FACT",
                "n.scope_key,n.active",
            ),
            (
                "flowscope_scope_target",
                "LINEAGE_SCOPE",
                "n.target_key,n.withdrawn",
            ),
        ] {
            store
                .graph
                .run(query(&format!(
                    "CREATE RANGE INDEX {name} IF NOT EXISTS FOR (n:{label}) ON ({keys})"
                )))
                .await?;
            store
                .graph
                .run(query("CALL db.awaitIndex($name, 60)").param("name", name))
                .await?;
        }
        let mut tx = store.graph.start_txn().await?;
        let r=one(&mut tx,query("MERGE (s:LINEAGE_STORE {store_id:'flowscope'}) ON CREATE SET s.environment=$env SET s.lock_tick=coalesce(s.lock_tick,0)+1 RETURN s.environment AS env").param("env",config.environment.clone())).await?;
        let env: String = r
            .get("env")
            .map_err(|_| StorageError::Invalid("store environment missing".into()))?;
        if env != config.environment {
            tx.rollback().await?;
            return Err(StorageError::Invalid(
                "database is bound to a different environment".into(),
            ));
        }
        tx.commit().await?;
        Ok(store)
    }
    pub fn graph(&self) -> &Graph {
        &self.graph
    }

    /// Reconcile an unknown commit before checking permission for a new write.
    /// Revocation must not relabel an already committed event as blocked.
    pub async fn receipt(&self, e: &StorageEvent) -> Result<Option<ApplyOutcome>, StorageError> {
        let mut rows=self.graph.execute(query("MATCH (r:LINEAGE_EVENT {event_id:$id}) RETURN r.content_hash AS hash,r.outcome_json AS outcome").param("id",e.event_id.clone())).await?;
        let Some(row) = rows.next().await? else {
            return Ok(None);
        };
        while rows.next().await?.is_some() {}
        if row.get::<String>("hash").ok().as_deref() != Some(e.content_hash().as_str()) {
            return Err(StorageError::Conflict);
        }
        let outcome: Option<String> = row
            .get("outcome")
            .map_err(|_| StorageError::Invalid("incomplete graph receipt".into()))?;
        outcome
            .map(|o| serde_json::from_str(&o).map_err(StorageError::from))
            .transpose()
    }

    async fn apply_tx(
        &self,
        tx: &mut Txn,
        e: &StorageEvent,
        s: &Snapshot,
    ) -> Result<ApplyOutcome, StorageError> {
        let row=one(tx,query("MERGE (r:LINEAGE_EVENT {event_id:$id}) ON CREATE SET r.content_hash=$hash SET r.lock_tick=coalesce(r.lock_tick,0)+1 RETURN r.content_hash AS hash, coalesce(r.outcome_json,'') AS outcome")
            .param("id",e.event_id.clone()).param("hash",e.content_hash())).await?;
        let hash: String = row.get("hash").map_err(|_| StorageError::Conflict)?;
        if hash != e.content_hash() {
            return Err(StorageError::Conflict);
        }
        let existing: String = row.get("outcome").unwrap_or_default();
        if !existing.is_empty() {
            return Ok(serde_json::from_str(&existing)?);
        }
        tx.run(query("MATCH (r:LINEAGE_EVENT {event_id:$id}) SET r.principal_id=$principal,r.token_id=$token,r.policy_revision=$policy,r.action=$action,r.observed_at=$at,r.sql_text=$sql,r.analysis_json=$analysis,r.artifact_id=$artifact,r.parse_success=$success")
            .param("id",e.event_id.clone()).param("principal",e.principal_id.clone()).param("token",e.token_id.clone()).param("policy",e.policy_revision)
            .param("action",e.action.as_str()).param("at",e.observed_at.clone()).param("sql",e.sql.clone()).param("analysis",serde_json::to_string(&e.analysis)?)
            .param("artifact",s.artifact_id.clone()).param("success",!e.analysis.summary.has_errors)).await?;
        let outcome = match e.action {
            Action::Publish => self.publish(tx, e, s).await?,
            Action::RecordUsage => self.usage(tx, e, s).await?,
            _ => ApplyOutcome::recorded(),
        };
        tx.run(query("MATCH (r:LINEAGE_EVENT {event_id:$id}) SET r.outcome_json=$outcome,r.committed_at=datetime()")
            .param("id",e.event_id.clone()).param("outcome",serde_json::to_string(&outcome)?)).await?;
        Ok(outcome)
    }
    async fn usage(
        &self,
        tx: &mut Txn,
        e: &StorageEvent,
        s: &Snapshot,
    ) -> Result<ApplyOutcome, StorageError> {
        tx.run(query("MERGE (a:QUERY_ACTOR {principal_id:$principal}) ON CREATE SET a.ctime=datetime() SET a.principal_type=$kind MERGE (q:QUERY_EVENT {event_id:$event}) SET q.observed_at=$at,q.execution_status='not_observed',q.parse_success=$success,q.artifact_id=$artifact,q.sql_type=$type,q.policy_revision=$revision MERGE (a)-[:SUBMITTED_QUERY]->(q) WITH q MATCH (r:LINEAGE_EVENT {event_id:$event}) MERGE (q)-[:HAS_ANALYSIS]->(r)")
            .param("principal",e.principal_id.clone()).param("kind",e.principal_type.clone()).param("event",e.event_id.clone()).param("at",e.observed_at.clone())
            .param("success",!e.analysis.summary.has_errors).param("artifact",s.artifact_id.clone()).param("type",serde_json::to_value(e.analysis.sql_type)?.as_str().unwrap_or("unknown"))
            .param("revision",e.policy_revision)).await?;
        if !e.analysis.summary.has_errors {
            let references: BTreeSet<_> = s
                .references
                .iter()
                .map(|(name, role, t)| (name.clone(), role.clone(), t.clone()))
                .collect();
            let rows = references.into_iter().map(|(name,role,t)|json!({
                "key":digest(format!("{}:{name}",self.environment)), "name":name,"role":role,
                "cat":t.as_ref().map(|t|t.catalog.as_str()), "db":t.as_ref().map(|t|t.db_name.as_str()),
                "table":t.as_ref().map(|t|t.table_name.as_str())
            })).collect::<Vec<_>>();
            for rows in rows.chunks(BATCH_SIZE) {
                tx.run(query("UNWIND $rows AS row MATCH (q:QUERY_EVENT {event_id:$event}) OPTIONAL MATCH (t:M_TABLE {catalog:row.cat,db_name:row.db,table_name:row.table}) WITH q,row,collect(t) AS tables FOREACH (t IN CASE WHEN size(tables)=1 THEN tables ELSE [] END | MERGE (q)-[:USES_TABLE {usage_role:row.role}]->(t)) FOREACH (unused IN CASE WHEN size(tables)=1 THEN [] ELSE [1] END | MERGE (ref:TABLE_REFERENCE {reference_key:row.key}) ON CREATE SET ref.qualified_name=row.name,ref.resolution_status='unresolved_or_unregistered' MERGE (q)-[:USES_TABLE {usage_role:row.role}]->(ref))")
                    .param("rows",bolt(json!(rows))).param("event",e.event_id.clone())).await?;
            }
        }
        Ok(ApplyOutcome {
            lineage_status: "not_requested".into(),
            usage_status: "committed".into(),
            graph_changes: None,
            reason: e
                .analysis
                .summary
                .has_errors
                .then(|| "parse_errors_no_trusted_usage_edges".into()),
        })
    }

    async fn publish(
        &self,
        tx: &mut Txn,
        e: &StorageEvent,
        s: &Snapshot,
    ) -> Result<ApplyOutcome, StorageError> {
        if e.principal_type != "scheduler" {
            return Err(StorageError::Invalid(
                "only scheduler principals can publish".into(),
            ));
        }
        let c = e
            .source
            .as_ref()
            .ok_or_else(|| StorageError::Invalid("source context required".into()))?;
        if let Some(reason) = publication_rejection(e, s) {
            return Ok(ApplyOutcome::not_requested(reason));
        }
        let version = c.version()?;
        let scope = c.scope_key();
        let revision = format!("{scope}:{version}:{}", c.analysis_revision);
        let row=one(tx,query("MERGE (s:LINEAGE_SCOPE {scope_key:$scope}) ON CREATE SET s.current_version=-1,s.analysis_revision=-1 SET s.lock_tick=coalesce(s.lock_tick,0)+1,s.latest_seen_version=CASE WHEN coalesce(s.latest_seen_version,-1)<$version THEN $version ELSE s.latest_seen_version END RETURN toString(s.current_version) AS version,toString(s.analysis_revision) AS analysis_revision,coalesce(s.artifact_id,'') AS artifact,coalesce(s.target_key,'') AS old_target")
            .param("scope",scope.clone()).param("version",version)).await?;
        // neo4rs 0.8 decodes negative tiny integers incorrectly. Read version
        // sentinels as strings, then parse them without a lossy fallback.
        let current = version_value(&row, "version")?;
        let current_analysis = version_value(&row, "analysis_revision")?;
        let old_target: String = row.get("old_target").unwrap_or_default();
        let current_artifact: String = row.get("artifact").unwrap_or_default();
        if (version, i64::from(c.analysis_revision)) < (current, current_analysis) {
            return Ok(ApplyOutcome::blocked("stale_source_version"));
        }
        if (version, i64::from(c.analysis_revision)) == (current, current_analysis) {
            if current_artifact != s.artifact_id {
                return Err(StorageError::Conflict);
            }
            return Ok(ApplyOutcome {
                lineage_status: "committed".into(),
                usage_status: "not_requested".into(),
                reason: Some("already_current".into()),
                graph_changes: Some(GraphChanges::default()),
            });
        }
        let withdraw = c.event_kind == "withdraw";
        let mut affected = BTreeSet::new();
        let mut rows=tx.execute(query("MATCH (f:LINEAGE_FACT {scope_key:$scope,active:true}) RETURN f.edge_key AS edge").param("scope",scope.clone())).await?;
        while let Some(r) = rows.next(tx.handle()).await? {
            affected.insert(
                r.get::<String>("edge")
                    .map_err(|_| StorageError::Invalid("fact identity missing".into()))?,
            );
        }
        if !withdraw {
            affected.extend(s.facts.keys().cloned());
        }
        // Shared edge locks are acquired in deterministic order across sources.
        let affected: Vec<_> = affected.into_iter().collect();
        for keys in affected.chunks(BATCH_SIZE) {
            tx.run(query("UNWIND $keys AS key WITH key ORDER BY key MERGE (l:LINEAGE_EDGE {edge_key:key}) SET l.lock_tick=coalesce(l.lock_tick,0)+1")
                .param("keys", keys.to_vec())).await?;
        }
        // Lock shared business nodes as well as edges before taking before-images.
        // Sorted locks make concurrent sources count a shared creation only once.
        let mut node_keys: BTreeSet<String> = if withdraw {
            BTreeSet::new()
        } else {
            s.entities.keys().cloned().collect()
        };
        node_keys.extend(
            [
                old_target.clone(),
                s.target.as_ref().map(|t| t.key()).unwrap_or_default(),
            ]
            .into_iter()
            .filter(|key| !key.is_empty()),
        );
        let ordered_node_keys: Vec<_> = node_keys.iter().cloned().collect();
        for keys in ordered_node_keys.chunks(BATCH_SIZE) {
            tx.run(query("UNWIND $keys AS key WITH key ORDER BY key MERGE (l:LINEAGE_ENTITY_LOCK {lineage_key:key}) SET l.lock_tick=coalesce(l.lock_tick,0)+1").param("keys",keys.to_vec())).await?;
        }
        let before_nodes = business_nodes(tx, e, s, &node_keys).await?;
        let before_relationships = business_relationships(tx, &affected).await?;
        tx.run(
            query("MATCH (f:LINEAGE_FACT {scope_key:$scope,active:true}) SET f.active=false")
                .param("scope", scope.clone()),
        )
        .await?;
        tx.run(query("MERGE (r:LINEAGE_REVISION {revision_id:$revision}) SET r.scope_key=$scope,r.artifact_id=$artifact,r.sql_md5=$md5,r.source_version=$version,r.withdrawn=$withdraw WITH r MATCH (s:LINEAGE_SCOPE {scope_key:$scope}) OPTIONAL MATCH (s)-[old:CURRENT]->() DELETE old MERGE (s)-[:HAS_REVISION]->(r) MERGE (s)-[:CURRENT]->(r)")
            .param("revision",revision.clone()).param("scope",scope.clone()).param("artifact",s.artifact_id.clone()).param("md5",s.sql_md5.clone()).param("version",version).param("withdraw",withdraw)).await?;
        if !withdraw {
            self.entities(tx, e, s, &scope).await?;
            self.facts(tx, s, &scope, &revision).await?;
        }
        self.project(tx, &affected).await?;
        tx.run(query("MATCH (s:LINEAGE_SCOPE {scope_key:$scope}) SET s.current_version=$version,s.analysis_revision=$analysis,s.artifact_id=$artifact,s.sql_md5=$md5,s.withdrawn=$withdraw,s.target_key=$target,s.task_name=$name,s.utime=datetime()")
            .param("scope",scope.clone()).param("version",version).param("analysis",i64::from(c.analysis_revision)).param("artifact",s.artifact_id.clone()).param("md5",s.sql_md5.clone()).param("withdraw",withdraw)
            .param("target",s.target.as_ref().map(|t|t.key()).unwrap_or_default()).param("name",c.task_name.clone())).await?;
        // Compatibility properties are only authoritative for a single producer.
        let targets: BTreeSet<_> = [
            old_target,
            s.target.as_ref().map(|t| t.key()).unwrap_or_default(),
        ]
        .into_iter()
        .filter(|t| !t.is_empty())
        .collect();
        for target in targets {
            tx.run(query("MATCH (t:LINEAGE_ENTITY:M_TABLE {lineage_key:$target}) OPTIONAL MATCH (s:LINEAGE_SCOPE {target_key:$target,withdrawn:false}) WITH t,collect(s) AS scopes SET t.producer_scopes=[s IN scopes | s.scope_key],t.task_sql_md5=CASE WHEN size(scopes)=1 THEN scopes[0].sql_md5 ELSE '' END")
            .param("target",target)).await?;
        }
        Ok(ApplyOutcome {
            lineage_status: "committed".into(),
            usage_status: "not_requested".into(),
            reason: withdraw.then(|| "withdrawn".into()),
            graph_changes: Some(GraphChanges::between(
                &before_nodes,
                &business_nodes(tx, e, s, &node_keys).await?,
                &before_relationships,
                &business_relationships(tx, &affected).await?,
            )),
        })
    }

    async fn entities(
        &self,
        tx: &mut Txn,
        e: &StorageEvent,
        s: &Snapshot,
        scope: &str,
    ) -> Result<(), StorageError> {
        let mut groups = BTreeMap::<&str, Vec<Value>>::new();
        for n in s.entities.values() {
            let t = n.table.as_ref();
            groups.entry(&n.kind).or_default().push(json!({
                "key":n.key, "cat":t.map(|t|t.catalog.as_str()).unwrap_or_default(),
                "db":t.map(|t|t.db_name.as_str()).unwrap_or_default(),
                "table":t.map(|t|t.table_name.as_str()).unwrap_or_default(),
                "column":n.column.as_deref().unwrap_or_default(),
                "fqn":t.map(|t|t.fqn()).unwrap_or_default(), "props":n.props
            }));
        }
        for (kind, nodes) in groups {
            let body = match kind {
                "table"=>"MERGE (n:M_TABLE {catalog:row.cat,db_name:row.db,table_name:row.table}) ON CREATE SET n.ctime=datetime() SET n:LINEAGE_ENTITY,n.lineage_key=row.key,n.fs_kind='table',n.fs_fqn=row.fqn,n.utime=datetime()",
                "physical"=>"MERGE (n:M_COL:Physical {catalog:row.cat,db_name:row.db,table_name:row.table,col_name:row.column}) ON CREATE SET n.ctime=datetime() SET n:LINEAGE_ENTITY,n.lineage_key=row.key,n.fs_kind='physical_column',n += row.props,n.utime=datetime()",
                "cte"=>"MERGE (n:CTE {fs_uid:row.key}) ON CREATE SET n.ctime=datetime() SET n:LINEAGE_ENTITY,n.lineage_key=row.key,n += row.props,n.artifact_id=$artifact,n.utime=datetime()",
                "derived"=>"MERGE (n:M_COL:Derived {fs_uid:row.key}) ON CREATE SET n.ctime=datetime() SET n:LINEAGE_ENTITY,n.lineage_key=row.key,n += row.props,n.artifact_id=$artifact,n.utime=datetime()",
                "template"=>"MERGE (n:TEMPLATE {scheduler:'mario',mario_template_id:$source}) ON CREATE SET n.ctime=datetime() SET n:LINEAGE_ENTITY,n.lineage_key=row.key,n += row.props,n.task_sql_md5=$md5,n.utime=datetime()",
                "sync"=>"MERGE (n:SYNC {scheduler:'change',task_id:$source}) ON CREATE SET n.ctime=datetime() SET n:LINEAGE_ENTITY,n.lineage_key=row.key,n += row.props,n.task_sql_md5=$md5,n.utime=datetime()",
                "output"=>"MERGE (n:LINEAGE_OUTPUT {fs_uid:row.key}) SET n:LINEAGE_ENTITY,n.lineage_key=row.key,n += row.props,n.utime=datetime()",
                _=>return Err(StorageError::Invalid("unknown entity kind".into())),
            };
            for rows in nodes.chunks(BATCH_SIZE) {
                tx.run(
                    query(&format!("UNWIND $rows AS row {body}"))
                        .param("rows", bolt(json!(rows)))
                        .param("artifact", s.artifact_id.clone())
                        .param("md5", s.sql_md5.clone())
                        .param(
                            "source",
                            e.source
                                .as_ref()
                                .and_then(|c| c.source_id.parse::<i64>().ok())
                                .unwrap_or(0),
                        ),
                )
                .await?;
                if matches!(kind, "cte" | "derived") {
                    tx.run(query("UNWIND $rows AS row MATCH (s:LINEAGE_SCOPE {scope_key:$scope}),(n:LINEAGE_ENTITY {lineage_key:row.key}) MERGE (s)-[o:OWNS_LINEAGE {artifact_id:$artifact}]->(n) SET o.sql_md5=$md5,o.utime=datetime()")
                        .param("rows",bolt(json!(rows))).param("scope",scope.to_string())
                        .param("artifact",s.artifact_id.clone()).param("md5",s.sql_md5.clone())).await?;
                }
            }
        }
        Ok(())
    }
    async fn facts(
        &self,
        tx: &mut Txn,
        s: &Snapshot,
        scope: &str,
        revision: &str,
    ) -> Result<(), StorageError> {
        let rows = s
            .facts
            .values()
            .map(|f| {
                Ok(json!({
                    "from":f.from,"to":f.to,"id":digest(format!("{revision}:{}",f.key)),
                    "edge":f.key,"kind":f.kind,"props":serde_json::to_string(&f.props)?
                }))
            })
            .collect::<Result<Vec<_>, StorageError>>()?;
        for rows in rows.chunks(BATCH_SIZE) {
            let row=one(tx,query("UNWIND $rows AS row MATCH (a:LINEAGE_ENTITY {lineage_key:row.from}),(b:LINEAGE_ENTITY {lineage_key:row.to}),(r:LINEAGE_REVISION {revision_id:$revision}) MERGE (f:LINEAGE_FACT {fact_key:row.id}) SET f.scope_key=$scope,f.edge_key=row.edge,f.kind=row.kind,f.from_key=row.from,f.to_key=row.to,f.props_json=row.props,f.sql_md5=$md5,f.active=true MERGE (r)-[:HAS_FACT]->(f) RETURN count(f) AS n")
                .param("rows",bolt(json!(rows))).param("revision",revision.to_string())
                .param("scope",scope.to_string()).param("md5",s.sql_md5.clone())).await?;
            if row.get::<i64>("n").unwrap_or(0) != rows.len() as i64 {
                return Err(StorageError::Invalid("fact endpoint missing".into()));
            }
        }
        Ok(())
    }
    async fn project(&self, tx: &mut Txn, keys: &[String]) -> Result<(), StorageError> {
        #[derive(Default)]
        struct Projection {
            kind: String,
            src: String,
            dst: String,
            props: String,
            hashes: BTreeSet<String>,
            scopes: BTreeSet<String>,
        }
        for keys in keys.chunks(BATCH_SIZE) {
            let mut rows=tx.execute(query("UNWIND $keys AS key MATCH (f:LINEAGE_FACT {edge_key:key}) RETURN f.edge_key AS edge,f.kind AS kind,f.from_key AS src,f.to_key AS dst,f.props_json AS props,f.active AS active,f.sql_md5 AS md5,f.scope_key AS scope ORDER BY f.fact_key")
                .param("keys",keys.to_vec())).await?;
            let mut projections = BTreeMap::<String, Projection>::new();
            while let Some(r) = rows.next(tx.handle()).await? {
                let key = r
                    .get::<String>("edge")
                    .map_err(|_| StorageError::Invalid("fact identity missing".into()))?;
                let p = projections.entry(key).or_default();
                p.kind = r
                    .get("kind")
                    .map_err(|_| StorageError::Invalid("fact kind".into()))?;
                p.src = r.get("src").unwrap_or_default();
                p.dst = r.get("dst").unwrap_or_default();
                p.props = r.get("props").unwrap_or_else(|_| "{}".into());
                if r.get::<bool>("active").unwrap_or(false) {
                    p.hashes.insert(r.get::<String>("md5").unwrap_or_default());
                    p.scopes
                        .insert(r.get::<String>("scope").unwrap_or_default());
                }
            }
            let mut groups = BTreeMap::<(String, bool), Vec<Value>>::new();
            for (key, p) in projections {
                if ![
                    "READS_FROM",
                    "REF_TABLE_COL",
                    "REF_TEP",
                    "DERIVES_COL",
                    "JOINS_WITH",
                    "CONTROLS_COL",
                ]
                .contains(&p.kind.as_str())
                {
                    return Err(StorageError::Invalid(
                        "invalid projected relation kind".into(),
                    ));
                }
                let active = !p.scopes.is_empty();
                groups.entry((p.kind,active)).or_default().push(json!({
                    "edge":key,"src":p.src,"dst":p.dst,"props":if active { serde_json::from_str::<Value>(&p.props)? } else { json!({}) },
                    "hashes":p.hashes,"scopes":p.scopes
                }));
            }
            for ((kind, active), rows) in groups {
                if active {
                    let q=format!("UNWIND $rows AS row MATCH (a:LINEAGE_ENTITY {{lineage_key:row.src}}),(b:LINEAGE_ENTITY {{lineage_key:row.dst}}) MERGE (a)-[r:{kind} {{projection_key:row.edge}}]->(b) ON CREATE SET r.ctime=datetime() SET r += row.props,r.sql_md5_list=row.hashes,r.frequency=size(row.hashes),r.source_scopes=row.scopes,r.utime=datetime() RETURN count(r) AS n");
                    let row = one(tx, query(&q).param("rows", bolt(json!(rows)))).await?;
                    if row.get::<i64>("n").unwrap_or(0) != rows.len() as i64 {
                        return Err(StorageError::Invalid("projection endpoint missing".into()));
                    }
                } else {
                    tx.run(query(&format!("UNWIND $rows AS row MATCH (a:LINEAGE_ENTITY {{lineage_key:row.src}})-[r:{kind} {{projection_key:row.edge}}]->(b:LINEAGE_ENTITY {{lineage_key:row.dst}}) DELETE r"))
                        .param("rows",bolt(json!(rows)))).await?;
                }
            }
        }
        Ok(())
    }
}
fn business_label(kind: &str) -> &'static str {
    match kind {
        "table" => "M_TABLE",
        "physical" => "M_COL:Physical",
        "derived" => "M_COL:Derived",
        "cte" => "CTE",
        "template" => "TEMPLATE",
        "sync" => "SYNC",
        _ => "LINEAGE_OUTPUT",
    }
}

fn business_object(row: &neo4rs::Row) -> Result<BusinessObject, StorageError> {
    let kind = row
        .get("kind")
        .map_err(|_| StorageError::Invalid("missing change kind".into()))?;
    let keys: Vec<String> = row
        .get("keys")
        .map_err(|_| StorageError::Invalid("missing change property names".into()))?;
    let values: Vec<Value> = row
        .get("values")
        .map_err(|_| StorageError::Invalid("invalid change properties".into()))?;
    let mut properties: BTreeMap<String, Value> = keys.into_iter().zip(values).collect();
    for key in ["producer_scopes", "source_scopes", "sql_md5_list"] {
        if let Some(Value::Array(values)) = properties.get_mut(key) {
            values.sort_by_key(Value::to_string);
        }
    }
    Ok(BusinessObject { kind, properties })
}

async fn business_nodes(
    tx: &mut Txn,
    event: &StorageEvent,
    snapshot: &Snapshot,
    keys: &BTreeSet<String>,
) -> Result<BusinessObjects, StorageError> {
    let mut groups = BTreeMap::<&str, Vec<Value>>::new();
    for key in keys {
        let entity = snapshot.entities.get(key);
        let table = entity.and_then(|value| value.table.as_ref());
        groups.entry(entity.map(|value|value.kind.as_str()).unwrap_or("existing")).or_default().push(json!({
            "key":key,"cat":table.map(|t|t.catalog.as_str()).unwrap_or_default(),"db":table.map(|t|t.db_name.as_str()).unwrap_or_default(),
            "table":table.map(|t|t.table_name.as_str()).unwrap_or_default(),"column":entity.and_then(|value|value.column.as_deref()).unwrap_or_default()
        }));
    }
    let mut result = BTreeMap::new();
    for (kind, nodes) in groups {
        let pattern=match kind {
            "table"=>"(n:M_TABLE {catalog:row.cat,db_name:row.db,table_name:row.table})",
            "physical"=>"(n:M_COL:Physical {catalog:row.cat,db_name:row.db,table_name:row.table,col_name:row.column})",
            "cte"=>"(n:CTE {fs_uid:row.key})","derived"=>"(n:M_COL:Derived {fs_uid:row.key})",
            "template"=>"(n:TEMPLATE {scheduler:'mario',mario_template_id:$source})",
            "sync"=>"(n:SYNC {scheduler:'change',task_id:$source})","output"=>"(n:LINEAGE_OUTPUT {fs_uid:row.key})",
            _=>"(n:LINEAGE_ENTITY {lineage_key:row.key})",
        };
        let label = business_label(if kind == "existing" { "table" } else { kind });
        for nodes in nodes.chunks(BATCH_SIZE) {
            let mut rows=tx.execute(query(&format!("UNWIND $rows AS row MATCH {pattern} WITH row,n,[k IN keys(n) WHERE NOT k IN ['ctime','utime','lock_tick']] AS ks RETURN row.key AS key,$kind AS kind,ks AS keys,[k IN ks | n[k]] AS values"))
                .param("rows",bolt(json!(nodes))).param("kind",label)
                .param("source",event.source.as_ref().and_then(|c|c.source_id.parse::<i64>().ok()).unwrap_or(0))).await?;
            while let Some(row) = rows.next(tx.handle()).await? {
                let key = row
                    .get("key")
                    .map_err(|_| StorageError::Invalid("missing change identity".into()))?;
                result.insert(key, business_object(&row)?);
            }
        }
    }
    Ok(result)
}

async fn business_relationships(
    tx: &mut Txn,
    keys: &[String],
) -> Result<BusinessObjects, StorageError> {
    let mut result = BTreeMap::new();
    for keys in keys.chunks(BATCH_SIZE) {
        let mut rows=tx.execute(query("UNWIND $keys AS edge CALL { WITH edge MATCH (f:LINEAGE_FACT {edge_key:edge}) RETURN f.from_key AS src,f.to_key AS dst LIMIT 1 } MATCH (a:LINEAGE_ENTITY {lineage_key:src})-[r]->(b:LINEAGE_ENTITY {lineage_key:dst}) WHERE r.projection_key=edge WITH edge,r,[k IN keys(r) WHERE NOT k IN ['ctime','utime']] AS ks RETURN edge AS key,type(r) AS kind,ks AS keys,[k IN ks | r[k]] AS values").param("keys",keys.to_vec())).await?;
        while let Some(row) = rows.next(tx.handle()).await? {
            let key = row.get("key").map_err(|_| {
                StorageError::Invalid("missing relationship change identity".into())
            })?;
            result.insert(key, business_object(&row)?);
        }
    }
    Ok(result)
}

impl LineageStore for Neo4jStore {
    async fn apply(&self, e: &StorageEvent) -> Result<ApplyOutcome, StorageError> {
        if e.environment != self.environment
            || e.action == Action::Publish
                && e.source
                    .as_ref()
                    .is_some_and(|s| s.environment != self.environment)
        {
            return Err(StorageError::Invalid(
                "event environment does not match database".into(),
            ));
        }
        let s = normalize(e);
        let mut tx = self.graph.start_txn().await?;
        match self.apply_tx(&mut tx, e, &s).await {
            Ok(outcome) => {
                tx.commit().await?;
                Ok(outcome)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }
}
