import type { AnalyzeResult, Edge, Node, Span, StatementMeta } from '@pondpilot/flowscope-core';

import { OUTPUT_NODE_TYPE } from './lineageHelpers';
import { mergeNodesForNavigation, resolveNodeSourceName } from './nodeOccurrences';

/**
 * Kind of span an index entry refers to.
 *
 * - `'name'` — a `nameSpan` (the identifier occurrence for a table/CTE/column).
 * - `'body'` — a `bodySpan` (the parenthesised body of a CTE definition).
 *
 * Name matches take precedence over body matches at lookup time: placing the
 * cursor on a CTE name inside its own definition should focus that CTE node,
 * not the enclosing one.
 */
export type SpanIndexEntryKind = 'name' | 'body';

/**
 * A single entry in the reveal-in-graph span index.
 *
 * One node may contribute multiple entries (e.g. a CTE referenced several
 * times yields one entry per `nameSpan`, plus one entry per `bodySpan`).
 */
export interface SpanIndexEntry {
  /** ID of the lineage node this span belongs to. */
  nodeId: string;
  /** Byte-offset span (analyzer coordinates). */
  span: Span;
  /** Whether this span is a name occurrence or a CTE body. */
  kind: SpanIndexEntryKind;
  /** Width of the span (end - start). Precomputed for tie-breaking. */
  size: number;
}

export interface SpanIndex {
  entries: SpanIndexEntry[];
}

export interface RevealLookupNode {
  id: string;
  type: Node['type'];
  label: string;
  qualifiedName?: string;
}

export interface RevealLookup {
  nodesById: Map<string, RevealLookupNode>;
  ownerRelationIdByNodeId: Map<string, string>;
}

export interface ResolveRevealGraphTargetOptions {
  viewMode: 'script' | 'table';
  showColumnEdges: boolean;
  showScriptTables: boolean;
  visibleNodeIds?: ReadonlySet<string>;
}

const EMPTY_INDEX: SpanIndex = { entries: [] };
const EMPTY_LOOKUP: RevealLookup = {
  nodesById: new Map(),
  ownerRelationIdByNodeId: new Map(),
};

function isRelationType(type: Node['type']): boolean {
  return type === 'table' || type === 'view' || type === 'cte' || type === OUTPUT_NODE_TYPE;
}

function buildMergedNodeMap(result: AnalyzeResult): Map<string, Node> {
  const statementById = new Map<number, Pick<StatementMeta, 'sourceName'>>(
    result.statements.map((statement) => [statement.statementIndex, statement])
  );
  const mergedNodes = new Map<string, Node>();

  for (const rawNode of result.nodes) {
    const sourceName = resolveNodeSourceName(rawNode, statementById);
    const merged = mergeNodesForNavigation(mergedNodes.get(rawNode.id) ?? null, rawNode, sourceName);
    mergedNodes.set(rawNode.id, merged);
  }

  return mergedNodes;
}

function buildOwnerRelationMap(edges: Edge[], mergedNodes: Map<string, Node>): Map<string, string> {
  const ownerRelationIdByNodeId = new Map<string, string>();

  for (const edge of edges) {
    if (edge.type !== 'ownership') continue;
    const owner = mergedNodes.get(edge.from);
    if (owner && isRelationType(owner.type)) {
      ownerRelationIdByNodeId.set(edge.to, owner.id);
    }
  }

  return ownerRelationIdByNodeId;
}

function pushEntries(
  target: SpanIndexEntry[],
  nodeId: string,
  spans: Span[] | undefined,
  kind: SpanIndexEntryKind
): void {
  if (!spans || spans.length === 0) return;
  for (const span of spans) {
    if (!span) continue;
    const size = span.end - span.start;
    if (size <= 0) continue;
    target.push({ nodeId, span, kind, size });
  }
}

/**
 * Build an interval index of every known `nameSpan` and `bodySpan` across the
 * flat node list. Called once per analysis result; the result is cheap to hold
 * in memo state.
 *
 * Nodes are merged in a single pass so shared nodes (referenced across
 * multiple statements) contribute every occurrence exactly once without the
 * previous per-id rescans over `result.nodes`.
 */
export function buildSpanIndex(result: AnalyzeResult | null): SpanIndex {
  if (!result || !result.nodes || result.nodes.length === 0) {
    return EMPTY_INDEX;
  }

  const mergedNodes = buildMergedNodeMap(result);
  const entries: SpanIndexEntry[] = [];

  for (const node of mergedNodes.values()) {
    pushEntries(entries, node.id, node.nameSpans, 'name');
    if (node.bodySpan) {
      pushEntries(entries, node.id, [node.bodySpan], 'body');
    }
  }

  return { entries };
}

/**
 * Look up the node whose span best contains `byteOffset`.
 *
 * Returns `null` when the cursor is in whitespace or otherwise outside every
 * indexed span. Spans are treated as half-open `[start, end)`. Name matches
 * beat body matches; within a kind, the smallest containing span wins.
 */
export function findNodeAtByteOffset(index: SpanIndex, byteOffset: number): SpanIndexEntry | null {
  let bestName: SpanIndexEntry | null = null;
  let bestBody: SpanIndexEntry | null = null;

  for (const entry of index.entries) {
    if (byteOffset < entry.span.start || byteOffset >= entry.span.end) continue;
    if (entry.kind === 'name') {
      if (!bestName || entry.size < bestName.size) bestName = entry;
    } else if (!bestBody || entry.size < bestBody.size) {
      bestBody = entry;
    }
  }

  return bestName ?? bestBody;
}

/**
 * Build the node/ownership lookup needed to map span hits to actual rendered
 * graph node ids in the current view.
 */
export function buildRevealLookup(result: AnalyzeResult | null): RevealLookup {
  if (!result || !result.nodes || result.nodes.length === 0) {
    return EMPTY_LOOKUP;
  }

  const mergedNodes = buildMergedNodeMap(result);
  const ownerRelationIdByNodeId = buildOwnerRelationMap(result.edges, mergedNodes);
  const nodesById = new Map<string, RevealLookupNode>();

  for (const node of mergedNodes.values()) {
    nodesById.set(node.id, {
      id: node.id,
      type: node.type,
      label: node.label,
      qualifiedName: node.qualifiedName,
    });
  }

  return { nodesById, ownerRelationIdByNodeId };
}

function toHybridGraphId(node: RevealLookupNode): string | null {
  if (node.type !== 'table' && node.type !== 'view' && node.type !== OUTPUT_NODE_TYPE) {
    return null;
  }

  return `table:${node.qualifiedName || node.label}`;
}

/**
 * Resolve a lineage node hit to the actual React Flow node id that is rendered
 * in the current graph mode. Returns null when the target is not visible in the
 * active graph representation.
 */
export function resolveRevealGraphTarget(
  lookup: RevealLookup,
  nodeId: string,
  options: ResolveRevealGraphTargetOptions
): string | null {
  const baseNode = lookup.nodesById.get(nodeId);
  if (!baseNode) {
    return null;
  }

  const relationNode =
    baseNode.type === 'column'
      ? lookup.nodesById.get(lookup.ownerRelationIdByNodeId.get(baseNode.id) ?? '') ?? null
      : baseNode;

  if (!relationNode) {
    return null;
  }

  let targetId: string | null = null;
  if (options.viewMode === 'table') {
    targetId = relationNode.id;
  } else if (options.showScriptTables) {
    targetId = toHybridGraphId(relationNode);
  }

  if (!targetId) {
    return null;
  }

  if (options.visibleNodeIds && !options.visibleNodeIds.has(targetId)) {
    return null;
  }

  return targetId;
}
