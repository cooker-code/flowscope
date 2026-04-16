import { describe, it, expect, beforeEach } from 'vitest';
import type { StoreApi } from 'zustand/vanilla';

import { createLineageStore, type LineageState } from '../src/store';

describe('revealNodeInGraph', () => {
  let store: StoreApi<LineageState>;

  beforeEach(() => {
    store = createLineageStore();
  });

  it('selects the node and records a reveal request', () => {
    store.getState().revealNodeInGraph('table:users');

    const state = store.getState();
    expect(state.selectedNodeId).toBe('table:users');
    expect(state.highlightedSpan).toBeNull();
    expect(state.focusedOccurrenceIndex).toBe(0);
    expect(state.revealRequest).toEqual({ nodeId: 'table:users', nonce: 1 });
    expect(state.suppressNextSelectedNodeNavigation).toBe(true);
  });

  it('bumps the nonce when the same node is revealed repeatedly', () => {
    store.getState().revealNodeInGraph('cte:active');
    store.getState().revealNodeInGraph('cte:active');
    store.getState().revealNodeInGraph('cte:active');

    expect(store.getState().revealRequest).toEqual({ nodeId: 'cte:active', nonce: 3 });
  });

  it('clearRevealRequest drops the pending request without touching selection', () => {
    store.getState().revealNodeInGraph('cte:active');
    store.getState().clearRevealRequest();

    const state = store.getState();
    expect(state.revealRequest).toBeNull();
    expect(state.selectedNodeId).toBe('cte:active');
  });

  it('consumeSelectedNodeNavigationSuppression skips the bounce only once', () => {
    store.getState().revealNodeInGraph('cte:active');

    expect(store.getState().consumeSelectedNodeNavigationSuppression()).toBe(true);
    expect(store.getState().suppressNextSelectedNodeNavigation).toBe(false);
    expect(store.getState().consumeSelectedNodeNavigationSuppression()).toBe(false);
  });
});
