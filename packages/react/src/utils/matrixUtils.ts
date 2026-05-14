/**
 * Matrix view utilities for extracting table and script dependencies.
 * These functions analyze lineage data to build dependency matrices.
 */

import type { AnalyzeResult, Span } from '@pondpilot/flowscope-core';
import { isTableLikeType, nodesInStatement, edgesInStatement } from '@pondpilot/flowscope-core';
import {
  getCreatedRelationNodeIds,
  OUTPUT_NODE_TYPE,
  JOIN_DEPENDENCY_EDGE_TYPE,
  buildColumnOwnershipMap,
  isScriptRelationNode,
} from './lineageHelpers';
import { getOccurrenceForStatement } from './nodeOccurrences';

// ============================================================================
// Types
// ============================================================================

export interface TableDependencyWithDetails {
  sourceTable: string;
  targetTable: string;
  columnCount: number;
  columns: Array<{ source: string; target: string; expression?: string }>;
  spans: Span[];
  locations: Array<{ span: Span; sourceName?: string; statementIndex: number }>;
  /**
   * Synthetic dependency reconstructed via transitive closure when CTE rows/columns
   * are hidden in the matrix. Set by `collapseCteFromMatrix`; never produced by the
   * primary extraction path. UI uses this to render a subtler arrow or tooltip note.
   */
  indirect?: boolean;
  /**
   * When `indirect === true`, lists the CTE hops (qualified names or labels) that the
   * physical-to-physical dependency was rebuilt through. Empty/undefined when direct.
   */
  viaCtes?: string[];
}

export interface ScriptDependency {
  sourceScript: string;
  targetScript: string;
  sharedTables: string[];
}

export interface MatrixCellData {
  type: 'self' | 'write' | 'read' | 'none';
  details?: TableDependencyWithDetails | ScriptDependency;
}

export interface MatrixData {
  items: string[];
  cells: Map<string, Map<string, MatrixCellData>>;
}

/**
 * Aggregated per-row / per-column statistics for a matrix. Drives complexity
 * margins (Fan-In/Fan-Out bars), heatmap intensity normalization, and clustering.
 *
 * Computed by `computeMatrixMetrics` — the single source of truth shared by
 * the matrix Web Worker (initial build) and the main thread (post-CTE-collapse
 * recomputation). Do NOT duplicate this logic in another location.
 */
export interface MatrixMetrics {
  rowCounts: Map<string, number>;
  colCounts: Map<string, number>;
  maxRow: number;
  maxCol: number;
  maxIntensity: number;
}

/**
 * Computes row/col degree and heatmap intensity bounds for a matrix.
 *
 * Iterates `matrix.cells` once: every `write` cell increments `rowCounts[row]`
 * and `colCounts[col]`; non-self/non-none cells contribute to `maxIntensity`
 * (column count for tables, shared-table count for scripts).
 *
 * Used by both `matrix.worker.ts` (initial build) and `MatrixView` after a
 * CTE collapse rewrites the cell graph in place.
 */
export function computeMatrixMetrics(
  matrix: MatrixData,
  mode: 'tables' | 'scripts'
): MatrixMetrics {
  const rowCounts = new Map<string, number>();
  const colCounts = new Map<string, number>();
  let maxRow = 0;
  let maxCol = 0;
  let maxIntensity = 1;

  for (const item of matrix.items) {
    rowCounts.set(item, 0);
    colCounts.set(item, 0);
  }

  for (const [rowId, rowCells] of matrix.cells) {
    for (const [colId, cell] of rowCells) {
      if (cell.type === 'write') {
        const rowCount = (rowCounts.get(rowId) || 0) + 1;
        rowCounts.set(rowId, rowCount);
        maxRow = Math.max(maxRow, rowCount);

        const colCount = (colCounts.get(colId) || 0) + 1;
        colCounts.set(colId, colCount);
        maxCol = Math.max(maxCol, colCount);
      }

      if (cell.type !== 'none' && cell.type !== 'self') {
        let intensity = 0;
        if (mode === 'tables') {
          intensity = (cell.details as { columnCount?: number } | undefined)?.columnCount || 0;
        } else {
          intensity =
            (cell.details as { sharedTables?: string[] } | undefined)?.sharedTables?.length || 0;
        }
        if (intensity > maxIntensity) {
          maxIntensity = intensity;
        }
      }
    }
  }

  return { rowCounts, colCounts, maxRow, maxCol, maxIntensity };
}

// ============================================================================
// Data Extraction
// ============================================================================

/**
 * Extracts all unique column names from the lineage graph.
 * Used for search autocomplete.
 */
export function extractAllColumnNames(result: AnalyzeResult): string[] {
  const columnNames = new Set<string>();
  for (const node of result.nodes) {
    if (node.type === 'column') {
      columnNames.add(node.label);
    }
  }
  return Array.from(columnNames).sort();
}

/**
 * Extracts table-to-table dependencies with column-level details from lineage statements.
 * Tracks which columns flow between tables and captures source spans for navigation.
 */
export function extractTableDependenciesWithDetails(
  result: AnalyzeResult
): TableDependencyWithDetails[] {
  const depMap = new Map<string, TableDependencyWithDetails>();

  for (const stmt of result.statements) {
    const stmtNodes = nodesInStatement(result, stmt.statementIndex);
    const stmtEdges = edgesInStatement(result, stmt.statementIndex);
    const tableNodes = stmtNodes.filter((n) => isTableLikeType(n.type));
    const outputNodes = stmtNodes.filter((n) => n.type === OUTPUT_NODE_TYPE);
    const relationNodes = [...tableNodes, ...outputNodes];
    const columnNodes = stmtNodes.filter((n) => n.type === 'column');

    const columnToTable = buildColumnOwnershipMap(
      stmtEdges,
      relationNodes,
      (n) => n.qualifiedName || n.label
    );

    for (const edge of stmtEdges) {
      if (edge.type === 'data_flow' || edge.type === JOIN_DEPENDENCY_EDGE_TYPE) {
        const sourceNode = relationNodes.find((n) => n.id === edge.from);
        const targetNode = relationNodes.find((n) => n.id === edge.to);

        if (sourceNode && targetNode) {
          const sourceKey = sourceNode.qualifiedName || sourceNode.label;
          const targetKey = targetNode.qualifiedName || targetNode.label;
          const depKey = `${sourceKey}->${targetKey}`;

          if (sourceKey !== targetKey) {
            if (!depMap.has(depKey)) {
              depMap.set(depKey, {
                sourceTable: sourceKey,
                targetTable: targetKey,
                columnCount: 0,
                columns: [],
                spans: [],
                locations: [],
              });
            }
            const dep = depMap.get(depKey)!;
            const occurrences = getOccurrenceForStatement(sourceNode, stmt.statementIndex);
            if (occurrences.spans.length > 0) {
              occurrences.spans.forEach((span, index) => {
                dep.spans.push(span);
                dep.locations.push({
                  span,
                  sourceName: occurrences.sourceNames[index] ?? undefined,
                  statementIndex: stmt.statementIndex,
                });
              });
            } else if (sourceNode.span) {
              dep.spans.push(sourceNode.span);
              dep.locations.push({ span: sourceNode.span, statementIndex: stmt.statementIndex });
            }
          }
        }
      }

      if (edge.type === 'derivation' || edge.type === 'data_flow') {
        const sourceCol = columnNodes.find((c) => c.id === edge.from);
        const targetCol = columnNodes.find((c) => c.id === edge.to);

        if (sourceCol && targetCol) {
          const sourceTable = columnToTable.get(edge.from);
          const targetTable = columnToTable.get(edge.to);

          if (sourceTable && targetTable && sourceTable !== targetTable) {
            const depKey = `${sourceTable}->${targetTable}`;
            if (!depMap.has(depKey)) {
              depMap.set(depKey, {
                sourceTable,
                targetTable,
                columnCount: 0,
                columns: [],
                spans: [],
                locations: [],
              });
            }
            const dep = depMap.get(depKey)!;
            dep.columnCount++;
            dep.columns.push({
              source: sourceCol.label,
              target: targetCol.label,
              expression: edge.expression || targetCol.expression,
            });
          }
        }
      }
    }
  }

  return Array.from(depMap.values());
}

export interface ScriptDependencyResult {
  dependencies: ScriptDependency[];
  allScripts: string[];
}

/**
 * Extracts script-to-script dependencies based on shared tables.
 * A dependency exists when one script writes to a table that another script reads.
 * Returns both dependencies and all script names (for showing scripts with no dependencies).
 */
export function extractScriptDependencies(result: AnalyzeResult): ScriptDependencyResult {
  const scriptMap = new Map<string, { tablesRead: Set<string>; tablesWritten: Set<string> }>();

  for (const stmt of result.statements) {
    const sourceName = stmt.sourceName || 'default';
    if (!scriptMap.has(sourceName)) {
      scriptMap.set(sourceName, { tablesRead: new Set(), tablesWritten: new Set() });
    }
    const scriptData = scriptMap.get(sourceName)!;

    const stmtNodes = nodesInStatement(result, stmt.statementIndex);
    const stmtEdges = edgesInStatement(result, stmt.statementIndex);
    const tableNodes = stmtNodes.filter(isScriptRelationNode);
    const outputNodes = stmtNodes.filter((n) => n.type === OUTPUT_NODE_TYPE);
    const createdRelationIds = getCreatedRelationNodeIds(stmt.statementType, stmtNodes, stmtEdges);

    for (const node of outputNodes) {
      scriptData.tablesWritten.add(node.qualifiedName || node.label);
    }

    for (const node of tableNodes) {
      const tableName = node.qualifiedName || node.label;
      const isWritten =
        stmtEdges.some((e) => e.to === node.id && e.type === 'data_flow') ||
        createdRelationIds.has(node.id);
      const isRead = stmtEdges.some((e) => e.from === node.id && e.type === 'data_flow');

      if (isWritten) {
        scriptData.tablesWritten.add(tableName);
      }
      if (isRead || (!isWritten && !isRead)) {
        scriptData.tablesRead.add(tableName);
      }
    }
  }

  const dependencies: ScriptDependency[] = [];
  const allScripts = Array.from(scriptMap.keys());

  for (const producerScript of allScripts) {
    const producer = scriptMap.get(producerScript)!;
    for (const consumerScript of allScripts) {
      if (producerScript === consumerScript) continue;
      const consumer = scriptMap.get(consumerScript)!;

      const sharedTables = Array.from(producer.tablesWritten).filter((t) =>
        consumer.tablesRead.has(t)
      );

      if (sharedTables.length > 0) {
        dependencies.push({
          sourceScript: producerScript,
          targetScript: consumerScript,
          sharedTables,
        });
      }
    }
  }

  return { dependencies, allScripts };
}

// ============================================================================
// Matrix Building
// ============================================================================

/**
 * Builds a matrix data structure from table dependencies.
 */
export function buildTableMatrix(dependencies: TableDependencyWithDetails[]): MatrixData {
  const allTables = new Set<string>();
  for (const dep of dependencies) {
    allTables.add(dep.sourceTable);
    allTables.add(dep.targetTable);
  }
  const items = Array.from(allTables).sort();

  const depLookup = new Map<string, TableDependencyWithDetails>();
  for (const dep of dependencies) {
    depLookup.set(`${dep.sourceTable}->${dep.targetTable}`, dep);
  }

  const cells = new Map<string, Map<string, MatrixCellData>>();
  for (const rowItem of items) {
    const row = new Map<string, MatrixCellData>();
    for (const colItem of items) {
      if (rowItem === colItem) {
        row.set(colItem, { type: 'self' });
      } else {
        const writeKey = `${rowItem}->${colItem}`;
        const readKey = `${colItem}->${rowItem}`;

        if (depLookup.has(writeKey)) {
          row.set(colItem, { type: 'write', details: depLookup.get(writeKey) });
        } else if (depLookup.has(readKey)) {
          row.set(colItem, { type: 'read', details: depLookup.get(readKey) });
        } else {
          row.set(colItem, { type: 'none' });
        }
      }
    }
    cells.set(rowItem, row);
  }

  return { items, cells };
}

/**
 * Returns the matrix-key (qualifiedName or label) for every CTE node in the result.
 * Matrix items use the same `qualifiedName || label` convention as
 * `extractTableDependenciesWithDetails`, so this set can be intersected directly
 * with `MatrixData.items`.
 */
export function extractCteItemKeys(result: AnalyzeResult): Set<string> {
  const keys = new Set<string>();
  for (const node of result.nodes) {
    if (node.type === 'cte') {
      keys.add(node.qualifiedName || node.label);
    }
  }
  return keys;
}

/**
 * Removes CTE rows/columns from a table matrix and reconstructs physical-to-physical
 * dependencies that previously only existed via CTE chains.
 *
 * Algorithm:
 *  1. Filter `items` to drop CTE keys.
 *  2. For each remaining physical item `A`, BFS forward through the original `cells`,
 *     traversing only `write` edges. Whenever we land on another physical item `B`
 *     via at least one CTE hop AND there is no direct edge `A→B` already, emit a
 *     synthetic dependency carrying `indirect: true` and the CTE path in `viaCtes`.
 *  3. Rebuild a fresh `MatrixData` containing direct edges (preserved as-is) plus
 *     synthetic indirect ones.
 *
 * Returns a new MatrixData; the input is not mutated.
 */
export function collapseCteFromMatrix(matrix: MatrixData, cteSet: Set<string>): MatrixData {
  if (cteSet.size === 0) return matrix;

  const physicalItems = matrix.items.filter((item) => !cteSet.has(item));
  const physicalSet = new Set(physicalItems);

  const directWrite = new Map<string, Map<string, MatrixCellData>>();
  for (const [rowItem, rowCells] of matrix.cells) {
    if (!physicalSet.has(rowItem)) continue;
    const filteredRow = new Map<string, MatrixCellData>();
    for (const [colItem, cell] of rowCells) {
      if (!physicalSet.has(colItem)) continue;
      filteredRow.set(colItem, cell);
    }
    directWrite.set(rowItem, filteredRow);
  }

  const indirectWrites = new Map<string, Map<string, { viaCtes: string[]; sample?: MatrixCellData }>>();

  for (const startNode of physicalItems) {
    const visited = new Set<string>();
    visited.add(startNode);
    type Frontier = { node: string; path: string[]; firstEdge?: MatrixCellData };
    const queue: Frontier[] = [{ node: startNode, path: [], firstEdge: undefined }];

    while (queue.length > 0) {
      const { node, path, firstEdge } = queue.shift()!;
      const rowCells = matrix.cells.get(node);
      if (!rowCells) continue;

      for (const [target, cell] of rowCells) {
        if (cell.type !== 'write') continue;
        if (visited.has(target)) continue;
        visited.add(target);

        const isCte = cteSet.has(target);

        if (!isCte) {
          if (path.length === 0) continue;
          if (target === startNode) continue;

          const directRow = directWrite.get(startNode);
          const existing = directRow?.get(target);
          if (existing && (existing.type === 'write' || existing.type === 'read')) continue;

          let bucket = indirectWrites.get(startNode);
          if (!bucket) {
            bucket = new Map();
            indirectWrites.set(startNode, bucket);
          }
          if (!bucket.has(target)) {
            bucket.set(target, { viaCtes: [...path], sample: firstEdge ?? cell });
          }
          continue;
        }

        queue.push({
          node: target,
          path: [...path, target],
          firstEdge: firstEdge ?? cell,
        });
      }
    }
  }

  const cells = new Map<string, Map<string, MatrixCellData>>();
  for (const rowItem of physicalItems) {
    const row = new Map<string, MatrixCellData>();
    const directRow = directWrite.get(rowItem) ?? new Map<string, MatrixCellData>();
    const bucket = indirectWrites.get(rowItem);

    for (const colItem of physicalItems) {
      if (rowItem === colItem) {
        row.set(colItem, { type: 'self' });
        continue;
      }

      const directCell = directRow.get(colItem);
      if (directCell && directCell.type !== 'none') {
        row.set(colItem, directCell);
        continue;
      }

      const indirect = bucket?.get(colItem);
      if (indirect) {
        const baseDetails = indirect.sample?.details as TableDependencyWithDetails | undefined;
        const syntheticDetails: TableDependencyWithDetails = {
          sourceTable: rowItem,
          targetTable: colItem,
          columnCount: baseDetails?.columnCount ?? 0,
          columns: baseDetails?.columns ?? [],
          spans: baseDetails?.spans ?? [],
          locations: baseDetails?.locations ?? [],
          indirect: true,
          viaCtes: indirect.viaCtes,
        };
        row.set(colItem, { type: 'write', details: syntheticDetails });
        continue;
      }

      const reverseDirect = directWrite.get(colItem)?.get(rowItem);
      if (reverseDirect && reverseDirect.type === 'write') {
        row.set(colItem, { type: 'read', details: reverseDirect.details });
        continue;
      }

      const reverseIndirect = indirectWrites.get(colItem)?.get(rowItem);
      if (reverseIndirect) {
        const baseDetails = reverseIndirect.sample?.details as
          | TableDependencyWithDetails
          | undefined;
        const syntheticDetails: TableDependencyWithDetails = {
          sourceTable: colItem,
          targetTable: rowItem,
          columnCount: baseDetails?.columnCount ?? 0,
          columns: baseDetails?.columns ?? [],
          spans: baseDetails?.spans ?? [],
          locations: baseDetails?.locations ?? [],
          indirect: true,
          viaCtes: reverseIndirect.viaCtes,
        };
        row.set(colItem, { type: 'read', details: syntheticDetails });
        continue;
      }

      row.set(colItem, { type: 'none' });
    }
    cells.set(rowItem, row);
  }

  return { items: physicalItems, cells };
}

/**
 * Builds a matrix data structure from script dependencies.
 * Takes allScripts to include scripts with no dependencies in the matrix.
 */
export function buildScriptMatrix(
  dependencies: ScriptDependency[],
  allScripts: string[]
): MatrixData {
  const items = [...allScripts].sort();

  const depLookup = new Map<string, ScriptDependency>();
  for (const dep of dependencies) {
    depLookup.set(`${dep.sourceScript}->${dep.targetScript}`, dep);
  }

  const cells = new Map<string, Map<string, MatrixCellData>>();
  for (const rowItem of items) {
    const row = new Map<string, MatrixCellData>();
    for (const colItem of items) {
      if (rowItem === colItem) {
        row.set(colItem, { type: 'self' });
      } else {
        const writeKey = `${rowItem}->${colItem}`;
        const readKey = `${colItem}->${rowItem}`;

        if (depLookup.has(writeKey)) {
          row.set(colItem, { type: 'write', details: depLookup.get(writeKey) });
        } else if (depLookup.has(readKey)) {
          row.set(colItem, { type: 'read', details: depLookup.get(readKey) });
        } else {
          row.set(colItem, { type: 'none' });
        }
      }
    }
    cells.set(rowItem, row);
  }

  return { items, cells };
}
