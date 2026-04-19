import { useMemo, useCallback, useEffect, useRef, useState, type JSX } from 'react';
import CodeMirror, { type ReactCodeMirrorRef } from '@uiw/react-codemirror';
import { sql } from '@codemirror/lang-sql';
import { acceptCompletion, autocompletion } from '@codemirror/autocomplete';
import { EditorView, keymap, Decoration, type DecorationSet } from '@codemirror/view';
import { Prec, StateField, StateEffect } from '@codemirror/state';
import { oneDark } from '@codemirror/theme-one-dark';
import { charOffsetToByteOffset } from '@pondpilot/flowscope-core';

import { useLineage, useLineageStore } from '../store';
import { createSqlCompletionSource } from '../completion';
import type { SqlViewProps } from '../types';
import { trySpanToCharRange } from '../utils/sqlSpans';
import {
  buildRevealLookup,
  buildSpanIndex,
  findNodeAtByteOffset,
  resolveRevealAnalysisScope,
  resolveRevealGraphTarget,
} from '../utils/revealInGraph';

type HighlightRange = { from: number; to: number; className: string };

const setHighlights = StateEffect.define<HighlightRange[]>();

const highlightField = StateField.define<DecorationSet>({
  create() {
    return Decoration.none;
  },
  update(highlights, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setHighlights)) {
        if (effect.value.length === 0) {
          return Decoration.none;
        }
        const marks = effect.value.map(({ from, to, className }) =>
          Decoration.mark({ class: className }).range(from, to)
        );
        return Decoration.set(marks);
      }
    }
    if (tr.docChanged) {
      return highlights.map(tr.changes);
    }
    return highlights;
  },
  provide: (f) => EditorView.decorations.from(f),
});

const baseTheme = EditorView.baseTheme({
  '.flowscope-sql-highlight-active': {
    backgroundColor: 'rgba(102, 126, 234, 0.3)',
    borderRadius: '2px',
  },
  '.flowscope-sql-highlight-error': {
    backgroundColor: 'rgba(239, 72, 111, 0.25)',
    borderRadius: '2px',
  },
  '.flowscope-sql-highlight-warning': {
    backgroundColor: 'rgba(244, 164, 98, 0.25)',
    borderRadius: '2px',
  },
  '.flowscope-sql-highlight-info': {
    backgroundColor: 'rgba(76, 97, 255, 0.15)',
    borderRadius: '2px',
  },
});

export function SqlView({
  className,
  editable = false,
  onChange,
  value,
  isDark,
  highlightedSpan: highlightedSpanProp,
  analyzedSourceName,
  dialect,
  completionSchema,
  disableCompletion = false,
  onCompletionError,
}: SqlViewProps): JSX.Element {
  const { state, actions } = useLineage();
  const revealNodeInGraph = useLineageStore((store) => store.revealNodeInGraph);
  const visibleGraphNodeIds = useLineageStore((store) => store.visibleGraphNodeIds);
  const stalePaths = useLineageStore((store) => store.stalePaths);
  const isControlled = value !== undefined;
  // When the caller declares which analyzed source this editor represents,
  // treat the reveal action as stale if that path has diverged from the
  // analyzed snapshot. Offsets from the stale span index would land in the
  // wrong place, so we'd rather hide the affordance than navigate wrong.
  const isCurrentSourceStale = Boolean(analyzedSourceName && stalePaths.has(analyzedSourceName));

  // Warn in dev mode if highlightedSpan is passed without value (it will be ignored)
  if (process.env.NODE_ENV !== 'production' && !isControlled && highlightedSpanProp !== undefined) {
    console.warn(
      'SqlView: `highlightedSpan` prop is ignored in uncontrolled mode. Pass a `value` prop to use controlled mode.'
    );
  }

  const sqlText = isControlled ? value : state.sql;
  // In controlled mode, prefer the prop; in uncontrolled mode, use store state
  // Normalize undefined to null for consistent type handling downstream
  const highlightedSpan = isControlled ? (highlightedSpanProp ?? null) : state.highlightedSpan;
  const issueHighlights = useMemo<HighlightRange[]>(() => {
    if (isControlled) {
      return [];
    }
    const issues = state.result?.issues ?? [];
    return issues.flatMap((issue) => {
      if (!issue.span) return [];
      const className =
        issue.severity === 'error'
          ? 'flowscope-sql-highlight-error'
          : issue.severity === 'warning'
            ? 'flowscope-sql-highlight-warning'
            : 'flowscope-sql-highlight-info';
      const range = trySpanToCharRange(sqlText, issue.span, 'issue highlight');
      return range ? [{ ...range, className }] : [];
    });
  }, [state.result, isControlled, sqlText]);

  const editorRef = useRef<ReactCodeMirrorRef>(null);
  const lastAutoScrolledHighlightKeyRef = useRef<string | null>(null);

  const revealScope = useMemo(
    () =>
      resolveRevealAnalysisScope({
        result: state.result,
        isControlled,
        sqlText,
        analyzedSql: state.sql,
        analyzedSourceName,
      }),
    [analyzedSourceName, isControlled, sqlText, state.result, state.sql]
  );

  // Interval index of every known `nameSpan` / `bodySpan` in the current
  // analysis result. Rebuilt only when the relevant analysis slice changes.
  const spanIndex = useMemo(
    () =>
      revealScope.enabled
        ? buildSpanIndex(state.result, revealScope.sourceName)
        : buildSpanIndex(null),
    [revealScope.enabled, revealScope.sourceName, state.result]
  );
  const revealLookup = useMemo(
    () =>
      revealScope.enabled
        ? buildRevealLookup(state.result, revealScope.sourceName)
        : buildRevealLookup(null),
    [revealScope.enabled, revealScope.sourceName, state.result]
  );

  // Node id under the caret, or null when the cursor is in whitespace / the
  // index is empty. Drives the "Reveal in lineage" button and the context-menu
  // entry. Works in both controlled and uncontrolled modes — the byte offsets
  // come from `sqlText` (whatever the editor is displaying) and the spans come
  // from the store's analysis result. When the displayed text doesn't
  // correspond to the analyzed SQL (e.g. the resolved/compiled view), span
  // lookups will typically miss, so the button stays hidden.
  const [revealCandidateId, setRevealCandidateId] = useState<string | null>(null);

  const computeRevealCandidate = useCallback(
    (charOffset: number | null): string | null => {
      if (charOffset === null) return null;
      if (!revealScope.enabled || spanIndex.entries.length === 0) return null;
      const byteOffset = charOffsetToByteOffset(sqlText, charOffset);
      const hit = findNodeAtByteOffset(spanIndex, byteOffset);
      if (!hit) return null;

      return resolveRevealGraphTarget(revealLookup, hit.nodeId, {
        viewMode: state.viewMode,
        showColumnEdges: state.showColumnEdges,
        showScriptTables: state.showScriptTables,
        visibleNodeIds: visibleGraphNodeIds,
      });
    },
    [
      revealLookup,
      revealScope.enabled,
      sqlText,
      spanIndex,
      state.showColumnEdges,
      state.showScriptTables,
      state.viewMode,
      visibleGraphNodeIds,
    ]
  );

  // CodeMirror update listener — recomputes the reveal candidate on every
  // selection change or document edit (edits shift offsets around, so the
  // cached candidate goes stale).
  const selectionListener = useMemo(
    () =>
      EditorView.updateListener.of((update) => {
        if (!update.selectionSet && !update.docChanged) return;
        const head = update.state.selection.main.head;
        setRevealCandidateId(computeRevealCandidate(head));
      }),
    [computeRevealCandidate]
  );

  // Recompute whenever inputs to computeRevealCandidate change (e.g. when the
  // analysis result refreshes) without waiting for the user to move the cursor.
  useEffect(() => {
    const view = editorRef.current?.view;
    if (!view) {
      setRevealCandidateId(null);
      return;
    }
    const head = view.state.selection.main.head;
    setRevealCandidateId(computeRevealCandidate(head));
  }, [computeRevealCandidate]);

  const handleReveal = useCallback(
    (nodeId: string | null = revealCandidateId) => {
      if (!nodeId) return;
      revealNodeInGraph(nodeId);
    },
    [revealCandidateId, revealNodeInGraph]
  );

  // Alt+click directly on an indexed span reveals that span in the graph
  // without requiring the user to reach for the floating button. Preserves
  // the native context menu (and copy/paste) because we don't touch
  // `contextmenu` events.
  const handleEditorMouseDown = useCallback(
    (event: React.MouseEvent<HTMLDivElement>) => {
      if (!event.altKey || event.button !== 0) return;
      // Let clicks on the reveal button handle themselves; we bind at the
      // wrapper so we'd otherwise re-trigger reveal on the button too.
      const target = event.target as HTMLElement | null;
      if (target?.closest('.flowscope-reveal-action')) return;
      const view = editorRef.current?.view;
      if (!view) return;
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      const nodeId = computeRevealCandidate(pos ?? null);
      if (!nodeId) return;
      event.preventDefault();
      handleReveal(nodeId);
    },
    [computeRevealCandidate, handleReveal]
  );

  // Mirror dialect/schema/onError into refs so the completion source reads the
  // latest values without requiring a CodeMirror reconfigure on every change.
  // That is also why these refs are intentionally *not* listed as deps of the
  // memoized completion extension below.
  const dialectRef = useRef(dialect);
  const schemaRef = useRef(completionSchema);
  const onCompletionErrorRef = useRef(onCompletionError);
  useEffect(() => {
    dialectRef.current = dialect;
  }, [dialect]);
  useEffect(() => {
    schemaRef.current = completionSchema;
  }, [completionSchema]);
  useEffect(() => {
    onCompletionErrorRef.current = onCompletionError;
  }, [onCompletionError]);

  const completionExtension = useMemo(() => {
    if (!editable || disableCompletion) return null;
    const source = createSqlCompletionSource({
      getDialect: () => dialectRef.current ?? 'generic',
      getSchema: () => schemaRef.current,
      onError: (error) => {
        const handler = onCompletionErrorRef.current;
        if (handler) {
          handler(error);
          return;
        }
        // Log only the message to avoid dumping the full error (which may
        // embed SQL/schema fragments) into shared consoles.
        console.warn(
          '[FlowScope] SQL completion failed:',
          error instanceof Error ? error.message : String(error)
        );
      },
    });
    // `acceptCompletion` is a no-op (returns false) when no popup is open, so
    // binding Tab here leaves default Tab handling (indent / focus) intact
    // outside of an active completion session. `Prec.highest` ensures we win
    // over basicSetup's `indentWithTab` binding while a popup is open.
    return [
      autocompletion({ override: [source] }),
      Prec.highest(keymap.of([{ key: 'Tab', run: acceptCompletion }])),
    ];
  }, [editable, disableCompletion]);

  const extensions = useMemo(
    () => [
      sql(),
      highlightField,
      baseTheme,
      EditorView.lineWrapping,
      EditorView.editable.of(editable),
      selectionListener,
      ...(completionExtension ?? []),
    ],
    [editable, selectionListener, completionExtension]
  );

  const theme = useMemo(() => (isDark ? oneDark : 'light'), [isDark]);

  const handleChange = useCallback(
    (val: string) => {
      if (!isControlled) {
        actions.setSql(val);
      }
      onChange?.(val);
    },
    [actions, onChange, isControlled]
  );

  useEffect(() => {
    const view = editorRef.current?.view;
    if (!view) return;

    const ranges: HighlightRange[] = [];
    if (!isControlled) {
      ranges.push(...issueHighlights);
    }
    const activeRange = highlightedSpan
      ? trySpanToCharRange(sqlText, highlightedSpan, 'active highlight')
      : null;
    if (activeRange) {
      ranges.push({
        from: activeRange.from,
        to: activeRange.to,
        className: 'flowscope-sql-highlight-active',
      });
    }

    view.dispatch({
      effects: setHighlights.of(ranges),
    });

    const highlightKey = highlightedSpan ? `${highlightedSpan.start}:${highlightedSpan.end}` : null;
    if (!activeRange) {
      lastAutoScrolledHighlightKeyRef.current = null;
      return;
    }

    const shouldAutoScroll =
      lastAutoScrolledHighlightKeyRef.current !== highlightKey || !view.hasFocus;
    if (shouldAutoScroll) {
      view.dispatch({
        selection: { anchor: activeRange.from },
        scrollIntoView: true,
      });
      lastAutoScrolledHighlightKeyRef.current = highlightKey;
    }
  }, [highlightedSpan, issueHighlights, isControlled, sqlText]);

  const canReveal = revealCandidateId !== null && !isCurrentSourceStale;

  return (
    <div className={`flowscope-sql-view ${className || ''}`} onMouseDown={handleEditorMouseDown}>
      {canReveal && (
        <button
          type="button"
          className="flowscope-reveal-action"
          onClick={() => handleReveal()}
          title="Center the lineage graph on the node under the cursor (or Alt+click a span)"
          aria-label="Reveal the SQL identifier under the cursor in the lineage graph"
        >
          Reveal in lineage
        </button>
      )}
      <CodeMirror
        ref={editorRef}
        value={sqlText}
        onChange={handleChange}
        extensions={extensions}
        editable={editable}
        theme={theme}
        basicSetup={{
          lineNumbers: true,
          highlightActiveLineGutter: true,
          foldGutter: true,
        }}
        className="flowscope-codemirror"
      />
    </div>
  );
}
