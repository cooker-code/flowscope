import { beforeEach, describe, expect, it, vi } from 'vitest';
import { EditorState } from '@codemirror/state';
import { CompletionContext } from '@codemirror/autocomplete';
import type { CompletionItemsResult } from '@pondpilot/flowscope-core';

const { completionItemsMock } = vi.hoisted(() => ({ completionItemsMock: vi.fn() }));

vi.mock('@pondpilot/flowscope-core', async () => {
  const actual = await vi.importActual<typeof import('@pondpilot/flowscope-core')>(
    '@pondpilot/flowscope-core'
  );
  return {
    ...actual,
    completionItems: completionItemsMock,
  };
});

import { createSqlCompletionSource } from '../src/completion/sqlCompletionSource';

function contextAt(doc: string, pos: number): CompletionContext {
  return new CompletionContext(EditorState.create({ doc }), pos, true);
}

function engineResult(overrides: Partial<CompletionItemsResult> = {}): CompletionItemsResult {
  return {
    clause: 'select',
    shouldShow: true,
    items: [
      {
        label: 'users',
        insertText: 'users',
        kind: 'table',
        category: 'table',
        score: 900,
        clauseSpecific: true,
      },
    ],
    token: { value: 'us', kind: 'identifier', span: { start: 7, end: 9 } },
    ...overrides,
  };
}

beforeEach(() => {
  completionItemsMock.mockReset();
});

describe('createSqlCompletionSource', () => {
  it('forwards CodeMirror char offsets to the engine using UTF-16 encoding', async () => {
    completionItemsMock.mockResolvedValue(engineResult());
    const source = createSqlCompletionSource({ getDialect: () => 'postgres' });

    await source(contextAt('SELECT us', 9));

    expect(completionItemsMock).toHaveBeenCalledWith({
      sql: 'SELECT us',
      dialect: 'postgres',
      cursorOffset: 9,
      schema: undefined,
      encoding: 'utf16',
    });
  });

  it("uses the engine's token span as the replace range so inserted text overwrites the partial identifier", async () => {
    completionItemsMock.mockResolvedValue(engineResult());
    const source = createSqlCompletionSource();

    const result = await source(contextAt('SELECT us', 9));

    expect(result).not.toBeNull();
    expect(result!.from).toBe(7);
    expect(result!.to).toBe(9);
    expect(result!.options.map((o) => o.label)).toEqual(['users']);
  });

  it('keeps trigger punctuation in place by not replacing symbol tokens', async () => {
    completionItemsMock.mockResolvedValue(
      engineResult({
        token: { value: '.', kind: 'symbol', span: { start: 10, end: 11 } },
      })
    );
    const source = createSqlCompletionSource();

    const result = await source(contextAt('SELECT cte.', 11));

    expect(result).not.toBeNull();
    expect(result!.from).toBe(11);
    expect(result!.to).toBe(11);
  });

  it('returns null when the engine reports shouldShow=false', async () => {
    completionItemsMock.mockResolvedValue(engineResult({ shouldShow: false }));
    const source = createSqlCompletionSource();

    const result = await source(contextAt('SELECT ', 7));
    expect(result).toBeNull();
  });

  it('returns null when the engine produces no items', async () => {
    completionItemsMock.mockResolvedValue(engineResult({ items: [] }));
    const source = createSqlCompletionSource();

    const result = await source(contextAt('SELECT ', 7));
    expect(result).toBeNull();
  });

  it('defaults to the generic dialect when no accessor is provided', async () => {
    completionItemsMock.mockResolvedValue(engineResult());
    const source = createSqlCompletionSource();

    await source(contextAt('SELECT ', 7));

    expect(completionItemsMock).toHaveBeenCalledWith(
      expect.objectContaining({ dialect: 'generic' })
    );
  });

  it('drops stale results when a newer request starts before the previous resolves', async () => {
    let resolveFirst!: (value: CompletionItemsResult) => void;
    const firstPromise = new Promise<CompletionItemsResult>((resolve) => {
      resolveFirst = resolve;
    });
    completionItemsMock.mockImplementationOnce(() => firstPromise);
    completionItemsMock.mockResolvedValueOnce(engineResult());

    const source = createSqlCompletionSource();
    const firstCall = source(contextAt('SELECT u', 8));
    // Start a second request before the first resolves — the first's eventual
    // result is now stale and should be suppressed.
    const secondCall = source(contextAt('SELECT us', 9));

    resolveFirst(engineResult({ items: [] })); // Different payload, must be ignored.

    expect(await firstCall).toBeNull();
    expect(await secondCall).not.toBeNull();
  });

  it('clamps an out-of-range token span to the document length', async () => {
    // Simulate a stale / buggy engine response whose token span extends
    // beyond the current document. We expect the source to clamp rather than
    // hand CodeMirror invalid offsets.
    const doc = 'SELECT us';
    completionItemsMock.mockResolvedValue(
      engineResult({
        token: { value: 'us', kind: 'identifier', span: { start: 7, end: 9999 } },
      })
    );
    const source = createSqlCompletionSource();

    const result = await source(contextAt(doc, doc.length));

    expect(result).not.toBeNull();
    expect(result!.from).toBe(7);
    expect(result!.to).toBe(doc.length);
  });

  it('swallows engine errors and forwards them to onError instead of throwing', async () => {
    const error = new Error('engine blew up');
    completionItemsMock.mockRejectedValue(error);
    const onError = vi.fn();
    const source = createSqlCompletionSource({ onError });

    const result = await source(contextAt('SELECT ', 7));

    expect(result).toBeNull();
    expect(onError).toHaveBeenCalledWith(error);
  });
});
