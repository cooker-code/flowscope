import { useEffect, useRef } from 'react';
import type { AnalyzeResult } from '@pondpilot/flowscope-core';
import { useProject } from '@/lib/project-store';

export interface UseLoadAuditRecordOptions {
  auditId: string | null;
  enabled: boolean;
  setResultFromCache: (result: AnalyzeResult) => void;
}

/**
 * When `/?auditId=` is present in serve mode, loads the audit row into the
 * backend project (SQL text + optional cached AnalyzeResult).
 */
export function useLoadAuditRecord({
  auditId,
  enabled,
  setResultFromCache,
}: UseLoadAuditRecordOptions): void {
  const { setBackendFileContent, selectFile, isBackendMode } = useProject();
  const lastLoadedId = useRef<string | null>(null);

  useEffect(() => {
    if (!enabled || !auditId || !isBackendMode) {
      lastLoadedId.current = null;
      return;
    }

    let cancelled = false;

    (async () => {
      try {
        const res = await fetch(`/api/audit/${auditId}`);
        if (!res.ok || cancelled) {
          return;
        }
        const record = (await res.json()) as {
          sql_text: string;
          file_name?: string | null;
          result_json?: AnalyzeResult | null;
        };
        const fileKey = record.file_name?.trim() || `audit-inline-${auditId}.sql`;
        setBackendFileContent(fileKey, record.sql_text);
        selectFile(fileKey);
        if (record.result_json) {
          setResultFromCache(record.result_json);
        }
        lastLoadedId.current = auditId;
      } catch {
        lastLoadedId.current = null;
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [auditId, enabled, isBackendMode, setBackendFileContent, selectFile, setResultFromCache]);
}
