use super::helpers::generate_output_node_id;
use crate::dialect_ext::FlowscopeHiveDialect;
use crate::types::{Edge, FilterClauseType, FilterPredicate, JoinType, Node, NodeType, Span};
use sqlparser::ast::{Expr, FunctionArg, FunctionArgExpr, SelectItem, SetExpr, Statement};
use sqlparser::parser::Parser;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

pub(crate) const DBT_MODEL_SINK_METADATA_KEY: &str = "dbtModelSink";

/// Tracks a SELECT * that couldn't be expanded due to missing schema.
///
/// When a wildcard is encountered without schema metadata to resolve it,
/// we record the source and target so that downstream column references
/// can be used to infer what columns must have flowed through.
#[derive(Debug, Clone)]
pub(crate) struct PendingWildcard {
    /// The source canonical name (table or CTE) with unknown columns
    pub(crate) source_canonical: String,
    /// Exact CTE/derived relation node receiving the wildcard. Alias names can
    /// repeat in nested scopes and therefore cannot safely identify this target.
    pub(crate) target_node_id: Arc<str>,
    /// Node ID of the source
    pub(crate) source_node_id: Arc<str>,
}

/// A single table/view reference in a FROM or JOIN clause.
///
/// Each alias of the same canonical table gets its own instance with a unique
/// `node_id`. This allows self-joins like `FROM employees e1 JOIN employees e2`
/// to produce two distinct graph nodes.
#[derive(Debug, Clone)]
pub(crate) struct RelationInstance {
    /// Canonical (fully-qualified) table name used for schema lookup
    pub(crate) canonical: String,
    /// Node ID in the lineage graph (unique per instance)
    pub(crate) node_id: Arc<str>,
}

/// A virtual UDTF output, kept separate from physical relations.
#[derive(Debug, Clone)]
pub(crate) struct LateralViewBinding {
    pub(crate) table_alias: String,
    pub(crate) column_alias: String,
    pub(crate) sources: Vec<ColumnRef>,
    pub(crate) expression: String,
}

/// A recognized but invalid virtual reference must never fall back to an
/// implied physical column. Ambiguity is diagnosed at use, not declaration.
pub(crate) enum LateralViewResolution<'a> {
    NotFound,
    Resolved(&'a LateralViewBinding),
    Ambiguous,
    UnknownColumn,
}

/// Represents a single scope level for column resolution.
/// Each SELECT/subquery/CTE body gets its own scope.
#[derive(Debug, Clone, Default)]
pub(crate) struct Scope {
    /// Deterministic ID for this lexical scope within a statement.
    pub(crate) scope_id: usize,
    /// Tables directly referenced in this scope's FROM/JOIN clauses.
    /// Maps canonical table name -> node ID.
    /// For backwards compatibility, the last registered instance wins here.
    pub(crate) tables: HashMap<String, Arc<str>>,
    /// Aliases defined in this scope (alias -> canonical name)
    pub(crate) aliases: HashMap<String, String>,
    /// Alias -> relation instance (node_id + canonical) for instance-aware lookups.
    /// Keys are the alias name when aliased; for unaliased tables, both the simple
    /// name (e.g., `"employees"`) and the fully-qualified canonical name
    /// (e.g., `"public.employees"`) are registered so that either form resolves.
    pub(crate) alias_instances: HashMap<String, RelationInstance>,
    /// Subquery aliases in this scope
    pub(crate) subquery_aliases: HashSet<String>,
    /// Scope-local output columns for subquery/CTE aliases materialized in this scope.
    /// These shadow statement-global CTE definitions when alias names are reused.
    pub(crate) subquery_columns: HashMap<String, Vec<OutputColumn>>,
    /// All declared outputs, including duplicate names and constant inputs.
    /// Keeping candidates prevents either registration order from winning.
    pub(crate) lateral_view_bindings: Vec<LateralViewBinding>,
    /// User-visible relation names declared by this SELECT's FROM/JOIN list.
    ///
    /// Anonymous derived relations receive internal names, so reserve explicit
    /// names before visiting the list. This prevents a later user alias from
    /// overwriting an already-registered anonymous relation.
    pub(crate) reserved_relation_names: HashSet<String>,
    /// Number of anonymous derived relations registered in this lexical scope.
    ///
    /// SQL permits a derived relation in `FROM` without an explicit alias in
    /// several dialects. The analyzer still needs a deterministic internal
    /// identity for its materialized projection so unqualified outer columns
    /// can be resolved without treating the inner tables as outer-scope
    /// relations.
    pub(crate) anonymous_derived_relations: usize,
    /// True when the scope contains a table function relation whose output
    /// columns may be dialect-provided rather than schema-backed.
    pub(crate) has_table_function_relation: bool,
}

impl Scope {
    pub(crate) fn new(scope_id: usize) -> Self {
        Self {
            scope_id,
            ..Self::default()
        }
    }
}

/// Information about the current JOIN being processed.
#[derive(Debug, Clone, Default)]
pub(crate) struct JoinInfo {
    /// The type of join (INNER, LEFT, etc.)
    pub(crate) join_type: Option<JoinType>,
    /// The join condition expression (ON clause text)
    pub(crate) join_condition: Option<String>,
}

/// Context for analyzing a single statement.
///
/// # Instance-Aware Resolution
///
/// When the same table appears multiple times with different aliases (self-join),
/// each alias gets a unique [`RelationInstance`] with its own node ID. This enables:
/// - Per-instance filter attachment (e.g., `WHERE e1.active = true`)
/// - Distinct column ownership edges per alias
/// - Accurate lineage for `SELECT e1.col, e2.col FROM t e1 JOIN t e2`
///
/// ## Lookup Order
///
/// 1. `alias_instances` (via [`resolve_alias_instance`](Self::resolve_alias_instance)) —
///    instance-specific node ID for a given alias.
/// 2. `aliases` → `tables` / `table_node_ids` — canonical fallback when no alias
///    instance is registered (single-reference or unaliased tables).
/// 3. `cte_definitions` — statement-global CTE definition nodes.
///
/// ## Limitations
///
/// - Unaliased self-joins (e.g., `FROM t JOIN t`) collapse to a single node because
///   there is no alias to differentiate instances.
/// - The first CTE reference in a scope reuses the definition node; only subsequent
///   references get distinct instance nodes (see `resolve_cte_reference`).
pub(crate) struct StatementContext {
    pub(crate) statement_index: usize,
    /// Statement-local nodes.
    ///
    /// Read-only iteration is fine, but **structural mutations** (push/remove/
    /// swap) must go through `add_node` / `remove_node_by_id` so `node_index`
    /// stays in sync. In-place mutation of an existing node's fields is safe.
    pub(crate) nodes: Vec<Node>,
    pub(crate) edges: Vec<Edge>,
    pub(crate) node_ids: HashSet<Arc<str>>,
    /// Fast lookup from node ID to index in `nodes`, kept in sync with
    /// `add_node` / `remove_node_by_id`. Used by hot paths like
    /// `add_name_span` to avoid O(n) linear scans per call.
    node_index: HashMap<Arc<str>, usize>,
    pub(crate) edge_ids: HashSet<Arc<str>>,
    /// CTE name -> node ID
    pub(crate) cte_definitions: HashMap<String, Arc<str>>,
    /// Node ID -> CTE/derived alias name for reverse lookups
    pub(crate) cte_node_to_name: HashMap<Arc<str>, String>,
    /// Cursor for sequential left-to-right searching of definition-like spans.
    ///
    /// Used for CTE definition names and derived-table aliases, where the AST
    /// visitor still relies on roughly lexical traversal order.
    pub(crate) span_search_cursor: usize,
    /// Per-relation cursor for table/view/CTE occurrences keyed by the raw name
    /// as written in the AST (`users`, `public.users`, `"my.schema"."t"`, etc.).
    ///
    /// This avoids coupling unrelated relations to a single global cursor, so a
    /// mildly out-of-order traversal across different relations does not silently
    /// mis-assign a later occurrence of the same name in release builds.
    relation_span_cursors: HashMap<String, usize>,
    /// Alias -> canonical table name (global, for backwards compatibility)
    pub(crate) table_aliases: HashMap<String, String>,
    /// Subquery aliases (for reference tracking)
    pub(crate) subquery_aliases: HashSet<String>,
    /// Last join/operation type for edge labeling
    pub(crate) last_operation: Option<String>,
    /// Current join information (type + condition) for edge labeling
    pub(crate) current_join_info: JoinInfo,
    /// Table canonical name -> node ID (for column ownership) — global registry.
    ///
    /// In self-joins, the last registered instance overwrites the previous entry,
    /// so this map points to an arbitrary instance for self-joined tables. Use
    /// `resolve_alias_instance` (via `alias_instances` on `Scope`) for
    /// instance-specific lookups when an alias is available.
    pub(crate) table_node_ids: HashMap<String, Arc<str>>,
    /// Output columns for this statement (for column lineage)
    pub(crate) output_columns: Vec<OutputColumn>,
    /// Id of this statement's sink node. Holds one of two shapes:
    ///
    /// - A statement-scoped `Output` node id, produced by
    ///   [`Self::ensure_output_node_with_model`] for standalone SELECTs.
    /// - A canonical relation id (Table/View), produced by
    ///   [`Self::ensure_model_relation_sink`] for dbt models. Using the
    ///   canonical id here is what lets downstream `ref(...)` consumers
    ///   merge onto the same node, so multi-hop dbt chains render as one
    ///   connected graph instead of per-file fragments.
    pub(crate) sink_node_id: Option<Arc<str>>,
    /// Statement-global output columns for named CTE definitions.
    /// Scope-local alias materialization lives on [`Scope::subquery_columns`] so reused
    /// aliases do not leak across sibling branches or nested scopes.
    pub(crate) aliased_subquery_columns: HashMap<String, Vec<OutputColumn>>,
    /// Stack of scopes for proper column resolution
    /// The top of the stack (last element) is the current scope
    pub(crate) scope_stack: Vec<Scope>,
    /// Monotonic counter used to assign stable lexical scope IDs per statement.
    pub(crate) next_scope_id: usize,
    /// Pending filter predicates to attach to table nodes.
    /// Maps table canonical name -> list of filter predicates.
    pub(crate) pending_filters: HashMap<String, Vec<FilterPredicate>>,
    /// Instance-aware pending filters keyed by node ID (for self-join disambiguation).
    pub(crate) pending_instance_filters: HashMap<Arc<str>, Vec<FilterPredicate>>,
    /// Grouping columns for the current SELECT (normalized expression strings)
    /// Used to detect aggregation vs grouping key columns
    pub(crate) grouping_columns: HashSet<String>,
    /// True if the current SELECT has a GROUP BY clause
    pub(crate) has_group_by: bool,
    /// Columns referenced per source table (canonical_name → column_name → data_type).
    /// Used to build implied schema for source tables in SELECT queries.
    pub(crate) source_table_columns: HashMap<String, HashMap<String, Option<String>>>,
    /// Implied foreign key relationships from JOIN conditions.
    /// Key: (from_table, from_column), Value: (to_table, to_column)
    pub(crate) implied_foreign_keys: HashMap<(String, String), (String, String)>,
    /// Pending wildcards that couldn't be expanded due to missing schema.
    /// Used for backward column inference from downstream references.
    pub(crate) pending_wildcards: Vec<PendingWildcard>,
    /// Tracks which table nodes were introduced via JOIN (node_id → join metadata).
    /// Used to identify joined tables for dependency edges, complexity scoring,
    /// and base-table detection without storing join info on Node structs.
    pub(crate) joined_table_info: HashMap<Arc<str>, JoinInfo>,
    /// Set when alias instance registration is skipped due to the safety limit.
    /// Checked once after statement analysis to emit a user-visible warning.
    pub(crate) instance_limit_reached: bool,
}

/// Represents an output column in the SELECT list
#[derive(Debug, Clone)]
pub(crate) struct OutputColumn {
    /// Alias or derived name for the column
    pub(crate) name: String,
    /// Inferred data type of the column
    pub(crate) data_type: Option<String>,
    /// Node ID for this column
    pub(crate) node_id: Arc<str>,
}

/// A reference to a source column
#[derive(Debug, Clone)]
pub(crate) struct ColumnRef {
    /// Table name or alias
    pub(crate) table: Option<String>,
    /// Column name
    pub(crate) column: String,
}

impl StatementContext {
    pub(crate) fn new(statement_index: usize) -> Self {
        Self {
            statement_index,
            nodes: Vec::new(),
            edges: Vec::new(),
            node_ids: HashSet::new(),
            node_index: HashMap::new(),
            edge_ids: HashSet::new(),
            cte_definitions: HashMap::new(),
            cte_node_to_name: HashMap::new(),
            span_search_cursor: 0,
            relation_span_cursors: HashMap::new(),
            table_aliases: HashMap::new(),
            subquery_aliases: HashSet::new(),
            last_operation: None,
            current_join_info: JoinInfo::default(),
            table_node_ids: HashMap::new(),
            output_columns: Vec::new(),
            sink_node_id: None,
            aliased_subquery_columns: HashMap::new(),
            scope_stack: Vec::new(),
            next_scope_id: 0,
            pending_filters: HashMap::new(),
            pending_instance_filters: HashMap::new(),
            grouping_columns: HashSet::new(),
            has_group_by: false,
            source_table_columns: HashMap::new(),
            implied_foreign_keys: HashMap::new(),
            pending_wildcards: Vec::new(),
            joined_table_info: HashMap::new(),
            instance_limit_reached: false,
        }
    }

    /// Clear grouping context for a new SELECT
    pub(crate) fn clear_grouping(&mut self) {
        self.grouping_columns.clear();
        self.has_group_by = false;
    }

    /// Add a grouping column expression
    pub(crate) fn add_grouping_column(&mut self, expr: String) {
        self.grouping_columns.insert(expr);
        self.has_group_by = true;
    }

    /// Check if an expression matches a grouping column
    pub(crate) fn is_grouping_column(&self, expr: &str) -> bool {
        self.grouping_columns.contains(expr)
    }

    /// Record a column reference for a source table.
    ///
    /// This is used to build implied schema for source tables. If the column
    /// already exists without a type and a type is provided, the type is updated.
    pub(crate) fn record_source_column(
        &mut self,
        canonical_table: &str,
        column_name: &str,
        data_type: Option<String>,
    ) {
        let columns = self
            .source_table_columns
            .entry(canonical_table.to_string())
            .or_default();

        columns
            .entry(column_name.to_string())
            .and_modify(|existing| {
                // Update type if we have one and don't already have one
                if existing.is_none() && data_type.is_some() {
                    *existing = data_type.clone();
                }
            })
            .or_insert(data_type);
    }

    /// Record an implied foreign key relationship from a JOIN condition.
    ///
    /// When we see `ON t1.a = t2.b`, we record that t1.a references t2.b.
    /// The "from" side is considered the FK column, "to" is the referenced column.
    ///
    /// ## Self-Join Exclusion
    ///
    /// Conditions where `from_table == to_table` are **intentionally excluded**.
    /// While self-referential FKs do exist (e.g., `employees.manager_id → employees.id`
    /// for hierarchical data), detecting them from JOIN conditions alone would produce
    /// too many false positives. For example, `SELECT * FROM t t1 JOIN t t2 ON t1.x = t2.y`
    /// is a common pattern that doesn't imply a self-FK.
    ///
    /// If self-referential FK detection is needed, users should provide explicit schema
    /// via the `schema` field in the request.
    pub(crate) fn record_implied_foreign_key(
        &mut self,
        from_table: &str,
        from_column: &str,
        to_table: &str,
        to_column: &str,
    ) {
        // Skip self-joins (see doc comment for rationale)
        if from_table != to_table {
            self.implied_foreign_keys.insert(
                (from_table.to_string(), from_column.to_string()),
                (to_table.to_string(), to_column.to_string()),
            );
        }
    }

    /// Add a filter predicate for a specific table.
    ///
    /// # Parameters
    ///
    /// - `canonical`: The canonical table name
    /// - `expression`: The filter expression text
    /// - `clause_type`: The type of SQL clause (WHERE, HAVING, etc.)
    pub(crate) fn add_filter_for_table(
        &mut self,
        canonical: &str,
        expression: String,
        clause_type: FilterClauseType,
    ) {
        self.pending_filters
            .entry(canonical.to_string())
            .or_default()
            .push(FilterPredicate {
                expression,
                clause_type,
            });
    }

    /// Add a filter predicate targeted at a specific node by ID.
    ///
    /// Used when instance-aware resolution is available (e.g., qualified
    /// column references in self-joins) to attach filters to the correct
    /// alias instance rather than an ambiguous canonical match.
    pub(crate) fn add_filter_for_instance(
        &mut self,
        node_id: &Arc<str>,
        expression: String,
        clause_type: FilterClauseType,
    ) {
        self.pending_instance_filters
            .entry(node_id.clone())
            .or_default()
            .push(FilterPredicate {
                expression,
                clause_type,
            });
    }

    pub(crate) fn add_node(&mut self, node: Node) -> Arc<str> {
        let id = node.id.clone();
        if self.node_ids.insert(id.clone()) {
            self.node_index.insert(id.clone(), self.nodes.len());
            self.nodes.push(node);
        }
        id
    }

    /// Remove a node (and its index entry) by ID in O(1).
    pub(crate) fn remove_node_by_id(&mut self, node_id: &Arc<str>) {
        let Some(idx) = self.node_index.remove(node_id) else {
            return;
        };
        self.node_ids.remove(node_id);

        let removed = self.nodes.swap_remove(idx);
        debug_assert_eq!(&removed.id, node_id);

        if idx < self.nodes.len() {
            let moved_id = self.nodes[idx].id.clone();
            self.node_index.insert(moved_id, idx);
        }
    }

    pub(crate) fn add_edge(&mut self, edge: Edge) {
        let id = edge.id.clone();
        if self.edge_ids.insert(id) {
            self.edges.push(edge);
        }
    }

    /// Returns a mutable node by ID using the maintained index.
    pub(crate) fn node_mut(&mut self, node_id: &Arc<str>) -> Option<&mut Node> {
        let &idx = self.node_index.get(node_id)?;
        let node = self.nodes.get_mut(idx)?;
        debug_assert_eq!(&node.id, node_id);
        Some(node)
    }

    /// Returns the per-relation name-occurrence cursor for `raw_name`.
    pub(crate) fn relation_span_cursor(&mut self, raw_name: &str) -> &mut usize {
        self.relation_span_cursors
            .entry(raw_name.to_string())
            .or_insert(0)
    }

    /// Attach a relation-name occurrence span to an existing node.
    pub(crate) fn add_name_span(&mut self, node_id: &Arc<str>, span: crate::types::Span) {
        if let Some(node) = self.node_mut(node_id) {
            if !node.name_spans.contains(&span) {
                node.name_spans.push(span);
            }
        }
    }

    /// Creates or returns the output node for this statement.
    ///
    /// When `model_name` is provided (e.g., for dbt models), the output node
    /// will use the model name as both its label and qualified_name. This
    /// enables proper cross-statement linking for dbt model references.
    pub(crate) fn ensure_output_node_with_model(&mut self, model_name: Option<&str>) -> Arc<str> {
        if let Some(existing) = self.sink_node_id.as_ref() {
            return existing.clone();
        }

        let node_id = generate_output_node_id(self.statement_index);
        // Use model name for label if provided, otherwise use generic Output label
        let label = match model_name {
            Some(name) => name.to_string(),
            None if self.statement_index == 0 => "Output".to_string(),
            None => format!("Output ({})", self.statement_index + 1),
        };
        let qualified_name = model_name.map(Arc::<str>::from);
        let output_node = Node {
            id: node_id.clone(),
            node_type: NodeType::Output,
            label: label.into(),
            qualified_name,
            ..Default::default()
        };

        self.add_node(output_node);
        self.sink_node_id = Some(node_id.clone());
        node_id
    }

    /// Creates or returns the sink node for a dbt model's bare SELECT.
    ///
    /// Unlike `ensure_output_node_with_model`, which synthesizes a
    /// statement-scoped `Output` node, this materializes the sink as the
    /// canonical shared model node (`Table`, `View`, or `Cte` for ephemeral
    /// dbt models). When another dbt model references this one via
    /// `FROM {{ ref(...) }}`, its source node resolves to the same canonical
    /// id, so the flattener merges producer and consumer into a single graph
    /// node and multi-hop `A -> B -> C` chains render as one connected
    /// lineage rather than disconnected per-file fragments.
    pub(crate) fn ensure_model_relation_sink(
        &mut self,
        model_name: &str,
        canonical_id: Arc<str>,
        node_type: NodeType,
        span: Option<Span>,
    ) -> Arc<str> {
        if let Some(existing) = self.sink_node_id.as_ref() {
            return existing.clone();
        }

        let label: Arc<str> = Arc::from(model_name);
        let mut metadata = HashMap::new();
        metadata.insert("definitionOccurrence".to_string(), serde_json::json!(true));
        metadata.insert(
            DBT_MODEL_SINK_METADATA_KEY.to_string(),
            serde_json::json!(true),
        );
        let sink_node = Node {
            id: canonical_id.clone(),
            node_type,
            label: label.clone(),
            qualified_name: Some(label),
            span,
            metadata: Some(metadata),
            ..Default::default()
        };

        self.add_node(sink_node);
        self.sink_node_id = Some(canonical_id.clone());
        canonical_id
    }

    /// Returns the id of this statement's sink, if one has been materialized.
    ///
    /// The sink represents "where this statement writes". Callers must not
    /// assume it is always a statement-scoped `Output` node — for dbt models
    /// it is the canonical relation node (`Table` / `View` / `Cte`) created
    /// by [`Self::ensure_model_relation_sink`], which is the same node that
    /// downstream `ref(...)` consumers resolve to. Treat the returned id as
    /// opaque and look up the node's `node_type` if behavior needs to branch
    /// on the sink's kind.
    pub(crate) fn sink_node_id(&self) -> Option<&Arc<str>> {
        self.sink_node_id.as_ref()
    }

    /// Push a new scope onto the stack (entering a SELECT/subquery)
    pub(crate) fn push_scope(&mut self) {
        let scope_id = self.next_scope_id;
        self.next_scope_id += 1;
        self.scope_stack.push(Scope::new(scope_id));
    }

    /// Pop the current scope (leaving a SELECT/subquery)
    pub(crate) fn pop_scope(&mut self) {
        self.scope_stack.pop();
    }

    /// Get the current (topmost) scope, if any
    pub(crate) fn current_scope(&self) -> Option<&Scope> {
        self.scope_stack.last()
    }

    /// Returns the deterministic ID of the current lexical scope.
    pub(crate) fn current_scope_id(&self) -> Option<usize> {
        self.current_scope().map(|scope| scope.scope_id)
    }

    /// Get the current (topmost) scope mutably, if any
    pub(crate) fn current_scope_mut(&mut self) -> Option<&mut Scope> {
        self.scope_stack.last_mut()
    }

    /// Register a table in the current scope
    pub(crate) fn register_table_in_scope(&mut self, canonical: String, node_id: Arc<str>) {
        // Always register in global table_node_ids for node lookups
        self.table_node_ids
            .insert(canonical.clone(), node_id.clone());

        // Also register in current scope for resolution
        if let Some(scope) = self.current_scope_mut() {
            scope.tables.insert(canonical, node_id);
        }
    }

    /// Register an alias in the current scope.
    ///
    /// Also populates `alias_instances` when a node ID for the canonical name
    /// is already known (via `table_node_ids`), keeping the two maps in sync.
    /// Uses `or_insert` so that a previously registered instance-specific ID
    /// (from `register_alias_instance`) is not overwritten.
    pub(crate) fn register_alias_in_scope(&mut self, alias: String, canonical: String) {
        // Register in global aliases for backwards compatibility
        self.table_aliases.insert(alias.clone(), canonical.clone());

        // Look up node_id to keep alias_instances in sync
        let node_id = self.table_node_ids.get(&canonical).cloned();

        // Also register in current scope
        if let Some(scope) = self.current_scope_mut() {
            scope.aliases.insert(alias.clone(), canonical.clone());
            // Populate alias_instances if we have a node_id and no entry exists yet
            if let Some(node_id) = node_id {
                scope
                    .alias_instances
                    .entry(alias)
                    .or_insert(RelationInstance { canonical, node_id });
            }
        }
    }

    /// Register an alias with its instance node ID for self-join-aware resolution.
    ///
    /// Applies a defensive limit to prevent excessive memory use in pathological
    /// queries (e.g., 100-way self-joins where each alias creates a full column set).
    pub(crate) fn register_alias_instance(
        &mut self,
        alias: String,
        canonical: String,
        node_id: Arc<str>,
    ) {
        /// Maximum number of alias instances across all scopes in a single statement.
        /// This is a safety limit, not expected to be hit in real queries.
        const MAX_INSTANCES_PER_STATEMENT: usize = 500;

        let total_instances: usize = self
            .scope_stack
            .iter()
            .map(|s| s.alias_instances.len())
            .sum();
        if total_instances >= MAX_INSTANCES_PER_STATEMENT {
            #[cfg(feature = "tracing")]
            tracing::warn!(
                alias = %alias,
                canonical = %canonical,
                "alias instance limit ({MAX_INSTANCES_PER_STATEMENT}) reached, skipping registration"
            );
            self.instance_limit_reached = true;
            return;
        }

        if let Some(scope) = self.current_scope_mut() {
            scope
                .alias_instances
                .insert(alias, RelationInstance { canonical, node_id });
        }
    }

    /// Resolve an alias to its relation instance (canonical name + node_id).
    ///
    /// Searches the scope stack from innermost to outermost scope. Returns `None`
    /// if the alias is not registered as an instance in any scope.
    pub(crate) fn resolve_alias_instance(&self, alias: &str) -> Option<&RelationInstance> {
        for scope in self.scope_stack.iter().rev() {
            if let Some(instance) = scope.alias_instances.get(alias) {
                return Some(instance);
            }
        }
        None
    }

    /// Get distinct relation instances in the current scope.
    ///
    /// Unlike `tables_in_current_scope`, this preserves multiple aliases that
    /// refer to the same canonical relation.
    pub(crate) fn relation_instances_in_current_scope(&self) -> Vec<RelationInstance> {
        let Some(scope) = self.current_scope() else {
            return Vec::new();
        };

        let mut seen = HashSet::new();
        let mut instances: Vec<_> = scope
            .alias_instances
            .values()
            .filter(|instance| seen.insert(instance.node_id.clone()))
            .cloned()
            .collect();
        instances.sort_by(|left, right| {
            left.canonical
                .cmp(&right.canonical)
                .then_with(|| left.node_id.cmp(&right.node_id))
        });
        instances
    }

    /// Count distinct relation instances for a canonical name in the current scope.
    pub(crate) fn relation_instance_count_in_current_scope(&self, canonical: &str) -> usize {
        self.relation_instances_in_current_scope()
            .into_iter()
            .filter(|instance| instance.canonical == canonical)
            .count()
    }

    /// Register a subquery alias in the current scope
    pub(crate) fn register_subquery_alias_in_scope(&mut self, alias: String) {
        // Register globally
        self.subquery_aliases.insert(alias.clone());

        // Also register in current scope
        if let Some(scope) = self.current_scope_mut() {
            scope.subquery_aliases.insert(alias);
        }
    }

    /// Mark that the current scope contains a table function relation.
    pub(crate) fn mark_table_function_in_scope(&mut self) {
        if let Some(scope) = self.current_scope_mut() {
            scope.has_table_function_relation = true;
        }
    }

    /// Returns true when the current scope contains a table function relation.
    pub(crate) fn current_scope_has_table_function_relation(&self) -> bool {
        self.current_scope()
            .is_some_and(|scope| scope.has_table_function_relation)
    }

    /// Register statement-global output columns for a named CTE definition.
    pub(crate) fn register_cte_output_columns(&mut self, name: String, columns: Vec<OutputColumn>) {
        self.aliased_subquery_columns.insert(name, columns);
    }

    /// Register scope-local output columns for a derived table or aliased CTE instance.
    pub(crate) fn register_subquery_columns_in_scope(
        &mut self,
        name: String,
        columns: Vec<OutputColumn>,
    ) {
        if let Some(scope) = self.current_scope_mut() {
            scope.subquery_columns.insert(name, columns);
        } else {
            self.aliased_subquery_columns.insert(name, columns);
        }
    }

    pub(crate) fn register_lateral_view_binding(&mut self, binding: LateralViewBinding) {
        if let Some(scope) = self.current_scope_mut() {
            scope.lateral_view_bindings.push(binding);
        }
    }

    /// Resolve table-qualified outputs (`e.value`), bare outputs (`value`),
    /// and the existing struct-element form (`value.member`). Real relation
    /// qualifiers win. Bare names never escape their SELECT scope.
    pub(crate) fn resolve_lateral_view_binding(
        &self,
        source: &ColumnRef,
    ) -> LateralViewResolution<'_> {
        for scope in self.scope_stack.iter().rev() {
            let qualifier = source.table.as_deref();
            if let Some(q) = qualifier {
                if scope
                    .aliases
                    .keys()
                    .chain(scope.tables.keys())
                    .chain(scope.alias_instances.keys())
                    .any(|name| name.eq_ignore_ascii_case(q))
                {
                    return LateralViewResolution::NotFound;
                }
            }
            let (table_qualifier, member_output) = qualifier
                .and_then(|q| q.split_once('.'))
                .map_or((qualifier, None), |(table, output)| {
                    (
                        Some(table),
                        Some(output.split('.').next().unwrap_or(output)),
                    )
                });
            if table_qualifier.is_some_and(|q| {
                scope
                    .aliases
                    .keys()
                    .chain(scope.tables.keys())
                    .chain(scope.alias_instances.keys())
                    .any(|name| name.eq_ignore_ascii_case(q))
            }) {
                return LateralViewResolution::NotFound;
            }
            let table_known = table_qualifier.is_some_and(|q| {
                scope
                    .lateral_view_bindings
                    .iter()
                    .any(|b| b.table_alias.eq_ignore_ascii_case(q))
            });
            let mut candidates = scope.lateral_view_bindings.iter().filter(|binding| {
                if table_known {
                    table_qualifier.is_some_and(|q| binding.table_alias.eq_ignore_ascii_case(q))
                        && binding
                            .column_alias
                            .eq_ignore_ascii_case(member_output.unwrap_or(&source.column))
                } else {
                    binding
                        .column_alias
                        .eq_ignore_ascii_case(qualifier.unwrap_or(&source.column))
                }
            });
            if let Some(binding) = candidates.next() {
                return if candidates.next().is_some() {
                    LateralViewResolution::Ambiguous
                } else {
                    LateralViewResolution::Resolved(binding)
                };
            }
            if table_known {
                return LateralViewResolution::UnknownColumn;
            }
            if qualifier.is_none() {
                break;
            }
        }
        LateralViewResolution::NotFound
    }

    /// Resolves `struct_output.member` when its first identifier is not a
    /// visible relation alias, but is uniquely proven to be a struct-valued
    /// output column from a relation in the current scope. The returned ref is
    /// deliberately the base column, preserving its existing value lineage.
    ///
    /// This is not a general two-part-identifier fallback: physical aliases
    /// always win, ambiguous base columns return `None`, and the producer must
    /// have an expression that explicitly constructs a struct.
    pub(crate) fn resolve_derived_struct_member_base(
        &self,
        source: &ColumnRef,
    ) -> Option<ColumnRef> {
        let base = source.table.as_deref()?;
        for scope in self.scope_stack.iter().rev() {
            if scope.aliases.contains_key(base)
                || scope.tables.contains_key(base)
                || scope.alias_instances.contains_key(base)
            {
                return None;
            }
        }

        let mut candidates = Vec::new();
        for relation in self.relation_instances_in_current_scope() {
            let Some(columns) = self.resolve_subquery_columns(&relation.canonical) else {
                continue;
            };
            for column in columns {
                if !column.name.eq_ignore_ascii_case(base) {
                    continue;
                }
                let is_struct_producer = self
                    .nodes
                    .iter()
                    .find(|node| node.id == column.node_id)
                    .and_then(|node| node.expression.as_deref())
                    .is_some_and(is_proven_struct_expression);
                if is_struct_producer {
                    candidates.push((relation.canonical.clone(), column.name.clone()));
                }
            }
        }
        candidates.sort();
        candidates.dedup();
        (candidates.len() == 1).then(|| ColumnRef {
            table: Some(candidates[0].0.clone()),
            column: candidates[0].1.clone(),
        })
    }

    /// Reserve an explicit relation name in the current SELECT before its
    /// FROM/JOIN items are visited. Reservations affect only internally
    /// generated anonymous-derived names; they never alter SQL resolution.
    pub(crate) fn reserve_relation_name_in_current_scope(&mut self, name: String) {
        if let Some(scope) = self.current_scope_mut() {
            scope.reserved_relation_names.insert(name);
        }
    }

    /// Allocate a deterministic, analyzer-internal canonical name for an
    /// unnamed derived relation in the current lexical scope.
    ///
    /// The name is not an SQL alias and is never selected as a fallback for a
    /// user-provided qualifier. It only lets the normal scope and
    /// `RelationInstance` machinery represent a syntactically unnamed `FROM
    /// (SELECT ...)` relation. Keeping the ordinal per scope makes siblings
    /// distinct, so an unqualified column across two anonymous relations stays
    /// ambiguous instead of being silently bound to one of them.
    pub(crate) fn next_anonymous_derived_relation_name(&mut self) -> String {
        let statement_index = self.statement_index;
        let cte_names: HashSet<String> = self.cte_definitions.keys().cloned().collect();
        let Some(scope) = self.current_scope_mut() else {
            return "__flowscope_derived_without_scope_0".to_string();
        };

        loop {
            let ordinal = scope.anonymous_derived_relations;
            scope.anonymous_derived_relations += 1;
            let candidate = format!(
                "__flowscope_derived_statement_{}_scope_{}_{}",
                statement_index, scope.scope_id, ordinal
            );
            if !cte_names.contains(&candidate)
                && !scope.reserved_relation_names.contains(&candidate)
                && !scope.tables.contains_key(&candidate)
                && !scope.aliases.contains_key(&candidate)
                && !scope.alias_instances.contains_key(&candidate)
                && !scope.subquery_columns.contains_key(&candidate)
            {
                return candidate;
            }
        }
    }

    /// Returns true when the current scope already materialized columns for `name`.
    pub(crate) fn has_subquery_columns_in_current_scope(&self, name: &str) -> bool {
        self.current_scope()
            .is_some_and(|scope| scope.subquery_columns.contains_key(name))
    }

    /// Resolve subquery/CTE output columns with lexical scoping.
    ///
    /// Scope-local aliases shadow statement-global CTE definition columns.
    ///
    /// The walk stops at the first scope where `name` resolves to a **physical table**
    /// (not a CTE) but has no entry in `subquery_columns`. Without this guard, a
    /// physical-table alias in an inner scope (e.g. `FROM tbl t`) would fall through
    /// to an outer scope where a derived subquery shares the same alias `t`, returning
    /// wrong column nodes and producing spurious Ownership edges that cause
    /// `MULTIPLE_TARGET_TABLES` false positives.
    pub(crate) fn resolve_subquery_columns(&self, name: &str) -> Option<&[OutputColumn]> {
        for scope in self.scope_stack.iter().rev() {
            if let Some(columns) = scope.subquery_columns.get(name) {
                return Some(columns.as_slice());
            }
            // If `name` is an alias for a non-CTE (physical table/view) in this scope,
            // stop the upward walk. CTE aliases must NOT be blocked here because their
            // output columns live in `aliased_subquery_columns` (registered globally via
            // `register_cte_output_columns`), which is checked after the loop.
            if let Some(canonical) = scope.aliases.get(name) {
                if !self.cte_definitions.contains_key(canonical.as_str()) {
                    return None;
                }
            }
            // Also stop when `name` directly matches a physical-table canonical (not a CTE).
            if scope.tables.contains_key(name) && !self.cte_definitions.contains_key(name) {
                return None;
            }
        }

        self.aliased_subquery_columns.get(name).map(Vec::as_slice)
    }

    /// Get tables that are in scope for column resolution.
    /// Returns tables from the current scope only.
    pub(crate) fn tables_in_current_scope(&self) -> Vec<String> {
        if let Some(scope) = self.current_scope() {
            scope.tables.keys().cloned().collect()
        } else {
            Vec::new()
        }
    }

    /// Returns a checkpoint representing the current length of the output column buffer.
    ///
    /// This is part of the **projection checkpoint pattern** used when analyzing nested
    /// queries (CTEs, derived tables). The pattern works as follows:
    ///
    /// 1. Before analyzing a subquery, call `projection_checkpoint()` to record the current
    ///    buffer position
    /// 2. Analyze the subquery, which appends its output columns to the buffer
    /// 3. Call `take_output_columns_since(checkpoint)` to extract only the columns produced
    ///    by that subquery, leaving earlier columns intact
    ///
    /// This ensures that columns from inner queries don't leak into the schema of outer
    /// statements (e.g., a CTE's internal columns shouldn't appear in a CREATE TABLE AS
    /// statement's implied schema).
    pub(crate) fn projection_checkpoint(&self) -> usize {
        self.output_columns.len()
    }

    /// Drains output columns produced since the provided checkpoint.
    ///
    /// See [`projection_checkpoint`](Self::projection_checkpoint) for usage pattern.
    pub(crate) fn take_output_columns_since(&mut self, checkpoint: usize) -> Vec<OutputColumn> {
        if checkpoint > self.output_columns.len() {
            // This indicates a logic error: the checkpoint was taken from a different context
            // or the output_columns were modified unexpectedly.
            debug_assert!(
                false,
                "Invalid projection checkpoint: {} > buffer length {}",
                checkpoint,
                self.output_columns.len()
            );
            return Vec::new();
        }
        if checkpoint == self.output_columns.len() {
            // No new columns were produced - this is valid (e.g., empty subquery)
            return Vec::new();
        }
        self.output_columns.split_off(checkpoint)
    }
}

/// Proves that a materialized projection itself is a struct value. This parses
/// the already-normalized expression rather than searching its display text:
/// scalar wrappers that merely *contain* a `named_struct` argument must not
/// authorize `scalar.member` resolution.
fn is_proven_struct_expression(expression: &str) -> bool {
    let sql = format!("SELECT {expression}");
    let Ok(mut statements) = Parser::parse_sql(&FlowscopeHiveDialect::default(), &sql) else {
        return false;
    };
    let Some(Statement::Query(query)) = statements.pop() else {
        return false;
    };
    let SetExpr::Select(select) = *query.body else {
        return false;
    };
    let Some(item) = select.projection.first() else {
        return false;
    };
    let expression = match item {
        SelectItem::UnnamedExpr(expression)
        | SelectItem::ExprWithAlias {
            expr: expression, ..
        } => expression,
        SelectItem::Wildcard(_) | SelectItem::QualifiedWildcard(_, _) => return false,
    };
    is_proven_struct_ast(expression)
}

fn is_proven_struct_ast(expression: &Expr) -> bool {
    match expression {
        Expr::Nested(expression) => is_proven_struct_ast(expression),
        Expr::Struct { .. } => true,
        Expr::Cast { data_type, .. } => matches!(data_type, sqlparser::ast::DataType::Struct(_, _)),
        Expr::Function(function) => {
            let name = function.name.to_string().to_ascii_lowercase();
            if name == "named_struct" {
                return true;
            }
            if !matches!(name.as_str(), "aggregate" | "reduce") {
                return false;
            }
            let sqlparser::ast::FunctionArguments::List(arguments) = &function.args else {
                return false;
            };
            let expressions: Vec<_> = arguments
                .args
                .iter()
                .filter_map(|argument| match argument {
                    FunctionArg::Unnamed(FunctionArgExpr::Expr(expression))
                    | FunctionArg::Named {
                        arg: FunctionArgExpr::Expr(expression),
                        ..
                    } => Some(expression),
                    _ => None,
                })
                .collect();
            // Spark aggregate/reduce preserve the accumulator's type when
            // there is no finish lambda. A finish expression is deliberately
            // rejected here unless future typed analysis can prove its result.
            expressions.len() == 3 && is_proven_struct_ast(expressions[1])
        }
        _ => false,
    }
}
