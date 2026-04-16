import { describe, expect, it } from 'vitest';

import type { AnalyzeResult } from '@pondpilot/flowscope-core';

import type { SpanIndex, SpanIndexEntry } from '../src/utils/revealInGraph';
import {
  buildRevealLookup,
  buildSpanIndex,
  findNodeAtByteOffset,
  resolveRevealAnalysisScope,
  resolveRevealGraphTarget,
} from '../src/utils/revealInGraph';

/**
 * Behavior contract for `findNodeAtByteOffset` — the core lookup for the
 * text→graph reveal action (#24).
 *
 * The rules encoded here are:
 *
 * 1. Cursor in whitespace (no span contains it) → return null.
 * 2. Cursor inside a single `name` span → return that entry.
 * 3. Cursor inside a single `body` span → return that entry.
 * 4. Cursor inside both a `name` and a `body` span → prefer the `name` entry.
 *    (Placing the cursor on a CTE name inside its own definition should focus
 *    that CTE, not the enclosing statement.)
 * 5. Cursor inside two overlapping `body` spans (nested CTEs) → prefer the
 *    smallest containing span — the more specific node wins.
 * 6. Span boundaries are half-open: `[start, end)`. The offset at `span.end`
 *    is *not* contained.
 */

function entry(
  nodeId: string,
  kind: SpanIndexEntry['kind'],
  start: number,
  end: number
): SpanIndexEntry {
  return { nodeId, kind, span: { start, end }, size: end - start };
}

function index(...entries: SpanIndexEntry[]): SpanIndex {
  return { entries };
}

describe('findNodeAtByteOffset', () => {
  it('returns null when the cursor is outside every indexed span', () => {
    const idx = index(entry('a', 'name', 10, 20));
    expect(findNodeAtByteOffset(idx, 5)).toBeNull();
    expect(findNodeAtByteOffset(idx, 25)).toBeNull();
  });

  it('returns null for an empty index', () => {
    expect(findNodeAtByteOffset(index(), 0)).toBeNull();
  });

  it('returns the containing name entry', () => {
    const idx = index(entry('col_x', 'name', 100, 110));
    const hit = findNodeAtByteOffset(idx, 105);
    expect(hit?.nodeId).toBe('col_x');
    expect(hit?.kind).toBe('name');
  });

  it('returns the containing body entry when no name matches', () => {
    const idx = index(entry('cte_a', 'body', 0, 200));
    const hit = findNodeAtByteOffset(idx, 50);
    expect(hit?.nodeId).toBe('cte_a');
    expect(hit?.kind).toBe('body');
  });

  it('prefers a name match over an enclosing body match', () => {
    // Cursor is on a CTE name *inside* the CTE body.
    const idx = index(
      entry('cte_a', 'body', 0, 200),
      entry('cte_a', 'name', 50, 55) // reference to `cte_a` at offset 50..55
    );
    const hit = findNodeAtByteOffset(idx, 52);
    expect(hit?.nodeId).toBe('cte_a');
    expect(hit?.kind).toBe('name');
  });

  it('picks the smallest containing body span when bodies nest', () => {
    // Outer CTE body [0, 200). Inner CTE body [40, 100). Cursor at 50 is in
    // both, but the user meant the inner one.
    const idx = index(entry('outer', 'body', 0, 200), entry('inner', 'body', 40, 100));
    const hit = findNodeAtByteOffset(idx, 50);
    expect(hit?.nodeId).toBe('inner');
  });

  it('treats spans as half-open [start, end)', () => {
    const idx = index(entry('a', 'name', 10, 20));
    expect(findNodeAtByteOffset(idx, 10)?.nodeId).toBe('a');
    // `span.end` is exclusive:
    expect(findNodeAtByteOffset(idx, 20)).toBeNull();
  });
});

describe('buildSpanIndex', () => {
  it('merges repeated node ids into a single span set', () => {
    const result = {
      statements: [
        { statementIndex: 0, sourceName: 'a.sql' },
        { statementIndex: 1, sourceName: 'b.sql' },
      ],
      nodes: [
        {
          id: 'table:users',
          type: 'table',
          label: 'users',
          statementIds: [0],
          nameSpans: [{ start: 0, end: 5 }],
          metadata: { occurrenceSpans: [{ start: 0, end: 5 }] },
        },
        {
          id: 'table:users',
          type: 'table',
          label: 'users',
          statementIds: [1],
          nameSpans: [{ start: 10, end: 15 }],
          metadata: { occurrenceSpans: [{ start: 10, end: 15 }] },
        },
      ],
      edges: [],
      issues: [],
    } as unknown as AnalyzeResult;

    const index = buildSpanIndex(result);
    expect(index.entries).toHaveLength(2);
    expect(index.entries.map((entry) => entry.span)).toEqual([
      { start: 0, end: 5 },
      { start: 10, end: 15 },
    ]);
  });

  it('indexes every merged body span, not just the first one', () => {
    const result = {
      statements: [
        { statementIndex: 0, sourceName: 'a.sql' },
        { statementIndex: 1, sourceName: 'b.sql' },
      ],
      nodes: [
        {
          id: 'cte:users',
          type: 'cte',
          label: 'users',
          statementIds: [0],
          bodySpan: { start: 20, end: 40 },
          metadata: { bodySpans: [{ start: 20, end: 40 }] },
        },
        {
          id: 'cte:users',
          type: 'cte',
          label: 'users',
          statementIds: [1],
          bodySpan: { start: 120, end: 160 },
          metadata: { bodySpans: [{ start: 120, end: 160 }] },
        },
      ],
      edges: [],
      issues: [],
    } as unknown as AnalyzeResult;

    const index = buildSpanIndex(result);
    expect(
      index.entries.filter((entry) => entry.kind === 'body').map((entry) => entry.span)
    ).toEqual([
      { start: 20, end: 40 },
      { start: 120, end: 160 },
    ]);
  });

  it('can scope indexing to a single source file', () => {
    const result = {
      statements: [
        { statementIndex: 0, sourceName: 'a.sql' },
        { statementIndex: 1, sourceName: 'b.sql' },
      ],
      nodes: [
        {
          id: 'table:users',
          type: 'table',
          label: 'users',
          statementIds: [0],
          nameSpans: [{ start: 0, end: 5 }],
          metadata: { occurrenceSpans: [{ start: 0, end: 5 }] },
        },
        {
          id: 'table:users',
          type: 'table',
          label: 'users',
          statementIds: [1],
          nameSpans: [{ start: 10, end: 15 }],
          metadata: { occurrenceSpans: [{ start: 10, end: 15 }] },
        },
      ],
      edges: [],
      issues: [],
    } as unknown as AnalyzeResult;

    const index = buildSpanIndex(result, 'b.sql');
    expect(index.entries.map((entry) => entry.span)).toEqual([{ start: 10, end: 15 }]);
  });
});

describe('resolveRevealAnalysisScope', () => {
  const multiFileResult = {
    statements: [
      { statementIndex: 0, sourceName: 'a.sql' },
      { statementIndex: 1, sourceName: 'b.sql' },
    ],
    nodes: [],
    edges: [],
    issues: [],
  } as unknown as AnalyzeResult;

  it('disables reveal when a controlled editor buffer is stale', () => {
    expect(
      resolveRevealAnalysisScope({
        result: multiFileResult,
        isControlled: true,
        sqlText: 'select * from edited_users',
        analyzedSql: 'select * from users',
        analyzedSourceName: 'a.sql',
      })
    ).toEqual({ enabled: false });
  });

  it('disables reveal for multi-file controlled editors without an explicit source', () => {
    expect(
      resolveRevealAnalysisScope({
        result: multiFileResult,
        isControlled: true,
        sqlText: 'select * from users',
        analyzedSql: 'select * from users',
      })
    ).toEqual({ enabled: false });
  });

  it('allows reveal when the controlled editor is scoped to a known source', () => {
    expect(
      resolveRevealAnalysisScope({
        result: multiFileResult,
        isControlled: true,
        sqlText: 'select * from users',
        analyzedSql: 'select * from users',
        analyzedSourceName: 'b.sql',
      })
    ).toEqual({ enabled: true, sourceName: 'b.sql' });
  });
});

describe('resolveRevealGraphTarget', () => {
  const result = {
    statements: [{ statementIndex: 0, sourceName: 'query.sql' }],
    nodes: [
      {
        id: 'table:users',
        type: 'table',
        label: 'users',
        qualifiedName: 'public.users',
        statementIds: [0],
      },
      {
        id: 'column:users.id',
        type: 'column',
        label: 'id',
        statementIds: [0],
      },
      {
        id: 'cte:active_users',
        type: 'cte',
        label: 'active_users',
        statementIds: [0],
      },
    ],
    edges: [
      {
        id: 'ownership:users:id',
        from: 'table:users',
        to: 'column:users.id',
        type: 'ownership',
        statementIds: [0],
      },
    ],
    issues: [],
  } as unknown as AnalyzeResult;

  it('maps a column hit to its owning relation in table view', () => {
    const lookup = buildRevealLookup(result);
    expect(
      resolveRevealGraphTarget(lookup, 'column:users.id', {
        viewMode: 'table',
        showColumnEdges: false,
        showScriptTables: false,
        visibleNodeIds: new Set(['table:users']),
      })
    ).toBe('table:users');
  });

  it('maps a relation hit to the hybrid graph node id in script view', () => {
    const lookup = buildRevealLookup(result);
    expect(
      resolveRevealGraphTarget(lookup, 'table:users', {
        viewMode: 'script',
        showColumnEdges: false,
        showScriptTables: true,
        visibleNodeIds: new Set(['table:public.users']),
      })
    ).toBe('table:public.users');
  });

  it('hides reveal when the mapped target is not visible in the current graph', () => {
    const lookup = buildRevealLookup(result);
    expect(
      resolveRevealGraphTarget(lookup, 'column:users.id', {
        viewMode: 'table',
        showColumnEdges: false,
        showScriptTables: false,
        visibleNodeIds: new Set(['cte:active_users']),
      })
    ).toBeNull();
  });

  it('hides reveal for CTEs in script view when only script/table hybrid nodes exist', () => {
    const lookup = buildRevealLookup(result);
    expect(
      resolveRevealGraphTarget(lookup, 'cte:active_users', {
        viewMode: 'script',
        showColumnEdges: false,
        showScriptTables: true,
        visibleNodeIds: new Set(['table:public.users']),
      })
    ).toBeNull();
  });
});
