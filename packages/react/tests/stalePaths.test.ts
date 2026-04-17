import { describe, it, expect, beforeEach } from 'vitest';
import type { StoreApi } from 'zustand/vanilla';
import type { AnalyzeResult } from '@pondpilot/flowscope-core';

import { createLineageStore, type LineageState } from '../src/store';

function buildResult(): AnalyzeResult {
  return {
    statements: [
      {
        statementIndex: 0,
        statementType: 'SELECT',
        sourceName: 'models/users.sql',
        joinCount: 0,
        complexityScore: 1,
      },
    ],
    nodes: [
      {
        id: 'table:users',
        type: 'table',
        label: 'users',
        statementIds: [0],
        span: { start: 14, end: 19 },
        nameSpans: [{ start: 14, end: 19 }],
      },
    ],
    edges: [],
    issues: [],
    summary: {
      statementCount: 1,
      tableCount: 1,
      columnCount: 0,
      joinCount: 0,
      complexityScore: 1,
      issueCount: { errors: 0, warnings: 0, infos: 0 },
      hasErrors: false,
    },
  };
}

describe('stale-graph store fields', () => {
  let store: StoreApi<LineageState>;

  beforeEach(() => {
    store = createLineageStore();
  });

  it('starts with null analyzed snapshot and an empty stale set', () => {
    const state = store.getState();
    expect(state.analyzedContentByPath).toBeNull();
    expect(state.stalePaths.size).toBe(0);
  });

  it('setAnalyzedContent stores the snapshot map', () => {
    const snapshot = new Map([['models/users.sql', 'SELECT * FROM users']]);
    store.getState().setAnalyzedContent(snapshot);
    expect(store.getState().analyzedContentByPath).toBe(snapshot);
  });

  it('setStalePaths replaces the set and is a no-op when set membership is unchanged', () => {
    store.getState().setStalePaths(['a.sql', 'b.sql']);
    const first = store.getState().stalePaths;
    expect(first.has('a.sql')).toBe(true);
    expect(first.has('b.sql')).toBe(true);

    // Same membership → reference should not change (avoids extra re-renders).
    store.getState().setStalePaths(['a.sql', 'b.sql']);
    expect(store.getState().stalePaths).toBe(first);

    // Different membership → reference changes.
    store.getState().setStalePaths(['a.sql']);
    expect(store.getState().stalePaths).not.toBe(first);
    expect(store.getState().stalePaths.has('b.sql')).toBe(false);
  });

  it('clears both snapshot and stale set when the result is cleared', () => {
    store.getState().setResult(buildResult());
    store.getState().setAnalyzedContent(new Map([['a.sql', 'SELECT 1']]));
    store.getState().setStalePaths(['a.sql']);

    store.getState().setResult(null);

    const state = store.getState();
    expect(state.analyzedContentByPath).toBeNull();
    expect(state.stalePaths.size).toBe(0);
  });

  it('preserves the snapshot across a successful re-analyze (non-null setResult)', () => {
    const snapshot = new Map([['a.sql', 'SELECT 1']]);
    store.getState().setResult(buildResult());
    store.getState().setAnalyzedContent(snapshot);

    // A re-analysis calls setResult(result) first; the app then pushes a
    // fresh snapshot. In between, we must not wipe the prior snapshot —
    // otherwise the nav would blink stale→fresh for a frame.
    store.getState().setResult(buildResult());
    expect(store.getState().analyzedContentByPath).toBe(snapshot);
  });
});
