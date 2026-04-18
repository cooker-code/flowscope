import type { Completion } from '@codemirror/autocomplete';
import type { CompletionItem, CompletionItemKind } from '@pondpilot/flowscope-core';

/**
 * CodeMirror renders each completion's icon from the `type` field. The
 * flowscope engine's kinds don't all map one-to-one, so we pick the CM
 * built-in that reads best in a generic SQL context.
 */
const CM_TYPE_BY_KIND: Record<CompletionItemKind, string> = {
  keyword: 'keyword',
  operator: 'keyword',
  function: 'function',
  snippet: 'text',
  table: 'class',
  schemaTable: 'class',
  column: 'property',
};

const FALLBACK_DETAIL: Record<CompletionItemKind, string> = {
  keyword: 'keyword',
  operator: 'operator',
  function: 'function',
  snippet: 'snippet',
  table: 'table',
  schemaTable: 'schema table',
  column: 'column',
};

/**
 * Engine scores are context-weighted and span 0–1000+, while CodeMirror's
 * `boost` is a small adjustment applied after its own fuzzy-match score.
 * Scaling down keeps the relative ordering without drowning CM's matcher.
 */
const BOOST_SCALE = 100;

export function mapCompletionItem(item: CompletionItem): Completion {
  const detail = item.detail ?? FALLBACK_DETAIL[item.kind];
  const completion: Completion = {
    label: item.label,
    type: CM_TYPE_BY_KIND[item.kind],
    detail,
    boost: item.score / BOOST_SCALE,
  };

  if (item.insertText !== item.label) {
    completion.apply = item.insertText;
  }

  return completion;
}
