import type {
  CompletionContext,
  CompletionResult,
  CompletionSource,
} from '@codemirror/autocomplete';
import {
  completionItems,
  type CompletionToken,
  type Dialect,
  type SchemaMetadata,
} from '@pondpilot/flowscope-core';

import { mapCompletionItem } from './mapCompletionItem';

export interface SqlCompletionSourceOptions {
  /** SQL dialect driving keyword/function filtering. Defaults to 'generic'. */
  getDialect?: () => Dialect;
  /** Optional schema catalog passed through to the engine for column resolution. */
  getSchema?: () => SchemaMetadata | undefined;
  /** Hook to surface engine errors without crashing the editor. */
  onError?: (error: unknown) => void;
}

/** Re-query only while the user is still typing within a single identifier. */
const IDENTIFIER_CONTINUATION = /^[\w$]*$/;
const REPLACEABLE_TOKEN_KINDS = new Set(['identifier', 'keyword']);

function resolveCompletionRange(
  token: CompletionToken | undefined,
  cursorOffset: number,
  docLength: number
): { from: number; to: number } {
  const clamp = (offset: number) => Math.max(0, Math.min(docLength, offset));
  const cursor = clamp(cursorOffset);

  if (!token || !REPLACEABLE_TOKEN_KINDS.has(token.kind ?? '')) {
    return { from: cursor, to: cursor };
  }

  const from = clamp(token.span.start);
  const to = Math.max(from, clamp(token.span.end));
  return { from, to };
}

/**
 * CodeMirror `CompletionSource` backed by flowscope's engine.
 *
 * The engine is multi-statement aware and handles clause detection itself, so
 * we pass the full document plus the UTF-16 cursor offset (CodeMirror positions
 * are UTF-16 code units, which matches `encoding: 'utf16'` on the request).
 */
export function createSqlCompletionSource(
  options: SqlCompletionSourceOptions = {}
): CompletionSource {
  const { getDialect, getSchema, onError } = options;
  let requestCounter = 0;

  return async (context: CompletionContext): Promise<CompletionResult | null> => {
    const requestId = ++requestCounter;
    const sql = context.state.doc.toString();
    const cursorOffset = context.pos;
    const dialect = getDialect?.() ?? 'generic';
    const schema = getSchema?.();

    try {
      const result = await completionItems({
        sql,
        dialect,
        cursorOffset,
        schema,
        encoding: 'utf16',
      });

      if (context.aborted || requestId !== requestCounter) {
        return null;
      }

      if (!result.shouldShow || result.items.length === 0) {
        return null;
      }

      // Only replace the current token when the engine says the cursor is
      // inside an identifier/keyword. Trigger characters like `.`, `(`, and
      // `,` should stay in the document so qualified refs and function calls
      // remain intact.
      const { from, to } = resolveCompletionRange(
        result.token,
        cursorOffset,
        context.state.doc.length
      );

      return {
        from,
        to,
        options: result.items.map(mapCompletionItem),
        validFor: IDENTIFIER_CONTINUATION,
      };
    } catch (error) {
      if (requestId !== requestCounter) {
        return null;
      }
      onError?.(error);
      return null;
    }
  };
}
