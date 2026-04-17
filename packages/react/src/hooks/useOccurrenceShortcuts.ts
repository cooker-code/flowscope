import { useEffect, useRef } from 'react';

import { useLineageActions, useLineageStore } from '../store';
import { findMergedNodeById, resolveNodeSourceName } from '../utils/nodeOccurrences';

/**
 * Global keyboard shortcuts for cycling through the focused node's
 * `nameSpans`: `n` advances to the next occurrence and `Shift+n` returns to
 * the previous one. The listener is suppressed while the user is typing in
 * an editable surface (inputs, textareas, contenteditable, CodeMirror) so
 * the shortcut does not eat ordinary `n` keystrokes.
 *
 * Composition keys (Cmd/Ctrl/Alt + n) are also ignored so platform shortcuts
 * such as "new tab" still reach the browser.
 */
export function useOccurrenceShortcuts(): void {
  const { cycleOccurrence } = useLineageActions();
  // Mirror the store slices we need into refs so the keydown handler can
  // read them synchronously without re-binding on every change.
  const selectedNodeId = useLineageStore((state) => state.selectedNodeId);
  const result = useLineageStore((state) => state.result);
  const stalePaths = useLineageStore((state) => state.stalePaths);
  const staleStateRef = useRef({ selectedNodeId, result, stalePaths });
  staleStateRef.current = { selectedNodeId, result, stalePaths };

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key !== 'n' && event.key !== 'N') return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (isTypingTarget(event.target)) return;

      // Suppress when the selected node's file is stale — its name spans
      // no longer match the editor text, so cycling would jump to wrong
      // positions.
      const snapshot = staleStateRef.current;
      if (snapshot.selectedNodeId && snapshot.result) {
        const node = findMergedNodeById(snapshot.result, snapshot.selectedNodeId);
        if (node) {
          const statementById = new Map(
            snapshot.result.statements.map((s) => [s.statementIndex, s])
          );
          const sourceName = resolveNodeSourceName(node, statementById);
          if (sourceName && snapshot.stalePaths.has(sourceName)) return;
        }
      }

      event.preventDefault();
      cycleOccurrence(event.shiftKey ? 'prev' : 'next');
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [cycleOccurrence]);
}

function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (target.isContentEditable) return true;
  // CodeMirror's editor surface is a contenteditable wrapper; the check above
  // covers it, but also bail if the focused element sits inside the editor —
  // some skin variants use a non-contenteditable wrapper around the editable
  // line area.
  if (target.closest('.cm-editor')) return true;
  return false;
}
