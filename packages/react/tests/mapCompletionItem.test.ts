import { describe, expect, it } from 'vitest';
import type { CompletionItem } from '@pondpilot/flowscope-core';

import { mapCompletionItem } from '../src/completion/mapCompletionItem';

function item(overrides: Partial<CompletionItem>): CompletionItem {
  return {
    label: 'SELECT',
    insertText: 'SELECT',
    kind: 'keyword',
    category: 'keyword',
    score: 500,
    clauseSpecific: false,
    ...overrides,
  };
}

describe('mapCompletionItem', () => {
  it('maps each engine kind to a stable CodeMirror type', () => {
    const kinds = [
      ['keyword', 'keyword'],
      ['operator', 'keyword'],
      ['function', 'function'],
      ['snippet', 'text'],
      ['table', 'class'],
      ['schemaTable', 'class'],
      ['column', 'property'],
    ] as const;

    for (const [kind, expectedType] of kinds) {
      expect(mapCompletionItem(item({ kind, category: kind })).type).toBe(expectedType);
    }
  });

  it('passes through engine-supplied detail text verbatim', () => {
    const result = mapCompletionItem(item({ kind: 'function', detail: 'COUNT(expr) → BIGINT' }));
    expect(result.detail).toBe('COUNT(expr) → BIGINT');
  });

  it('falls back to a human-readable kind label when detail is missing', () => {
    expect(mapCompletionItem(item({ kind: 'schemaTable' })).detail).toBe('schema table');
    expect(mapCompletionItem(item({ kind: 'column' })).detail).toBe('column');
  });

  it('scales engine score into CodeMirror boost so ordering is preserved', () => {
    const a = mapCompletionItem(item({ score: 900 }));
    const b = mapCompletionItem(item({ score: 100 }));
    expect((a.boost ?? 0) > (b.boost ?? 0)).toBe(true);
  });

  it('omits apply when insertText equals label so CodeMirror inserts the label directly', () => {
    const result = mapCompletionItem(item({ label: 'SELECT', insertText: 'SELECT' }));
    expect(result.apply).toBeUndefined();
  });

  it('uses insertText as apply when it diverges from the label', () => {
    const result = mapCompletionItem(
      item({ kind: 'function', label: 'COUNT', insertText: 'COUNT()' })
    );
    expect(result.apply).toBe('COUNT()');
  });
});
