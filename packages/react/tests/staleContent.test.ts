import { describe, it, expect } from 'vitest';

import { computeStalePaths } from '../src/utils/staleContent';

describe('computeStalePaths', () => {
  it('returns an empty set when no analysis snapshot exists', () => {
    const stale = computeStalePaths(null, [{ path: 'a.sql', content: 'SELECT 1' }]);
    expect(stale.size).toBe(0);
  });

  it('returns an empty set when every analyzed path matches current content', () => {
    const snapshot = new Map([
      ['a.sql', 'SELECT 1'],
      ['b.sql', 'SELECT 2'],
    ]);
    const stale = computeStalePaths(snapshot, [
      { path: 'a.sql', content: 'SELECT 1' },
      { path: 'b.sql', content: 'SELECT 2' },
    ]);
    expect(stale.size).toBe(0);
  });

  it('flags a path whose content has diverged (edit)', () => {
    const snapshot = new Map([['a.sql', 'SELECT 1']]);
    const stale = computeStalePaths(snapshot, [{ path: 'a.sql', content: 'SELECT 2' }]);
    expect(stale.has('a.sql')).toBe(true);
    expect(stale.size).toBe(1);
  });

  it('clears a path after an edit is undone (content matches snapshot again)', () => {
    const snapshot = new Map([['a.sql', 'SELECT 1']]);
    // Edited: stale.
    expect(computeStalePaths(snapshot, [{ path: 'a.sql', content: 'SELECT 2' }]).has('a.sql')).toBe(
      true
    );
    // Undone back to the original: not stale.
    expect(computeStalePaths(snapshot, [{ path: 'a.sql', content: 'SELECT 1' }]).has('a.sql')).toBe(
      false
    );
  });

  it('flags a path that was analyzed but is now missing from the project (deleted/renamed)', () => {
    const snapshot = new Map([['a.sql', 'SELECT 1']]);
    const stale = computeStalePaths(snapshot, []);
    expect(stale.has('a.sql')).toBe(true);
  });

  it('ignores files added after analysis — they are not stale, just not in the graph yet', () => {
    const snapshot = new Map([['a.sql', 'SELECT 1']]);
    const stale = computeStalePaths(snapshot, [
      { path: 'a.sql', content: 'SELECT 1' },
      { path: 'newly_added.sql', content: 'SELECT 42' },
    ]);
    expect(stale.size).toBe(0);
  });

  it('is sensitive to trailing-newline edits (strict equality)', () => {
    const snapshot = new Map([['a.sql', 'SELECT 1']]);
    const stale = computeStalePaths(snapshot, [{ path: 'a.sql', content: 'SELECT 1\n' }]);
    expect(stale.has('a.sql')).toBe(true);
  });
});
