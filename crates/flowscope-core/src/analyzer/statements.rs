//! Statement-level analysis for DML operations (INSERT, UPDATE, DELETE, MERGE).
//!
//! This module handles Data Manipulation Language statements, analyzing data flow
//! between source and target tables. It delegates to specialized modules for DDL
//! and query analysis while managing the overall statement context and lineage graph.

use super::complexity;
use super::context::StatementContext;
use super::expression::ExpressionAnalyzer;
use super::helpers::{
    classify_query_type, extract_simple_name, generate_column_node_id, generate_edge_id,
    generate_node_id, split_qualified_identifiers,
};
use super::visitor::{LineageVisitor, Visitor};
use super::Analyzer;
use crate::error::ParseError;
use crate::types::{
    issue_codes, Edge, EdgeType, Issue, JoinType, Node, NodeType, Span, StatementLineage,
};
use regex::Regex;
use sqlparser::ast::{
    self, AlterTableOperation, Assignment, AssignmentTarget, CopyIntoSnowflakeKind, CopySource,
    CopyTarget, Expr, FromTable, MergeAction, MergeClause, MergeInsertKind, ObjectName,
    RenameTableNameKind, SetExpr, Statement, TableFactor, TableWithJoins, UpdateTableFromKind,
};
use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::sync::{Arc, LazyLock};
#[cfg(feature = "tracing")]
use tracing::{info, info_span};

#[cfg(feature = "templating")]
use crate::templater::TemplateMode;

/// Build a `Span` from a byte range, rejecting inverted or missing ranges.
///
/// `Span::new` stores whatever it's given; a range whose `start > end` would
/// silently produce a nonsense span that, downstream, could slice the wrong
/// bytes. This helper normalizes the "no usable range" case to `None` so
/// callers can fall back explicitly rather than propagate garbage.
fn span_from_range(range: Option<&Range<usize>>) -> Option<Span> {
    let range = range?;
    if range.start > range.end {
        return None;
    }
    Some(Span::new(range.start, range.end))
}

/// Information about a join node for dependency edge construction.
struct JoinNodeInfo {
    /// Node ID of the joined table
    node_id: Arc<str>,
    /// Type of join (INNER, LEFT, etc.)
    join_type: Option<JoinType>,
    /// Join condition expression (e.g., "a.id = b.id")
    join_condition: Option<Arc<str>>,
}

/// Source-text bookkeeping for a single statement passed to the analyzer.
///
/// Bundles both the templated and (when applicable) the untemplated source
/// ranges plus raw SQL, so statement-level analysis has a single handle to
/// the text it's analyzing. dbt materialization detection needs the
/// untemplated form; `StatementLineage` surfaces the resolved form to
/// downstream consumers.
pub(super) struct StatementSource {
    /// Byte range of this statement in the (possibly templated) source SQL.
    pub source_range: Range<usize>,
    /// Byte range of this statement in the untemplated source, when templating
    /// was applied. Used so spans computed for dbt producers point at the
    /// user's original file rather than the rendered output.
    pub original_source_range: Option<Range<usize>>,
    /// Untemplated SQL text for this statement, when templating was applied.
    pub original_sql: Option<String>,
    /// Resolved SQL text when templating was applied. Preserved on the
    /// statement lineage for downstream consumers.
    pub resolved_sql: Option<String>,
}

impl<'a> Analyzer<'a> {
    #[cfg_attr(feature = "tracing", tracing::instrument(skip(self, statement, source), fields(index, name = source_name.as_deref())))]
    pub(super) fn analyze_statement(
        &mut self,
        index: usize,
        statement: &Statement,
        source_name: Option<String>,
        source: StatementSource,
    ) -> Result<StatementLineage, ParseError> {
        let StatementSource {
            source_range,
            original_source_range,
            original_sql,
            resolved_sql,
        } = source;
        let mut ctx = StatementContext::new(index);

        let statement_type = match statement {
            Statement::Query(query) => {
                // In dbt mode, a bare SELECT represents a model that should be registered
                // with the model name derived from the source file path.
                let model_name = if self.is_dbt_mode() {
                    source_name.as_ref().map(|path| extract_model_name(path))
                } else {
                    None
                };

                // Normalize the model name to match how table references are normalized
                // (e.g., Snowflake normalizes to uppercase)
                let normalized_model_name = model_name.map(|n| self.normalize_table_name(n));
                let model_node_type = dbt_model_relation_type(original_sql.as_deref());

                let sink_target_id: Option<Arc<str>> = if let Some(ref name) = normalized_model_name
                {
                    // Register the model so downstream files that reference it via
                    // `ref(...)` reuse the correct canonical sink identity.
                    match model_node_type {
                        NodeType::View => self.tracker.record_view_produced(name, index),
                        NodeType::Table => self.tracker.record_produced(name, index),
                        NodeType::Cte => self.tracker.declare_ephemeral(name),
                        NodeType::Output | NodeType::Column => {
                            unreachable!("dbt model sinks must be relation-like")
                        }
                    }
                    // Materialize the sink as the canonical relation node so it
                    // unifies with consumer FROM references sharing the same
                    // canonical name (see issue #32).
                    let (canonical_id, node_type) = self.tracker.relation_identity(name);
                    // Prefer the untemplated range so the node's span points at
                    // the user's original file, but fall back to the templated
                    // range (and finally to None) if upstream hands us an
                    // inverted/invalid range. `Span::new` doesn't enforce
                    // start <= end, and an inverted span would slice the
                    // wrong bytes downstream.
                    let producer_span = span_from_range(original_source_range.as_ref())
                        .or_else(|| span_from_range(Some(&source_range)));
                    Some(ctx.ensure_model_relation_sink(
                        name,
                        canonical_id,
                        node_type,
                        producer_span,
                    ))
                } else {
                    // sqlparser parses `WITH cte AS (...) INSERT OVERWRITE TABLE t SELECT ...`
                    // as Statement::Query { body: SetExpr::Insert(...) }. In that case, the
                    // INSERT target is the real sink — create a Table node for it and use it
                    // as the sink so data_flow edges are created correctly.
                    if let SetExpr::Insert(Statement::Insert(insert)) = query.body.as_ref() {
                        let target_name = insert.table.to_string();
                        let canonical = self.normalize_table_name(&target_name);
                        let target_label = extract_simple_name(&target_name);
                        let target_id = ctx.add_node(Node {
                            id: generate_node_id("table", &canonical),
                            node_type: NodeType::Table,
                            label: target_label.into(),
                            qualified_name: Some(canonical.clone().into()),
                            ..Default::default()
                        });
                        self.tracker
                            .record_produced(&canonical, ctx.statement_index);
                        Some(target_id)
                    } else {
                        ctx.ensure_output_node_with_model(None);
                        None
                    }
                };

                self.analyze_query(&mut ctx, query, sink_target_id.as_deref());
                classify_query_type(query)
            }
            Statement::Insert(insert) => {
                self.analyze_insert(&mut ctx, insert);
                "INSERT".to_string()
            }
            Statement::CreateTable(create) => {
                if let Some(query) = &create.query {
                    self.analyze_create_table_as(&mut ctx, &create.name, query, create.temporary);
                    "CREATE_TABLE_AS".to_string()
                } else {
                    self.analyze_create_table(
                        &mut ctx,
                        &create.name,
                        &create.columns,
                        &create.constraints,
                        create.temporary,
                    );
                    "CREATE_TABLE".to_string()
                }
            }
            Statement::CreateView(create_view) => {
                self.analyze_create_view(
                    &mut ctx,
                    &create_view.name,
                    &create_view.query,
                    &create_view.columns,
                    create_view.temporary,
                );
                "CREATE_VIEW".to_string()
            }
            Statement::Update(update) => {
                self.analyze_update(
                    &mut ctx,
                    &update.table,
                    &update.assignments,
                    &update.from,
                    &update.selection,
                );
                "UPDATE".to_string()
            }
            Statement::Delete(delete) => {
                self.analyze_delete(
                    &mut ctx,
                    &delete.tables,
                    &delete.from,
                    &delete.using,
                    &delete.selection,
                );
                "DELETE".to_string()
            }
            Statement::Merge(merge) => {
                self.analyze_merge(
                    &mut ctx,
                    merge.into,
                    &merge.table,
                    &merge.source,
                    &merge.on,
                    &merge.clauses,
                );
                "MERGE".to_string()
            }
            Statement::Drop {
                object_type, names, ..
            } => {
                self.analyze_drop(&mut ctx, object_type, names);
                "DROP".to_string()
            }
            Statement::AlterTable(alter_table) => {
                self.analyze_alter_table(&mut ctx, &alter_table.name, &alter_table.operations);
                "ALTER_TABLE".to_string()
            }
            // Statements that are recognized but don't produce lineage
            // (admin, session, and metadata operations)
            Statement::AlterView { .. } => "ALTER_VIEW".to_string(),
            Statement::AlterIndex { .. } => "ALTER_INDEX".to_string(),
            Statement::AlterSchema(_) => "ALTER_SCHEMA".to_string(),
            Statement::AlterRole { .. } => "ALTER_ROLE".to_string(),
            Statement::Grant { .. } => "GRANT".to_string(),
            Statement::Revoke { .. } => "REVOKE".to_string(),
            Statement::Set(_) => "SET".to_string(),
            Statement::ShowVariable { .. } | Statement::ShowVariables { .. } => "SHOW".to_string(),
            Statement::Truncate { .. } => "TRUNCATE".to_string(),
            Statement::Comment { .. } => "COMMENT".to_string(),
            Statement::Explain { .. } | Statement::ExplainTable { .. } => "EXPLAIN".to_string(),
            Statement::Analyze { .. } => "ANALYZE".to_string(),
            Statement::Call(_) => "CALL".to_string(),
            Statement::Use(_) => "USE".to_string(),
            Statement::StartTransaction { .. }
            | Statement::Commit { .. }
            | Statement::Rollback { .. }
            | Statement::Savepoint { .. } => "TRANSACTION".to_string(),
            Statement::CreateIndex(_) => "CREATE_INDEX".to_string(),
            Statement::CreateSchema { .. } => "CREATE_SCHEMA".to_string(),
            Statement::CreateDatabase { .. } => "CREATE_DATABASE".to_string(),
            Statement::CreateRole { .. } => "CREATE_ROLE".to_string(),
            Statement::CreateFunction { .. } => "CREATE_FUNCTION".to_string(),
            Statement::CreateProcedure { .. } => "CREATE_PROCEDURE".to_string(),
            Statement::CreateTrigger { .. } => "CREATE_TRIGGER".to_string(),
            Statement::CreateType { .. } => "CREATE_TYPE".to_string(),
            Statement::CreateSequence { .. } => "CREATE_SEQUENCE".to_string(),
            Statement::CreateExtension { .. } => "CREATE_EXTENSION".to_string(),
            Statement::DropFunction { .. } => "DROP_FUNCTION".to_string(),
            Statement::DropProcedure { .. } => "DROP_PROCEDURE".to_string(),
            Statement::DropTrigger { .. } => "DROP_TRIGGER".to_string(),
            Statement::Copy {
                source, to, target, ..
            } => {
                self.analyze_copy(&mut ctx, source, *to, target);
                "COPY".to_string()
            }
            Statement::CopyIntoSnowflake {
                kind,
                into,
                from_obj,
                from_query,
                ..
            } => {
                self.analyze_copy_into_snowflake(&mut ctx, kind, into, from_obj, from_query);
                "COPY".to_string()
            }
            Statement::Unload {
                query, query_text, ..
            } => {
                self.analyze_unload(&mut ctx, query, query_text);
                "UNLOAD".to_string()
            }
            _ => {
                self.issues.push(
                    Issue::warning(
                        issue_codes::UNSUPPORTED_SYNTAX,
                        "Statement type not fully supported for lineage analysis",
                    )
                    .with_statement(index),
                );
                "UNKNOWN".to_string()
            }
        };

        // Apply pending filter predicates to table nodes before finalizing
        self.apply_pending_filters(&mut ctx);

        // Propagate inferred columns backward through SELECT * chains
        self.propagate_inferred_columns(&mut ctx);

        self.add_join_dependency_edges(&mut ctx);

        // Propagate join metadata from context onto edges originating from joined tables.
        // This ensures edges created during column analysis (not just create_source_edge)
        // carry join info for downstream consumers.
        Self::propagate_join_info_to_edges(&mut ctx);

        // Register implied schema for source tables referenced in the query
        self.register_source_tables_schema(&ctx);

        // Emit a user-visible warning when the alias instance limit was hit.
        // Lineage may be incomplete for the affected aliases.
        if ctx.instance_limit_reached {
            let mut issue = Issue::warning(
                issue_codes::MEMORY_LIMIT_EXCEEDED,
                "Alias instance limit reached; lineage for some self-join aliases may be incomplete",
            );
            issue.statement_index = Some(index);
            self.issues.push(issue);
        }

        // Calculate statement-level stats
        let join_count = complexity::count_joins(&ctx.joined_table_info);
        let complexity_score = complexity::calculate_complexity(&ctx.nodes, &ctx.joined_table_info);

        Ok(StatementLineage {
            statement_index: index,
            statement_type,
            source_name,
            nodes: ctx.nodes,
            edges: ctx.edges,
            span: Some(Span::new(source_range.start, source_range.end)),
            join_count,
            complexity_score,
            resolved_sql,
        })
    }

    fn add_join_dependency_edges(&self, ctx: &mut StatementContext) {
        let sink_node_id = match ctx.sink_node_id.as_ref() {
            Some(node_id) => node_id.clone(),
            None => return,
        };

        let output_column_ids: HashSet<_> = if self.column_lineage_enabled {
            ctx.edges
                .iter()
                .filter(|edge| edge.edge_type == EdgeType::Ownership && edge.from == sink_node_id)
                .map(|edge| edge.to.clone())
                .collect()
        } else {
            HashSet::new()
        };
        if self.column_lineage_enabled {
            let has_direct_output_lineage = ctx.edges.iter().any(|edge| {
                matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
                    && edge.to == sink_node_id
            });
            if output_column_ids.is_empty() && !has_direct_output_lineage {
                return;
            }
        }

        let mut table_columns: HashMap<Arc<str>, Vec<Arc<str>>> = HashMap::new();
        if self.column_lineage_enabled {
            for edge in &ctx.edges {
                if edge.edge_type == EdgeType::Ownership {
                    table_columns
                        .entry(edge.from.clone())
                        .or_default()
                        .push(edge.to.clone());
                }
            }
        }

        let join_nodes: Vec<JoinNodeInfo> = ctx
            .nodes
            .iter()
            .filter(|node| {
                node.node_type.is_table_like() && ctx.joined_table_info.contains_key(&node.id)
            })
            .filter_map(|node| {
                let info = ctx.joined_table_info.get(&node.id)?;
                Some(JoinNodeInfo {
                    node_id: node.id.clone(),
                    join_type: info.join_type,
                    join_condition: info.join_condition.as_deref().map(Into::into),
                })
            })
            .collect();

        for join_info in join_nodes {
            let JoinNodeInfo {
                node_id,
                join_type,
                join_condition,
            } = join_info;
            let contributes_to_output = if self.column_lineage_enabled {
                let owned_columns = table_columns.get(&node_id).cloned().unwrap_or_default();
                ctx.edges.iter().any(|edge| {
                    matches!(edge.edge_type, EdgeType::DataFlow | EdgeType::Derivation)
                        && (edge.from == node_id
                            || owned_columns.iter().any(|col| col == &edge.from))
                        && (edge.to == sink_node_id || output_column_ids.contains(&edge.to))
                })
            } else {
                false
            };

            if contributes_to_output {
                continue;
            }

            let edge_key = format!(
                "join_dependency:{node_id}:{join_type:?}:{}",
                join_condition.as_deref().unwrap_or("")
            );
            let edge_id = generate_edge_id(&edge_key, sink_node_id.as_ref());
            if ctx.edge_ids.contains(&edge_id) {
                continue;
            }

            ctx.add_edge(Edge {
                id: edge_id,
                from: node_id,
                to: sink_node_id.clone(),
                edge_type: EdgeType::JoinDependency,
                expression: None,
                operation: None,
                join_type,
                join_condition,
                metadata: None,
                approximate: None,
                statement_ids: Vec::new(),
            });
        }
    }

    /// Propagate join metadata from the context's `joined_table_info` map onto edges.
    ///
    /// Edges created during column analysis (e.g., wildcard expansion, aggregation)
    /// originate from joined tables but don't carry join info since they were not
    /// created via `create_source_edge`. This pass fills in the gap so downstream
    /// consumers (frontend, export) can read join info from edges alone.
    ///
    /// Only `DataFlow`, `Derivation`, and `JoinDependency` edges are eligible.
    /// If new edge types are introduced that should carry join context, extend
    /// the match below.
    ///
    /// Edges that already have `join_type` set are left untouched.
    fn propagate_join_info_to_edges(ctx: &mut StatementContext) {
        if ctx.joined_table_info.is_empty() {
            return;
        }

        // Single pass: build column→table ownership map and collect indices of edges
        // that are candidates for join info propagation. Each column has exactly one
        // owner, so later inserts for the same column are harmless.
        let mut column_to_table: HashMap<Arc<str>, Arc<str>> = HashMap::new();
        let mut candidate_indices: Vec<usize> = Vec::new();

        for (i, edge) in ctx.edges.iter().enumerate() {
            match edge.edge_type {
                EdgeType::Ownership => {
                    column_to_table.insert(edge.to.clone(), edge.from.clone());
                }
                EdgeType::DataFlow | EdgeType::Derivation | EdgeType::JoinDependency
                    if edge.join_type.is_none() =>
                {
                    candidate_indices.push(i);
                }
                _ => {}
            }
        }

        // Apply join info only to the candidate edges identified above.
        for i in candidate_indices {
            let edge = &ctx.edges[i];

            // Resolve the source to a table node ID (either directly or via column ownership)
            let source_table_id = if ctx.joined_table_info.contains_key(&edge.from) {
                Some(edge.from.clone())
            } else {
                column_to_table
                    .get(&edge.from)
                    .filter(|table_id| ctx.joined_table_info.contains_key(*table_id))
                    .cloned()
            };

            if let Some(info) = source_table_id.and_then(|id| ctx.joined_table_info.get(&id)) {
                let edge = &mut ctx.edges[i];
                edge.join_type = info.join_type;
                if edge.join_condition.is_none() {
                    edge.join_condition = info.join_condition.as_deref().map(Into::into);
                }
            }
        }
    }

    pub(super) fn analyze_insert(&mut self, ctx: &mut StatementContext, insert: &ast::Insert) {
        let target_name = insert.table.to_string();
        let canonical = self.normalize_table_name(&target_name);
        let target_label = extract_simple_name(&target_name);

        // Create target table node
        let target_id = ctx.add_node(Node {
            id: generate_node_id("table", &canonical),
            node_type: NodeType::Table,
            label: target_label.clone().into(),
            qualified_name: Some(canonical.clone().into()),
            ..Default::default()
        });
        if let Some(span) = self.locate_relation_name_span(ctx, &target_name) {
            ctx.add_name_span(&target_id, span);
        }

        self.tracker
            .record_produced(&canonical, ctx.statement_index);

        // Register the INSERT target as the statement-level sink so that
        // add_join_dependency_edges (which reads ctx.sink_node_id) correctly
        // creates JoinDependency edges for joined tables that don't otherwise
        // contribute column-level lineage to the target.
        ctx.sink_node_id = Some(target_id.clone());

        // Analyze source — use analyze_query (not analyze_query_body) so that
        // INSERT … WITH cte AS (…) SELECT … has its CTEs properly recognised.
        if let Some(ref source_body) = insert.source {
            self.analyze_query(ctx, source_body, Some(&target_id));
        }
    }

    pub(super) fn analyze_update(
        &mut self,
        ctx: &mut StatementContext,
        table: &TableWithJoins,
        assignments: &[Assignment],
        from: &Option<UpdateTableFromKind>,
        selection: &Option<Expr>,
    ) {
        let target_node_id = {
            let mut visitor = LineageVisitor::new(self, ctx, None);

            // 1. Analyze the target table
            visitor.analyze_dml_target_from_table_with_joins(table)
        };

        // 2. Analyze FROM clause (Postgres style) and joins in target table structure
        {
            let target = LineageVisitor::target_from_arc(target_node_id.as_ref());
            let mut visitor = LineageVisitor::new(self, ctx, target);

            if let Some(from_kind) = from {
                match from_kind {
                    UpdateTableFromKind::BeforeSet(tables) => {
                        for t in tables {
                            visitor.visit_table_with_joins(t);
                        }
                    }
                    UpdateTableFromKind::AfterSet(tables) => {
                        for t in tables {
                            visitor.visit_table_with_joins(t);
                        }
                    }
                }
            }

            for join in &table.joins {
                visitor.set_last_operation(Some("JOIN".to_string()));
                visitor.visit_table_factor(&join.relation);
            }
        }

        // 3a. Create column nodes for SET target columns
        for assignment in assignments {
            if let Some(col_name) = self.extract_assignment_target_name(assignment) {
                Self::add_target_column_node(ctx, target_node_id.as_deref(), &col_name);
            }
        }

        // 3b. Analyze assignment values and validate column references
        let mut expr_analyzer = ExpressionAnalyzer::new(self, ctx);
        for assignment in assignments {
            Self::analyze_assignment_targets(&mut expr_analyzer, assignment);
            expr_analyzer.analyze(&assignment.value);
        }

        // 4. Analyze selection (WHERE clause)
        if let Some(expr) = selection {
            expr_analyzer.analyze(expr);
        }
    }

    pub(super) fn analyze_delete(
        &mut self,
        ctx: &mut StatementContext,
        tables: &[ObjectName],
        from: &FromTable,
        using: &Option<Vec<TableWithJoins>>,
        selection: &Option<Expr>,
    ) {
        let mut target_ids: Vec<Arc<str>> = Vec::new();

        // Scope for visitor usage
        {
            let mut visitor = LineageVisitor::new(self, ctx, None);

            // Pre-register aliases from sources so multi-table deletes can resolve targets.
            match from {
                FromTable::WithFromKeyword(ts) | FromTable::WithoutKeyword(ts) => {
                    for t in ts {
                        visitor.register_aliases_in_table_with_joins(t);
                    }
                }
            }
            if let Some(us) = using {
                for t in us {
                    visitor.register_aliases_in_table_with_joins(t);
                }
            }

            // 1. Identify targets
            if !tables.is_empty() {
                // Multi-table delete - targets may reference aliases
                for obj in tables {
                    let name = obj.to_string();
                    let target_canonical = visitor
                        .resolve_table_alias(Some(&name))
                        .unwrap_or_else(|| visitor.canonicalize_table_reference(&name).canonical);

                    if let Some((_canonical, node_id)) =
                        visitor.analyze_dml_target(&target_canonical, None)
                    {
                        #[cfg(feature = "tracing")]
                        info!(target: "analyzer", "DELETE target identified: {} (ID: {})", _canonical, node_id);
                        target_ids.push(node_id);
                    }
                }
            } else {
                // Standard SQL: first table in FROM is target
                let ts = match from {
                    FromTable::WithFromKeyword(ts) | FromTable::WithoutKeyword(ts) => ts,
                };
                if let Some(first) = ts.first() {
                    if let TableFactor::Table { name, alias, .. } = &first.relation {
                        let name_str = name.to_string();
                        if let Some((_canonical, node_id)) =
                            visitor.analyze_dml_target(&name_str, alias.as_ref())
                        {
                            #[cfg(feature = "tracing")]
                            info!(target: "analyzer", "DELETE target identified: {} (ID: {})", _canonical, node_id);
                            target_ids.push(node_id);
                        }
                    }
                }
            }
        }
        // 2. Analyze sources (FROM + USING)
        let sources: Vec<&[TableWithJoins]> = {
            let from_tables = match from {
                FromTable::WithFromKeyword(ts) | FromTable::WithoutKeyword(ts) => ts.as_slice(),
            };
            let mut sources = vec![from_tables];
            if let Some(us) = using {
                sources.push(us.as_slice());
            }
            sources
        };

        if target_ids.is_empty() {
            let mut visitor = LineageVisitor::new(self, ctx, None);
            for ts in sources {
                for t in ts {
                    visitor.visit_table_with_joins(t);
                }
            }
        } else {
            for target_id in &target_ids {
                let mut visitor = LineageVisitor::new(self, ctx, Some(target_id.to_string()));
                for ts in &sources {
                    for t in *ts {
                        visitor.visit_table_with_joins(t);
                    }
                }
            }
        }

        // 3. Analyze selection
        if let Some(expr) = selection {
            let mut expr_analyzer = ExpressionAnalyzer::new(self, ctx);
            expr_analyzer.analyze(expr);
        }
    }

    pub(super) fn analyze_merge(
        &mut self,
        ctx: &mut StatementContext,
        _into: bool,
        table: &TableFactor,
        source: &TableFactor,
        on: &Expr,
        clauses: &[MergeClause],
    ) {
        // 1. Analyze Target Table and 2. Analyze Source Table (USING clause)
        let mut visitor = LineageVisitor::new(self, ctx, None);
        let target_id = visitor.analyze_dml_target_factor(table);

        visitor.set_target_node(LineageVisitor::target_from_arc(target_id.as_ref()));
        visitor.visit_table_factor(source);

        // 3a. Create column nodes for SET/INSERT target columns
        for clause in clauses {
            match &clause.action {
                MergeAction::Update(update_expr) => {
                    for assignment in &update_expr.assignments {
                        if let Some(col_name) = self.extract_assignment_target_name(assignment) {
                            Self::add_target_column_node(ctx, target_id.as_deref(), &col_name);
                        }
                    }
                }
                MergeAction::Insert(insert_expr) => {
                    for col in &insert_expr.columns {
                        if let Some(ident) = col.0.iter().filter_map(|p| p.as_ident()).next_back() {
                            let col_name = self.normalize_identifier(&ident.value);
                            Self::add_target_column_node(ctx, target_id.as_deref(), &col_name);
                        }
                    }
                }
                MergeAction::Delete { .. } => {}
            }
        }

        // 3b. Analyze ON predicate
        let mut expr_analyzer = ExpressionAnalyzer::new(self, ctx);
        expr_analyzer.analyze(on);

        // 4. Analyze MERGE clauses (expression analysis for column references and values)
        for clause in clauses {
            match &clause.action {
                MergeAction::Update(update_expr) => {
                    for assignment in &update_expr.assignments {
                        Self::analyze_assignment_targets(&mut expr_analyzer, assignment);
                        expr_analyzer.analyze(&assignment.value);
                    }
                }
                MergeAction::Insert(insert_expr) => {
                    for col in &insert_expr.columns {
                        Self::analyze_object_name_as_column(&mut expr_analyzer, col);
                    }
                    match &insert_expr.kind {
                        MergeInsertKind::Values(values) => {
                            for row in &values.rows {
                                for value in row {
                                    expr_analyzer.analyze(value);
                                }
                            }
                        }
                        MergeInsertKind::Row => {}
                    }
                }
                MergeAction::Delete { .. } => {}
            }

            if let Some(ref predicate) = clause.predicate {
                expr_analyzer.analyze(predicate);
            }
        }
    }

    /// Analyze the left-hand side of an assignment (SET target = value).
    /// Registers target column references in the lineage graph.
    fn analyze_assignment_targets(
        expr_analyzer: &mut ExpressionAnalyzer<'_, '_>,
        assignment: &Assignment,
    ) {
        let names = match &assignment.target {
            AssignmentTarget::ColumnName(name) => vec![name],
            AssignmentTarget::Tuple(names) => names.iter().collect(),
        };
        for name in names {
            Self::analyze_object_name_as_column(expr_analyzer, name);
        }
    }

    /// Create a Column node for a target column and an Ownership edge from the
    /// parent table node.  Used by UPDATE SET and MERGE SET/INSERT to register
    /// target-side column nodes in the lineage graph.
    fn add_target_column_node(ctx: &mut StatementContext, target_id: Option<&str>, col_name: &str) {
        let parent = target_id;
        let col_node_id = generate_column_node_id(parent, col_name);
        ctx.add_node(Node {
            id: col_node_id.clone(),
            node_type: NodeType::Column,
            label: col_name.into(),
            ..Default::default()
        });
        if let Some(tid) = target_id {
            let edge_id = generate_edge_id(tid, &col_node_id);
            if !ctx.edge_ids.contains(&edge_id) {
                ctx.add_edge(Edge {
                    id: edge_id,
                    from: tid.into(),
                    to: col_node_id,
                    edge_type: EdgeType::Ownership,
                    expression: None,
                    operation: None,
                    join_type: None,
                    join_condition: None,
                    metadata: None,
                    approximate: None,
                    statement_ids: Vec::new(),
                });
            }
        }
    }

    /// Extract the normalized column name from an assignment target.
    /// For `SET code = ...` returns "CODE" (Oracle) or "code" (Generic).
    /// For `SET t.code = ...` returns "CODE"/"code" (the last identifier).
    fn extract_assignment_target_name(&self, assignment: &Assignment) -> Option<String> {
        let name = match &assignment.target {
            AssignmentTarget::ColumnName(name) => name,
            AssignmentTarget::Tuple(_) => return None,
        };
        name.0
            .last()
            .and_then(|p| p.as_ident())
            .map(|ident| self.normalize_identifier(&ident.value))
    }

    /// Convert an `ObjectName` (e.g., a column reference like `t.col`) into
    /// an expression and analyze it, registering the column in the lineage graph.
    fn analyze_object_name_as_column(
        expr_analyzer: &mut ExpressionAnalyzer<'_, '_>,
        name: &ObjectName,
    ) {
        let idents: Vec<_> = name
            .0
            .iter()
            .filter_map(|p| p.as_ident().cloned())
            .collect();
        match idents.len() {
            0 => {}
            1 => expr_analyzer.analyze(&Expr::Identifier(idents.into_iter().next().unwrap())),
            _ => expr_analyzer.analyze(&Expr::CompoundIdentifier(idents)),
        }
    }

    pub(super) fn analyze_drop(
        &mut self,
        _ctx: &mut StatementContext,
        object_type: &ast::ObjectType,
        names: &[ObjectName],
    ) {
        // Handle DROP TABLE/VIEW to remove implied schema entries (only if allow_implied is true)
        if self.allow_implied()
            && matches!(object_type, ast::ObjectType::Table | ast::ObjectType::View)
        {
            for name in names {
                let table_name = name.to_string();
                let canonical = self.normalize_table_name(&table_name);

                // Only remove if it's an implied entry (not imported)
                self.schema.remove_implied(&canonical);
                self.tracker.remove(&canonical);
            }
        }
    }

    /// Analyzes a PostgreSQL-style COPY statement for lineage.
    ///
    /// COPY has two forms:
    /// - `COPY table FROM file`: loads data from file into table (table is target)
    /// - `COPY table/query TO file`: exports data from table/query to file (table is source)
    pub(super) fn analyze_copy(
        &mut self,
        ctx: &mut StatementContext,
        source: &CopySource,
        to: bool,
        _target: &CopyTarget,
    ) {
        match source {
            CopySource::Table { table_name, .. } => {
                let name = table_name.to_string();
                let canonical = self.normalize_table_name(&name);
                let node_id = generate_node_id("table", &canonical);
                let label = extract_simple_name(&name);

                ctx.add_node(Node {
                    id: node_id.clone(),
                    node_type: NodeType::Table,
                    label: label.clone().into(),
                    qualified_name: Some(canonical.clone().into()),
                    ..Default::default()
                });
                if let Some(span) = self.locate_relation_name_span(ctx, &name) {
                    ctx.add_name_span(&node_id, span);
                }

                if to {
                    // COPY table TO file: table is source (consumed)
                    self.tracker
                        .record_consumed(&canonical, ctx.statement_index);
                } else {
                    // COPY table FROM file: table is target (produced)
                    self.tracker
                        .record_produced(&canonical, ctx.statement_index);
                }
            }
            CopySource::Query(query) => {
                // COPY (SELECT ...) TO file: analyze query as source
                // Note: COPY with query is always TO (exporting)
                self.analyze_query(ctx, query, None);
            }
        }
    }

    /// Analyzes a Snowflake-style COPY INTO statement for lineage.
    ///
    /// COPY INTO has two forms:
    /// - `COPY INTO table FROM stage/location`: loads data into table (table is target)
    /// - `COPY INTO location FROM table/query`: exports data to location (table/query is source)
    pub(super) fn analyze_copy_into_snowflake(
        &mut self,
        ctx: &mut StatementContext,
        kind: &CopyIntoSnowflakeKind,
        into: &ObjectName,
        from_obj: &Option<ObjectName>,
        from_query: &Option<Box<ast::Query>>,
    ) {
        match kind {
            CopyIntoSnowflakeKind::Table => {
                // COPY INTO table FROM stage: table is target (produced)
                let name = into.to_string();
                let canonical = self.normalize_table_name(&name);
                let target_id = generate_node_id("table", &canonical);
                let label = extract_simple_name(&name);

                ctx.add_node(Node {
                    id: target_id.clone(),
                    node_type: NodeType::Table,
                    label: label.clone().into(),
                    qualified_name: Some(canonical.clone().into()),
                    ..Default::default()
                });
                if let Some(span) = self.locate_relation_name_span(ctx, &name) {
                    ctx.add_name_span(&target_id, span);
                }

                self.tracker
                    .record_produced(&canonical, ctx.statement_index);

                // If there's a source query in the transformation, analyze it
                if let Some(query) = from_query {
                    self.analyze_query(ctx, query, Some(&target_id));
                }
            }
            CopyIntoSnowflakeKind::Location => {
                // COPY INTO location FROM table/query: source is table or query
                if let Some(query) = from_query {
                    // Source is a query
                    self.analyze_query(ctx, query, None);
                } else if let Some(table_name) = from_obj {
                    // Source is a table
                    let name = table_name.to_string();
                    let canonical = self.normalize_table_name(&name);
                    let node_id = generate_node_id("table", &canonical);
                    let label = extract_simple_name(&name);

                    ctx.add_node(Node {
                        id: node_id.clone(),
                        node_type: NodeType::Table,
                        label: label.clone().into(),
                        qualified_name: Some(canonical.clone().into()),
                        ..Default::default()
                    });
                    if let Some(span) = self.locate_relation_name_span(ctx, &name) {
                        ctx.add_name_span(&node_id, span);
                    }

                    self.tracker
                        .record_consumed(&canonical, ctx.statement_index);
                }
            }
        }
    }

    /// Analyzes an ALTER TABLE statement for lineage.
    ///
    /// Currently handles:
    /// - `ALTER TABLE old_name RENAME TO new_name`: Creates dataflow edge from old to new table
    pub(super) fn analyze_alter_table(
        &mut self,
        ctx: &mut StatementContext,
        old_name: &ObjectName,
        operations: &[AlterTableOperation],
    ) {
        for op in operations {
            if let AlterTableOperation::RenameTable { table_name } = op {
                self.analyze_rename_table(ctx, old_name, table_name);
            }
            // Other ALTER TABLE operations could be handled here in the future
        }
    }

    /// Analyzes an ALTER TABLE RENAME statement for lineage.
    ///
    /// Creates nodes for both old and new table names with a dataflow edge
    /// connecting them to represent the rename relationship.
    fn analyze_rename_table(
        &mut self,
        ctx: &mut StatementContext,
        old_name: &ObjectName,
        new_name: &RenameTableNameKind,
    ) {
        // Extract the new table name from the enum
        let new_table_name = match new_name {
            RenameTableNameKind::To(name) | RenameTableNameKind::As(name) => name,
        };

        // Normalize and create nodes for both old and new table names
        let old_name_str = old_name.to_string();
        let old_canonical = self.normalize_table_name(&old_name_str);
        let old_node_id = generate_node_id("table", &old_canonical);

        let new_name_str = new_table_name.to_string();
        let mut inherited_parts = split_qualified_identifiers(&old_name_str);
        let new_parts = split_qualified_identifiers(&new_name_str);
        let new_name_with_schema = if new_parts.len() == 1 && inherited_parts.len() > 1 {
            inherited_parts.pop();
            inherited_parts.push(new_name_str.clone());
            inherited_parts.join(".")
        } else {
            new_name_str.clone()
        };
        let new_canonical = self.normalize_table_name(&new_name_with_schema);
        let new_node_id = generate_node_id("table", &new_canonical);

        // Create node for old table (source of rename)
        let old_label = extract_simple_name(&old_name_str);
        ctx.add_node(Node {
            id: old_node_id.clone(),
            node_type: NodeType::Table,
            label: old_label.clone().into(),
            qualified_name: Some(old_canonical.clone().into()),
            ..Default::default()
        });
        if let Some(span) = self.locate_relation_name_span(ctx, &old_name_str) {
            ctx.add_name_span(&old_node_id, span);
        }

        // Create node for new table (target of rename)
        let new_label = extract_simple_name(&new_name_str);
        ctx.add_node(Node {
            id: new_node_id.clone(),
            node_type: NodeType::Table,
            label: new_label.clone().into(),
            qualified_name: Some(new_canonical.clone().into()),
            ..Default::default()
        });
        if let Some(span) = self.locate_relation_name_span(ctx, &new_name_str) {
            ctx.add_name_span(&new_node_id, span);
        }

        // Create dataflow edge from old to new table
        let edge_id = generate_edge_id(&old_node_id, &new_node_id);
        ctx.add_edge(Edge {
            id: edge_id,
            from: old_node_id,
            to: new_node_id,
            edge_type: EdgeType::DataFlow,
            expression: None,
            operation: Some("RENAME".into()),
            join_type: None,
            join_condition: None,
            metadata: None,
            approximate: None,
            statement_ids: Vec::new(),
        });

        // Track that the old table is consumed and the new table is produced
        self.tracker
            .record_consumed(&old_canonical, ctx.statement_index);
        self.tracker
            .record_produced(&new_canonical, ctx.statement_index);
    }

    /// Analyzes a Redshift-style UNLOAD statement for lineage.
    ///
    /// UNLOAD exports query results to external storage (e.g., S3).
    /// All tables referenced in the query are tracked as sources (consumed).
    ///
    /// Supports two forms:
    /// - `UNLOAD ('SELECT ...') TO 's3://...'` - query as string literal
    /// - `UNLOAD (SELECT ...) TO 's3://...'` - query as parsed expression
    pub(super) fn analyze_unload(
        &mut self,
        ctx: &mut StatementContext,
        query: &Option<Box<ast::Query>>,
        query_text: &Option<String>,
    ) {
        // If we have a parsed query, analyze it directly
        if let Some(ref parsed_query) = query {
            self.analyze_query(ctx, parsed_query, None);
            return;
        }

        // If we have query text (string literal form), parse and analyze it
        if let Some(ref text) = query_text {
            // Parse the query string using the same dialect
            let dialect = self.request.dialect.to_sqlparser_dialect();
            match sqlparser::parser::Parser::parse_sql(dialect.as_ref(), text) {
                Ok(statements) => {
                    for stmt in statements {
                        if let Statement::Query(parsed_query) = stmt {
                            self.analyze_query(ctx, &parsed_query, None);
                        }
                    }
                }
                Err(_) => {
                    // If parsing fails, emit a warning but don't fail the analysis
                    self.issues.push(
                        Issue::warning(
                            issue_codes::PARSE_ERROR,
                            "Could not parse UNLOAD query string for lineage analysis",
                        )
                        .with_statement(ctx.statement_index),
                    );
                }
            }
        }
    }

    /// Checks if the analyzer is running in dbt template mode.
    #[cfg(feature = "templating")]
    pub(super) fn is_dbt_mode(&self) -> bool {
        self.request
            .template_config
            .as_ref()
            .map(|c| c.mode == TemplateMode::Dbt)
            .unwrap_or(false)
    }

    /// Checks if the analyzer is running in dbt template mode.
    #[cfg(not(feature = "templating"))]
    pub(super) fn is_dbt_mode(&self) -> bool {
        false
    }
}

/// Recognized dbt materializations. Adapter-specific values not listed here
/// fall through to `None` in the parser and are treated as the default
/// (physical table) by the caller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum DbtMaterialization {
    Table,
    View,
    Incremental,
    Ephemeral,
    Snapshot,
    MaterializedView,
}

impl DbtMaterialization {
    /// Maps a materialization to the lineage node type that best represents
    /// how downstream queries will observe it. `ephemeral` models are inlined
    /// CTEs with no persisted relation, so they are surfaced as `NodeType::Cte`
    /// instead of fabricating a table/view sink.
    fn node_type(self) -> NodeType {
        match self {
            DbtMaterialization::Table
            | DbtMaterialization::Incremental
            | DbtMaterialization::Snapshot => NodeType::Table,
            DbtMaterialization::View | DbtMaterialization::MaterializedView => NodeType::View,
            DbtMaterialization::Ephemeral => NodeType::Cte,
        }
    }
}

/// Matches a `materialized='value'` kwarg. Value must be a bare identifier
/// (word chars), which fits every real dbt materialization and avoids
/// matching inside arbitrary strings.
static MATERIALIZED_KWARG: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)materialized\s*=\s*(?:'(\w+)'|"(\w+)")"#)
        .expect("materialized kwarg regex is valid")
});

/// Matches the `materialized=` kwarg in any form — literal, Jinja expression,
/// adapter-specific value — so we can distinguish "model set materialized to
/// something we couldn't parse" from "model never configured materialized".
/// Requires a word boundary before `materialized` so substrings like
/// `pre_materialized=` don't count.
static MATERIALIZED_KWARG_PRESENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(^|[^A-Za-z0-9_])materialized\s*=")
        .expect("materialized presence regex is valid")
});

/// Outcome of parsing `config(...)` blocks for the `materialized` kwarg.
///
/// Distinguishes three user-visible states so callers can both pick a sensible
/// default node type and, when relevant, surface a warning to the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum DbtMaterializationDetection {
    /// No `config(...)` block set `materialized=...`. Treat as the default
    /// (physical table) without warning.
    NotConfigured,
    /// `materialized=...` parsed to a known dbt materialization.
    Known(DbtMaterialization),
    /// `materialized=...` was present but couldn't be resolved — a dynamic
    /// Jinja expression, a non-literal value, or an adapter-specific name
    /// outside our known set. Callers should fall back to `Table` and
    /// typically emit a warning so users know lineage may be off.
    Unresolved,
}

impl DbtMaterializationDetection {
    /// Returns the lineage node type implied by a successful detection, or
    /// `None` for the `NotConfigured` / `Unresolved` cases where callers must
    /// fall back to their own default.
    pub(super) fn node_type(self) -> Option<NodeType> {
        match self {
            DbtMaterializationDetection::Known(m) => Some(m.node_type()),
            DbtMaterializationDetection::NotConfigured
            | DbtMaterializationDetection::Unresolved => None,
        }
    }
}

/// Detects the dbt materialization from raw (untemplated) model SQL.
///
/// Scoped to the bodies of `config(...)` calls so the word `materialized`
/// appearing in column names, comments, or string literals elsewhere cannot
/// produce false positives. When multiple `config(...)` calls set
/// `materialized`, the last one wins to match dbt's config override behavior.
pub(super) fn detect_dbt_model_materialization(sql: &str) -> DbtMaterializationDetection {
    // Lowercase once up front so both the config-scanner and the
    // presence-check avoid re-allocating per call. ASCII-only content matches
    // `sql` byte-for-byte, which is fine because `config`, `materialized`,
    // and all known materialization keywords are ASCII.
    let lower = sql.to_ascii_lowercase();
    let mut search_from = 0;
    let mut last_value: Option<String> = None;
    let mut saw_materialized_kwarg = false;

    while let Some((body_range, next_search_from)) =
        find_next_config_call_body(sql, &lower, search_from)
    {
        let body = &sql[body_range.clone()];
        if !saw_materialized_kwarg && MATERIALIZED_KWARG_PRESENT.is_match(body) {
            saw_materialized_kwarg = true;
        }
        if let Some(captures) = MATERIALIZED_KWARG.captures(body) {
            last_value = captures
                .get(1)
                .or_else(|| captures.get(2))
                .map(|m| m.as_str().to_string());
        }
        search_from = next_search_from;
    }

    if let Some(raw) = last_value {
        match raw.to_ascii_lowercase().as_str() {
            "table" => DbtMaterializationDetection::Known(DbtMaterialization::Table),
            "view" => DbtMaterializationDetection::Known(DbtMaterialization::View),
            "incremental" => DbtMaterializationDetection::Known(DbtMaterialization::Incremental),
            "ephemeral" => DbtMaterializationDetection::Known(DbtMaterialization::Ephemeral),
            "snapshot" => DbtMaterializationDetection::Known(DbtMaterialization::Snapshot),
            "materialized_view" => {
                DbtMaterializationDetection::Known(DbtMaterialization::MaterializedView)
            }
            _ => DbtMaterializationDetection::Unresolved,
        }
    } else if saw_materialized_kwarg {
        DbtMaterializationDetection::Unresolved
    } else {
        DbtMaterializationDetection::NotConfigured
    }
}

pub(super) fn dbt_model_relation_type(sql: Option<&str>) -> NodeType {
    match sql.map(detect_dbt_model_materialization) {
        Some(DbtMaterializationDetection::Known(m)) => m.node_type(),
        _ => NodeType::Table,
    }
}

/// Upper bound on paren-match iterations inside a single `config(...)` body.
/// A well-formed dbt model is orders of magnitude below this; the guard
/// exists so pathological input (huge generated files, malicious payloads)
/// can't wedge the parser.
const CONFIG_BODY_SCAN_LIMIT: usize = 1_000_000;

/// Upper bound on nested paren depth inside a `config(...)` body. Real dbt
/// configs rarely exceed single-digit nesting; this rules out stack-style
/// abuse without touching the fast path.
const CONFIG_BODY_MAX_DEPTH: u32 = 256;

/// Returns the byte range (inside `sql`) of the next `config(...)` call's
/// body (between `(` and the matching `)`), plus the byte index to continue
/// searching from.
///
/// Tracks paren depth while skipping over string literals (single and double
/// quoted, with `\` escapes), so nested calls like
/// `config(materialized='view', partition_by=date_trunc('day', x))` resolve
/// correctly. Requires `config` to be a standalone identifier (not a suffix
/// of another word). Returns `None` if no `config(` is found after
/// `search_from`, if the call is unterminated, or if the scan hits the
/// robustness guards ([`CONFIG_BODY_SCAN_LIMIT`] /
/// [`CONFIG_BODY_MAX_DEPTH`]).
///
/// `lower` must be `sql.to_ascii_lowercase()` — passed in so callers that
/// invoke this in a loop only pay the allocation once.
fn find_next_config_call_body(
    sql: &str,
    lower: &str,
    search_from: usize,
) -> Option<(Range<usize>, usize)> {
    debug_assert_eq!(sql.len(), lower.len());
    let bytes = sql.as_bytes();
    let mut search_from = search_from;

    while let Some(rel) = lower[search_from..].find("config") {
        let start = search_from + rel;
        let after_keyword = start + "config".len();

        // Reject `reconfig`, `preconfigure`, etc.
        if start > 0 {
            let prev = bytes[start - 1];
            if prev.is_ascii_alphanumeric() || prev == b'_' {
                search_from = after_keyword;
                continue;
            }
        }

        // Allow whitespace between `config` and `(`.
        let mut cursor = after_keyword;
        while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= bytes.len() || bytes[cursor] != b'(' {
            search_from = after_keyword;
            continue;
        }

        let body_start = cursor + 1;
        let mut depth: u32 = 1;
        let mut quote: Option<u8> = None;
        let mut i = body_start;
        let mut iterations: usize = 0;
        while i < bytes.len() {
            iterations += 1;
            if iterations > CONFIG_BODY_SCAN_LIMIT {
                return None;
            }
            let b = bytes[i];
            if let Some(q) = quote {
                if b == b'\\' && i + 1 < bytes.len() {
                    i += 2;
                    continue;
                }
                if b == q {
                    quote = None;
                }
            } else {
                match b {
                    b'\'' | b'"' => quote = Some(b),
                    b'(' => {
                        depth += 1;
                        if depth > CONFIG_BODY_MAX_DEPTH {
                            return None;
                        }
                    }
                    b')' => {
                        depth -= 1;
                        if depth == 0 {
                            return Some((body_start..i, i + 1));
                        }
                    }
                    _ => {}
                }
            }
            i += 1;
        }
        return None;
    }

    None
}

#[cfg(test)]
mod dbt_materialization_tests {
    use super::{
        detect_dbt_model_materialization, DbtMaterialization, DbtMaterializationDetection,
    };

    fn known(sql: &str) -> Option<DbtMaterialization> {
        match detect_dbt_model_materialization(sql) {
            DbtMaterializationDetection::Known(m) => Some(m),
            _ => None,
        }
    }

    #[test]
    fn matches_single_quoted_view() {
        let sql = "{{ config(materialized='view') }}\nSELECT 1";
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn matches_double_quoted_view() {
        let sql = r#"{{ config(materialized="view") }} SELECT 1"#;
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn tolerates_whitespace_around_tokens() {
        let sql = "{{ config (  materialized   =   'view'  ) }} SELECT 1";
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn handles_nested_parens_in_sibling_kwargs() {
        let sql = "{{ config(materialized='view', partition_by=date_trunc('day', ts)) }} \
                   SELECT 1";
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn recognizes_all_known_materializations() {
        let cases = [
            ("table", DbtMaterialization::Table),
            ("view", DbtMaterialization::View),
            ("incremental", DbtMaterialization::Incremental),
            ("ephemeral", DbtMaterialization::Ephemeral),
            ("snapshot", DbtMaterialization::Snapshot),
            ("materialized_view", DbtMaterialization::MaterializedView),
        ];
        for (keyword, expected) in cases {
            let sql = format!("{{{{ config(materialized='{keyword}') }}}} SELECT 1");
            assert_eq!(
                known(&sql),
                Some(expected),
                "failed for materialization '{keyword}'"
            );
        }
    }

    #[test]
    fn unknown_materialization_returns_unresolved() {
        let sql = "{{ config(materialized='customthing') }} SELECT 1";
        assert_eq!(
            detect_dbt_model_materialization(sql),
            DbtMaterializationDetection::Unresolved
        );
    }

    #[test]
    fn node_type_mapping() {
        use crate::types::NodeType;
        assert_eq!(DbtMaterialization::Table.node_type(), NodeType::Table);
        assert_eq!(DbtMaterialization::Incremental.node_type(), NodeType::Table);
        assert_eq!(DbtMaterialization::Snapshot.node_type(), NodeType::Table);
        assert_eq!(DbtMaterialization::View.node_type(), NodeType::View);
        assert_eq!(DbtMaterialization::Ephemeral.node_type(), NodeType::Cte);
        assert_eq!(
            DbtMaterialization::MaterializedView.node_type(),
            NodeType::View
        );
    }

    #[test]
    fn ignores_materialized_outside_config() {
        let sql = "-- materialized='view'\nSELECT materialized FROM t";
        assert_eq!(
            detect_dbt_model_materialization(sql),
            DbtMaterializationDetection::NotConfigured
        );
    }

    #[test]
    fn ignores_config_substring_of_another_identifier() {
        let sql = "{{ reconfig(materialized='view') }} SELECT 1";
        assert_eq!(
            detect_dbt_model_materialization(sql),
            DbtMaterializationDetection::NotConfigured
        );
    }

    #[test]
    fn unterminated_config_call_returns_not_configured() {
        let sql = "{{ config(materialized='view'";
        assert_eq!(
            detect_dbt_model_materialization(sql),
            DbtMaterializationDetection::NotConfigured
        );
    }

    #[test]
    fn paren_inside_string_does_not_close_config() {
        let sql = r#"{{ config(alias=')', materialized='view') }} SELECT 1"#;
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn case_insensitive_keywords() {
        let sql = "{{ CONFIG(MATERIALIZED='VIEW') }} SELECT 1";
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn returns_not_configured_when_materialized_kwarg_missing() {
        let sql = "{{ config(tags=['daily']) }} SELECT 1";
        assert_eq!(
            detect_dbt_model_materialization(sql),
            DbtMaterializationDetection::NotConfigured
        );
    }

    #[test]
    fn finds_materialized_in_later_config_call() {
        let sql = "{{ config(tags=['daily']) }} {{ config(materialized='view') }} SELECT 1";
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn later_config_call_overrides_earlier_materialized_value() {
        let sql = "{{ config(materialized='table') }} {{ config(materialized='view') }} SELECT 1";
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn escaped_quote_in_earlier_kwarg_does_not_break_parsing() {
        // Single-quoted string with an escaped apostrophe must not swallow the
        // rest of the config body or trip up the kwarg regex that follows.
        let sql = r#"{{ config(alias='don\'t', materialized='view') }} SELECT 1"#;
        assert_eq!(known(sql), Some(DbtMaterialization::View));
    }

    #[test]
    fn escaped_quote_inside_materialized_value_is_unresolved() {
        // Value isn't a bare `\w+`, so the literal regex can't capture it.
        // Presence detector still fires, so we report Unresolved rather than
        // silently defaulting to table.
        let sql = r#"{{ config(materialized='it\'s_a_view') }} SELECT 1"#;
        assert_eq!(
            detect_dbt_model_materialization(sql),
            DbtMaterializationDetection::Unresolved
        );
    }

    #[test]
    fn unknown_adapter_materialization_reports_unresolved_and_defaults_to_table() {
        use super::dbt_model_relation_type;
        use crate::types::NodeType;
        // Custom adapter materializations (e.g., Databricks delta live tables,
        // Snowflake dynamic tables) aren't in our known set. We surface that as
        // `Unresolved` so callers can warn, but still fall back to `Table` for
        // the node type.
        let sql = "{{ config(materialized='dynamic_table') }} SELECT 1";
        assert_eq!(
            detect_dbt_model_materialization(sql),
            DbtMaterializationDetection::Unresolved
        );
        assert_eq!(dbt_model_relation_type(Some(sql)), NodeType::Table);
    }

    #[test]
    fn dynamic_jinja_materialization_reports_unresolved_and_defaults_to_table() {
        use super::dbt_model_relation_type;
        use crate::types::NodeType;
        // A Jinja expression as the value is not a quoted bare identifier.
        // The literal-value regex doesn't match, but the presence regex does,
        // so detection returns `Unresolved` — letting callers warn while the
        // node type falls back to `Table`.
        let sql =
            "{{ config(materialized=('view' if target.name == 'dev' else 'table')) }} SELECT 1";
        assert_eq!(
            detect_dbt_model_materialization(sql),
            DbtMaterializationDetection::Unresolved
        );
        assert_eq!(dbt_model_relation_type(Some(sql)), NodeType::Table);
    }
}

/// Extracts the model name from a dbt source path.
///
/// Given a path like `models/staging/stg_customers.sql`, extracts `stg_customers`.
/// Supports both `.sql` and `.sql.jinja` file extensions used by dbt.
/// This is used to register dbt model outputs for cross-statement linking.
pub(super) fn extract_model_name(path: &str) -> &str {
    // Get the filename from the path
    let filename = path.rsplit('/').next().unwrap_or(path);
    // Also handle Windows-style paths
    let filename = filename.rsplit('\\').next().unwrap_or(filename);
    // Strip the .sql or .sql.jinja extension
    filename
        .strip_suffix(".sql")
        .or_else(|| filename.strip_suffix(".sql.jinja"))
        .unwrap_or(filename)
}
