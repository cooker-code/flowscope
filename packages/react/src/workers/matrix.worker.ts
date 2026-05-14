/**
 * Web Worker for matrix computation.
 * Builds table/script matrices and autocomplete data off the main thread.
 */
import type { AnalyzeResult } from '@pondpilot/flowscope-core';
import type {
  MatrixData,
  MatrixMetrics,
  TableDependencyWithDetails,
  ScriptDependency,
  MatrixCellData,
} from '../utils/matrixUtils';
import {
  extractTableDependenciesWithDetails,
  extractScriptDependencies,
  extractAllColumnNames,
  extractCteItemKeys,
  computeMatrixMetrics,
} from '../utils/matrixUtils';

export interface MatrixBuildRequest {
  type: 'build-matrix';
  requestId: string;
  result: AnalyzeResult;
  maxItems?: number;
}

export interface MatrixBuildResponse {
  type: 'build-result';
  requestId: string;
  tableMatrix: MatrixData;
  scriptMatrix: MatrixData;
  allColumnNames: string[];
  tableMetrics: MatrixMetrics;
  scriptMetrics: MatrixMetrics;
  tableItemCount: number;
  tableItemsRendered: number;
  scriptItemCount: number;
  scriptItemsRendered: number;
  /**
   * Matrix-keys (qualifiedName || label) of CTE nodes present in the analysis.
   * Sent as an array because Sets do not survive structured cloning between
   * Worker boundaries on every runtime; the main thread reconstructs a Set.
   */
  cteItemKeys: string[];
  error?: string;
}

function buildTableMatrixWithItems(
  dependencies: TableDependencyWithDetails[],
  items: string[]
): MatrixData {
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

function buildScriptMatrixWithItems(dependencies: ScriptDependency[], items: string[]): MatrixData {
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

function selectTopItems(
  items: string[],
  counts: Map<string, number>,
  maxItems: number
): { selected: string[]; rendered: number } {
  if (maxItems <= 0 || items.length <= maxItems) {
    return { selected: [...items].sort(), rendered: items.length };
  }

  const sortedByDegree = [...items].sort((a, b) => {
    const diff = (counts.get(b) || 0) - (counts.get(a) || 0);
    if (diff !== 0) return diff;
    return a.localeCompare(b);
  });

  const selected = sortedByDegree.slice(0, maxItems).sort();
  return { selected, rendered: selected.length };
}

console.log('[Matrix Worker] Worker initialized');

self.onmessage = (event: MessageEvent<MatrixBuildRequest>) => {
  const request = event.data;

  if (request.type !== 'build-matrix') {
    return;
  }

  const startTime = performance.now();
  const debug = !!(import.meta as { env?: { DEV?: boolean } }).env?.DEV;

  try {
    const maxItems = request.maxItems ?? 0;

    const tableDepsStart = performance.now();
    const tableDeps = extractTableDependenciesWithDetails(request.result);
    const tableDepsMs = performance.now() - tableDepsStart;

    const tableCounts = new Map<string, number>();
    const tableItemsSet = new Set<string>();
    for (const dep of tableDeps) {
      tableItemsSet.add(dep.sourceTable);
      tableItemsSet.add(dep.targetTable);
      tableCounts.set(dep.sourceTable, (tableCounts.get(dep.sourceTable) || 0) + 1);
      tableCounts.set(dep.targetTable, (tableCounts.get(dep.targetTable) || 0) + 1);
    }
    const tableItemsAll = Array.from(tableItemsSet);
    const { selected: tableItems, rendered: tableItemsRendered } = selectTopItems(
      tableItemsAll,
      tableCounts,
      maxItems
    );
    const tableItemsSetSelected = new Set(tableItems);
    const limitedTableDeps = tableDeps.filter(
      (dep) =>
        tableItemsSetSelected.has(dep.sourceTable) && tableItemsSetSelected.has(dep.targetTable)
    );

    const tableMatrixStart = performance.now();
    const tableMatrix = buildTableMatrixWithItems(limitedTableDeps, tableItems);
    const tableMatrixMs = performance.now() - tableMatrixStart;

    const tableMetricsStart = performance.now();
    const tableMetrics = computeMatrixMetrics(tableMatrix, 'tables');
    const tableMetricsMs = performance.now() - tableMetricsStart;

    const scriptDepsStart = performance.now();
    const scriptDeps = extractScriptDependencies(request.result);
    const scriptDepsMs = performance.now() - scriptDepsStart;

    const scriptCounts = new Map<string, number>();
    for (const script of scriptDeps.allScripts) {
      scriptCounts.set(script, 0);
    }
    for (const dep of scriptDeps.dependencies) {
      scriptCounts.set(dep.sourceScript, (scriptCounts.get(dep.sourceScript) || 0) + 1);
      scriptCounts.set(dep.targetScript, (scriptCounts.get(dep.targetScript) || 0) + 1);
    }
    const { selected: scriptItems, rendered: scriptItemsRendered } = selectTopItems(
      scriptDeps.allScripts,
      scriptCounts,
      maxItems
    );
    const scriptItemsSetSelected = new Set(scriptItems);
    const limitedScriptDeps = scriptDeps.dependencies.filter(
      (dep) =>
        scriptItemsSetSelected.has(dep.sourceScript) && scriptItemsSetSelected.has(dep.targetScript)
    );

    const scriptMatrixStart = performance.now();
    const scriptMatrix = buildScriptMatrixWithItems(limitedScriptDeps, scriptItems);
    const scriptMatrixMs = performance.now() - scriptMatrixStart;

    const scriptMetricsStart = performance.now();
    const scriptMetrics = computeMatrixMetrics(scriptMatrix, 'scripts');
    const scriptMetricsMs = performance.now() - scriptMetricsStart;

    const columnNamesStart = performance.now();
    const allColumnNames = extractAllColumnNames(request.result);
    const columnNamesMs = performance.now() - columnNamesStart;

    const cteKeysStart = performance.now();
    const cteItemKeys = Array.from(extractCteItemKeys(request.result));
    const cteKeysMs = performance.now() - cteKeysStart;

    const duration = performance.now() - startTime;
    if (debug) {
      console.log(
        `[Matrix Worker] tableDeps=${tableDeps.length}, tableItems=${tableItemsAll.length} -> ${tableItemsRendered} (${tableItemsRendered * tableItemsRendered} cells)`
      );
      console.log(
        `[Matrix Worker] scriptDeps=${scriptDeps.dependencies.length}, scriptItems=${scriptDeps.allScripts.length} -> ${scriptItemsRendered} (${scriptItemsRendered * scriptItemsRendered} cells)`
      );
      console.log(
        `[Matrix Worker] steps: tableDeps ${tableDepsMs.toFixed(1)}ms, tableMatrix ${tableMatrixMs.toFixed(1)}ms, tableMetrics ${tableMetricsMs.toFixed(1)}ms`
      );
      console.log(
        `[Matrix Worker] steps: scriptDeps ${scriptDepsMs.toFixed(1)}ms, scriptMatrix ${scriptMatrixMs.toFixed(1)}ms, scriptMetrics ${scriptMetricsMs.toFixed(1)}ms`
      );
      console.log(
        `[Matrix Worker] steps: columnNames ${columnNamesMs.toFixed(1)}ms, cteKeys ${cteKeysMs.toFixed(1)}ms (${cteItemKeys.length} CTEs)`
      );
    }

    console.log(`[Matrix Worker] Build completed in ${duration.toFixed(2)}ms`);

    const response: MatrixBuildResponse = {
      type: 'build-result',
      requestId: request.requestId,
      tableMatrix,
      scriptMatrix,
      allColumnNames,
      tableMetrics,
      scriptMetrics,
      tableItemCount: tableItemsAll.length,
      tableItemsRendered,
      scriptItemCount: scriptDeps.allScripts.length,
      scriptItemsRendered,
      cteItemKeys,
    };

    self.postMessage(response);
  } catch (error) {
    console.error('[Matrix Worker] Error:', error);
    const response: MatrixBuildResponse = {
      type: 'build-result',
      requestId: request.requestId,
      tableMatrix: { items: [], cells: new Map() },
      scriptMatrix: { items: [], cells: new Map() },
      allColumnNames: [],
      tableMetrics: {
        rowCounts: new Map(),
        colCounts: new Map(),
        maxRow: 0,
        maxCol: 0,
        maxIntensity: 1,
      },
      scriptMetrics: {
        rowCounts: new Map(),
        colCounts: new Map(),
        maxRow: 0,
        maxCol: 0,
        maxIntensity: 1,
      },
      tableItemCount: 0,
      tableItemsRendered: 0,
      scriptItemCount: 0,
      scriptItemsRendered: 0,
      cteItemKeys: [],
      error: error instanceof Error ? error.message : 'Unknown error',
    };
    self.postMessage(response);
  }
};
