import type { Node, Edge, AggregationInfo } from '@pondpilot/flowscope-core';
import { JOIN_TYPE_LABELS } from '../constants';

const CREATE_STATEMENT_TYPES = new Set(['CREATE_TABLE', 'CREATE_TABLE_AS', 'CREATE_VIEW']);

/** Node type constant for output nodes. */
export const OUTPUT_NODE_TYPE = 'output' as Node['type'];

/**
 * React Flow node id used for table/view/output relations in the hybrid
 * script-plus-tables graph view. The id is built from the qualified name when
 * available so the same physical table collapses to a single node across
 * statements, falling back to the display label for unqualified references.
 *
 * This is the single source of truth for the scheme. `graphBuilders.ts`,
 * `workers/graphBuilder.worker.ts`, and `utils/revealInGraph.ts` all route
 * through these helpers so any future change to the id format stays consistent.
 *
 * Keys must not contain a colon: the `table:` prefix plus colons in the key
 * would produce ids that collide with other valid keys. DuckDB/Postgres
 * qualified names use dots, so this holds in practice; we assert in dev to
 * catch regressions early (e.g. a future dialect using `schema:table`).
 */
export function hybridTableNodeIdFromKey(key: string): string {
  if (process.env.NODE_ENV !== 'production' && key.includes(':')) {
    throw new Error(`hybridTableNodeIdFromKey: key must not contain ':' (got ${key})`);
  }
  return `table:${key}`;
}

/** Build a hybrid table node id directly from a lineage node's fields. */
export function hybridTableNodeId(node: { qualifiedName?: string | null; label: string }): string {
  return hybridTableNodeIdFromKey(node.qualifiedName || node.label);
}

/** Edge type constant for join dependency edges. */
export const JOIN_DEPENDENCY_EDGE_TYPE = 'join_dependency' as Edge['type'];

const DEFAULT_STATEMENT_SCOPE = 'statement:0';
const STATEMENT_SCOPE_METADATA_KEY = 'statementScope';

/**
 * Returns the node ids for relations created by a statement (e.g. CREATE TABLE/VIEW).
 * For CREATE statements we prefer nodes that receive data_flow edges; when lineage
 * does not include explicit flows (simple CREATE TABLE), we fall back to the sole
 * relation node or one that matches the statement type. dbt bare-SELECT model sinks
 * are also treated as created relations when a table/view owns statement-local
 * projection columns. We identify those columns from the statement's edge shape
 * instead of `qualifiedName` because flattened column nodes may inherit a
 * qualified name from another statement after producer/consumer merging.
 *
 * Operates on a per-statement view of the flat `AnalyzeResult`: pass the statement
 * type together with the nodes and edges that participate in that statement
 * (see `nodesInStatement` / `edgesInStatement`).
 */
export function getCreatedRelationNodeIds(
  statementType: string,
  nodes: Node[],
  edges: Edge[]
): Set<string> {
  const relationNodes = nodes.filter((n) => n.type === 'table' || n.type === 'view');
  const relationNodeIds = new Set(relationNodes.map((n) => n.id));
  const columnNodeIds = new Set(nodes.filter((n) => n.type === 'column').map((node) => node.id));
  const incomingNonOwnershipCounts = new Map<string, number>();
  const outgoingNonOwnershipCounts = new Map<string, number>();

  for (const edge of edges) {
    if (edge.type === 'ownership') {
      continue;
    }

    outgoingNonOwnershipCounts.set(edge.from, (outgoingNonOwnershipCounts.get(edge.from) ?? 0) + 1);
    incomingNonOwnershipCounts.set(edge.to, (incomingNonOwnershipCounts.get(edge.to) ?? 0) + 1);
  }

  const createdNodeIds = new Set<string>();
  for (const edge of edges) {
    // Relation sinks own either projected columns fed by intra-statement flow
    // edges, or isolated columns such as `SELECT 1 AS id` where the projection
    // has no non-ownership edges at all. Source-table columns are only emitted
    // as lineage inputs, so they have outgoing flow edges but no incoming ones.
    if (edge.type === 'ownership' && relationNodeIds.has(edge.from) && columnNodeIds.has(edge.to)) {
      const incoming = incomingNonOwnershipCounts.get(edge.to) ?? 0;
      const outgoing = outgoingNonOwnershipCounts.get(edge.to) ?? 0;
      if (incoming > 0 || (incoming === 0 && outgoing === 0)) {
        createdNodeIds.add(edge.from);
        continue;
      }
    }

    if (edge.type === 'data_flow' && relationNodeIds.has(edge.to)) {
      createdNodeIds.add(edge.to);
    }
  }

  if (createdNodeIds.size > 0) {
    return createdNodeIds;
  }

  if (!CREATE_STATEMENT_TYPES.has(statementType)) {
    return createdNodeIds;
  }

  if (relationNodes.length === 1) {
    createdNodeIds.add(relationNodes[0].id);
    return createdNodeIds;
  }

  // When lineage data does not include flows, fall back to the relation type that matches the statement.
  const targetType = statementType === 'CREATE_VIEW' ? 'view' : 'table';
  const matchingNodes = relationNodes.filter((node) => node.type === targetType);
  if (matchingNodes.length === 1) {
    createdNodeIds.add(matchingNodes[0].id);
  }

  return createdNodeIds;
}

/**
 * Identify output column IDs for SELECT-like statements.
 *
 * Primary source: columns owned by the output node (via ownership edges).
 * Fallback: columns not owned by any table in the column-to-table map.
 */
export function getOutputColumnIds(
  edges: Edge[],
  outputNode: Node | undefined,
  columnNodes: Node[],
  columnToTableMap: Map<string, string>,
  isSelect: boolean
): Set<string> {
  const ids = new Set<string>();
  if (isSelect && outputNode) {
    for (const edge of edges) {
      if (edge.type === 'ownership' && edge.from === outputNode.id) {
        ids.add(edge.to);
      }
    }
  }
  if (isSelect && !outputNode && ids.size === 0) {
    for (const col of columnNodes) {
      if (!columnToTableMap.has(col.id)) {
        ids.add(col.id);
      }
    }
  }
  return ids;
}

/**
 * Build a map from column IDs to their owning table info.
 * @param edges - The edges to search for ownership relationships
 * @param tableNodes - The table/relation nodes to look up
 * @param mapper - Function to extract the desired value from a table node
 */
export function buildColumnOwnershipMap<T>(
  edges: Edge[],
  tableNodes: Node[],
  mapper: (node: Node) => T
): Map<string, T> {
  const result = new Map<string, T>();
  for (const edge of edges) {
    if (edge.type === 'ownership') {
      const tableNode = tableNodes.find((t) => t.id === edge.from);
      if (tableNode) {
        result.set(edge.to, mapper(tableNode));
      }
    }
  }
  return result;
}

function isRelationType(type: Node['type']): boolean {
  return type === 'table' || type === 'view' || type === 'cte' || type === OUTPUT_NODE_TYPE;
}

function resolveRelationNodeId(
  nodeId: string,
  nodeById: Map<string, Node>,
  ownedNodeToRelationId: Map<string, string>
): string | undefined {
  const node = nodeById.get(nodeId);
  if (node && isRelationType(node.type)) {
    return node.id;
  }

  return ownedNodeToRelationId.get(nodeId);
}

/**
 * Collect the set of table node IDs that were introduced via JOIN.
 *
 * A table is considered "joined" if any edge carrying `joinType` resolves back to
 * that relation as its source owner. Tables not in the returned set are "base" tables.
 */
export function buildJoinedTableIds(edges: Edge[], nodes: Node[]): Set<string> {
  const nodeById = new Map(nodes.map((node) => [node.id, node]));
  const ownedNodeToRelationId = new Map<string, string>();

  for (const edge of edges) {
    if (edge.type !== 'ownership') {
      continue;
    }

    const owner = nodeById.get(edge.from);
    if (owner && isRelationType(owner.type)) {
      ownedNodeToRelationId.set(edge.to, owner.id);
    }
  }

  const ids = new Set<string>();
  for (const edge of edges) {
    if (edge.joinType) {
      const sourceRelationId = resolveRelationNodeId(edge.from, nodeById, ownedNodeToRelationId);
      if (sourceRelationId) {
        ids.add(sourceRelationId);
      }
    }
  }
  return ids;
}

/**
 * Format a join type string for display as an edge label.
 * Uses the JOIN_TYPE_LABELS mapping for human-readable labels.
 */
export function formatJoinType(joinType: string | undefined | null): string | undefined {
  if (!joinType) return undefined;
  return JOIN_TYPE_LABELS[joinType] || joinType.replace(/_/g, ' ');
}

/**
 * Determine if a node should be highlighted based on search term.
 * Checks both node label and column names for matches.
 */
export function isNodeHighlighted(
  searchTerm: string,
  columns: { name: string }[],
  nodeLabel?: string
): boolean {
  if (!searchTerm) {
    return false;
  }
  const lowerSearch = searchTerm.toLowerCase();
  const labelMatch = !!nodeLabel && nodeLabel.toLowerCase().includes(lowerSearch);
  const columnMatch = columns.some((col) => col.name.toLowerCase().includes(lowerSearch));
  return labelMatch || columnMatch;
}

/** Minimal column info returned by output column grouping. */
export interface OutputColumnInfo {
  id: string;
  name: string;
  expression?: string;
  aggregation?: AggregationInfo;
}

/**
 * Create a collision-safe key for a directed pair of node IDs.
 * Uses a null separator so IDs containing any printable substring cannot collide.
 *
 * Node IDs must not contain null bytes; this is validated in development builds.
 */
export function edgePairKey(sourceId: string, targetId: string): string {
  if (process.env.NODE_ENV !== 'production') {
    if (sourceId.includes('\0') || targetId.includes('\0')) {
      throw new Error('Node IDs must not contain null bytes');
    }
  }
  return `${sourceId}\0${targetId}`;
}

/**
 * Create a collision-safe React Flow edge ID for synthetic relation-level edges.
 */
export function syntheticEdgeId(kind: string, sourceId: string, targetId: string): string {
  return ['edge', kind, sourceId, targetId].map((part) => encodeURIComponent(part)).join('/');
}

/**
 * Create a stable per-statement scope key that survives statement merging.
 */
export function createStatementScope(statementIndex: number, sourceName?: string): string {
  return sourceName ? `${sourceName}#${statementIndex}` : `statement:${statementIndex}`;
}

/**
 * Attach merged-statement scope metadata to a node or edge.
 */
export function withStatementScope<T extends Node | Edge>(entity: T, scope: string): T {
  if (entity.metadata?.[STATEMENT_SCOPE_METADATA_KEY] === scope) {
    return entity;
  }

  return {
    ...entity,
    metadata: {
      ...(entity.metadata || {}),
      [STATEMENT_SCOPE_METADATA_KEY]: scope,
    },
  };
}

function getStatementScope(entity: Pick<Node, 'metadata'> | Pick<Edge, 'metadata'>): string {
  const scope = entity.metadata?.[STATEMENT_SCOPE_METADATA_KEY];
  return typeof scope === 'string' ? scope : DEFAULT_STATEMENT_SCOPE;
}

interface ResolvedOutputOwnership {
  columnToOutputNodeMap: Map<string, string>;
  outputNodeIds: Set<string>;
  outputColumnIds: Set<string>;
}

function resolveOutputOwnership(
  outputNodes: Node[],
  edges: Edge[],
  columnNodes: Node[],
  relationOwnedColumnIds: Set<string>,
  isSelect: boolean,
  virtualOutputNodeId: string
): ResolvedOutputOwnership {
  const explicitOutputNodeIds = new Set(outputNodes.map((node) => node.id));
  const explicitOutputScopes = new Set(outputNodes.map((node) => getStatementScope(node)));
  const explicitOwnerIds = new Map<string, string>();
  const columnToOutputNodeMap = new Map<string, string>();

  for (const edge of edges) {
    if (edge.type === 'ownership' && explicitOutputNodeIds.has(edge.from)) {
      explicitOwnerIds.set(edge.to, edge.from);
    }
  }

  for (const col of columnNodes) {
    const explicitOwnerId = explicitOwnerIds.get(col.id);
    if (explicitOwnerId) {
      columnToOutputNodeMap.set(col.id, explicitOwnerId);
      continue;
    }

    if (!isSelect || col.qualifiedName || relationOwnedColumnIds.has(col.id)) {
      continue;
    }

    if (explicitOutputScopes.has(getStatementScope(col))) {
      continue;
    }

    columnToOutputNodeMap.set(col.id, virtualOutputNodeId);
  }

  const outputNodeIds = new Set(explicitOutputNodeIds);
  const outputColumnIds = new Set<string>();

  for (const col of columnNodes) {
    const outputOwnerId = columnToOutputNodeMap.get(col.id);
    if (!outputOwnerId) {
      continue;
    }

    outputColumnIds.add(col.id);
    if (outputOwnerId === virtualOutputNodeId) {
      outputNodeIds.add(virtualOutputNodeId);
    }
  }

  return { columnToOutputNodeMap, outputNodeIds, outputColumnIds };
}

/**
 * Group columns by their output owner node ID.
 *
 * Columns explicitly owned by output nodes (via ownership edges) are assigned to those nodes.
 * Unowned projected columns (no qualifiedName, not owned by any table) fall back to the
 * virtual output node.
 */
export function groupOutputColumns(
  outputNodes: Node[],
  edges: Edge[],
  columnNodes: Node[],
  ownedColumnIds: Set<string>,
  isSelect: boolean,
  virtualOutputNodeId: string
): Map<string, OutputColumnInfo[]> {
  const result = new Map<string, OutputColumnInfo[]>();
  const { columnToOutputNodeMap } = resolveOutputOwnership(
    outputNodes,
    edges,
    columnNodes,
    ownedColumnIds,
    isSelect,
    virtualOutputNodeId
  );

  for (const col of columnNodes) {
    const outputOwnerId = columnToOutputNodeMap.get(col.id);
    if (!outputOwnerId) continue;

    let columns = result.get(outputOwnerId);
    if (!columns) {
      columns = [];
      result.set(outputOwnerId, columns);
    }
    columns.push({
      id: col.id,
      name: col.label,
      expression: col.expression,
      aggregation: col.aggregation,
    });
  }

  return result;
}

/**
 * Resolve the full output mapping for edge building.
 *
 * Augments `columnToTableMap` in place with output node ownership, then returns
 * the set of active output node IDs and the set of output column IDs.
 */
export function resolveOutputMapping(
  edges: Edge[],
  outputNodes: Node[],
  columnNodes: Node[],
  columnToTableMap: Map<string, string>,
  isSelect: boolean,
  virtualOutputNodeId: string
): { outputNodeIds: Set<string>; outputColumnIds: Set<string> } {
  const relationOwnedColumnIds = new Set(columnToTableMap.keys());
  const { columnToOutputNodeMap, outputNodeIds, outputColumnIds } = resolveOutputOwnership(
    outputNodes,
    edges,
    columnNodes,
    relationOwnedColumnIds,
    isSelect,
    virtualOutputNodeId
  );

  for (const [columnId, outputNodeId] of columnToOutputNodeMap) {
    columnToTableMap.set(columnId, outputNodeId);
  }

  return { outputNodeIds, outputColumnIds };
}
