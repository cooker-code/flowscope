import { useMemo, useCallback, useEffect, useRef, useState, type JSX } from 'react';
import CodeMirror, { type ReactCodeMirrorRef } from '@uiw/react-codemirror';
import { sql } from '@codemirror/lang-sql';
import { EditorView, Decoration, type DecorationSet } from '@codemirror/view';
import { StateField, StateEffect } from '@codemirror/state';
import { oneDark } from '@codemirror/theme-one-dark';
import { charOffsetToByteOffset } from '@pondpilot/flowscope-core';

import { useLineage, useLineageStore } from '../store';
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
}: SqlViewProps): JSX.Element {
  const { state, actions } = useLineage();
  const revealNodeInGraph = useLineageStore((store) => store.revealNodeInGraph);
  const visibleGraphNodeIds = useLineageStore((store) => store.visibleGraphNodeIds);
  const isControlled = value !== undefined;

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
      revealScope.enabled ? buildSpanIndex(state.result, revealScope.sourceName) : buildSpanIndex(null),
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

  const getRevealCandidateAtClientPoint = useCallback(
    (x: number, y: number): string | null => {
      const view = editorRef.current?.view;
      if (!view) return null;
      const pos = view.posAtCoords({ x, y });
      return computeRevealCandidate(pos ?? null);
    },
    [computeRevealCandidate]
  );

  // Wire a context-menu entry on the editor DOM. We can't directly inject
  // into the native menu, so we suppress it when a candidate exists and show
  // a lightweight overlay at the click position.
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; nodeId: string } | null>(
    null
  );
  const handleContextMenu = useCallback(
    (event: React.MouseEvent<HTMLDivElement>) => {
      const nodeId = getRevealCandidateAtClientPoint(event.clientX, event.clientY);
      if (!nodeId) return;
      event.preventDefault();
      setContextMenu({ x: event.clientX, y: event.clientY, nodeId });
    },
    [getRevealCandidateAtClientPoint]
  );

  useEffect(() => {
    if (!contextMenu) return;
    const close = () => setContextMenu(null);
    window.addEventListener('click', close);
    window.addEventListener('scroll', close, true);
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('scroll', close, true);
    };
  }, [contextMenu]);

  const extensions = useMemo(
    () => [
      sql(),
      highlightField,
      baseTheme,
      EditorView.lineWrapping,
      EditorView.editable.of(editable),
      selectionListener,
    ],
    [editable, selectionListener]
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

  const canReveal = revealCandidateId !== null;

  return (
    <div className={`flowscope-sql-view ${className || ''}`} onContextMenu={handleContextMenu}>
      {canReveal && (
        <button
          type="button"
          className="flowscope-reveal-action"
          onClick={() => handleReveal()}
          title="Center the graph on the node under the cursor"
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
      {contextMenu && canReveal && (
        <button
          type="button"
          role="menuitem"
          className="flowscope-reveal-action"
          style={{
            position: 'fixed',
            top: contextMenu.y,
            left: contextMenu.x,
            right: 'auto',
          }}
          onClick={() => {
            handleReveal(contextMenu.nodeId);
            setContextMenu(null);
          }}
        >
          Reveal in lineage
        </button>
      )}
    </div>
  );
}
