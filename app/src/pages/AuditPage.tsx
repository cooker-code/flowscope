import {
  apiFetch,
  graphStatus,
  INGESTION_STATUS_LABELS,
  type GraphChanges,
} from '@/lib/lineage-api';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import {
  ArrowLeft,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Loader2,
  TriangleAlert,
  XCircle,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { GraphIngestionStatus, GraphIngestionStatusHelp } from '@/components/GraphIngestionStatus';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { useDebounce } from '@/hooks/useDebounce';
import { useProject } from '@/lib/project-store';
import { cn, formatLocalTs } from '@/lib/utils';

const PAGE_SIZE = 50;

const ANY = '__any__';
const SQL_TYPE_OPTIONS = [
  { value: 'INSERT INTO', label: 'ii' },
  { value: 'INSERT OVERWRITE', label: 'io' },
  { value: 'SELECT', label: 'select' },
];

// Filter / pagination state lives in the URL so it survives navigating to a
// lineage detail and back. See `LAST_AUDIT_QUERY_KEY` for the cross-detail
// hand-off used by SqlPreviewCapsule.
const URL_PARAM_KEYS = [
  'from',
  'to',
  'sql_type',
  'success',
  'lineage_status',
  'file_name',
  'source_name',
  'target_table',
  'keyword',
  'page',
] as const;
export const LAST_AUDIT_QUERY_KEY = 'flowscope.audit.lastListQuery';

interface AuditListRecord {
  id: number;
  ts: string;
  endpoint: string;
  dialect: string;
  file_name: string | null;
  source_name: string | null;
  target_table: string | null;
  sql_type: string | null;
  success: boolean;
  alias_warning: boolean;
  duration_ms: number;
  table_count: number | null;
  principal_id?: string;
  event_id?: string;
  lineage_status?: string | null;
  usage_status?: string | null;
  policy_reason?: string | null;
  lineage_reason?: string | null;
  graph_changes?: GraphChanges | null;
}

interface AuditQueryResponse {
  total: number;
  distinct_sql?: number;
  records: AuditListRecord[];
}

export function AuditPage() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const { isBackendMode, backendAuditStorage } = useProject();

  // URL is the source of truth for filters/pagination — survives back/forward
  // and round-trips through the lineage detail view.
  const from = searchParams.get('from') ?? '';
  const to = searchParams.get('to') ?? '';
  const sqlType = searchParams.get('sql_type') ?? ANY;
  const success = searchParams.get('success') ?? ANY;
  const rawLineageStatus = searchParams.get('lineage_status') ?? ANY;
  const lineageStatus =
    rawLineageStatus === 'blocked'
      ? 'failed'
      : rawLineageStatus === 'blocked_policy'
        ? 'not_requested'
        : rawLineageStatus;
  const fileName = searchParams.get('file_name') ?? '';
  const sourceName = searchParams.get('source_name') ?? '';
  const targetTable = searchParams.get('target_table') ?? '';
  const urlKeyword = searchParams.get('keyword') ?? '';
  const page = Math.max(1, parseInt(searchParams.get('page') ?? '1', 10) || 1);

  // Text inputs maintain a local mirror so typing stays responsive; the
  // debounced value is what we push back to the URL (and the request).
  const [fileNameInput, setFileNameInput] = useState(fileName);
  const [sourceNameInput, setSourceNameInput] = useState(sourceName);
  const [targetTableInput, setTargetTableInput] = useState(targetTable);
  const [keywordInput, setKeywordInput] = useState(urlKeyword);
  const debouncedFileName = useDebounce(fileNameInput, 300);
  const debouncedSourceName = useDebounce(sourceNameInput, 300);
  const debouncedTargetTable = useDebounce(targetTableInput, 300);
  const debouncedKeyword = useDebounce(keywordInput, 300);

  // Helper: mutate the URL while resetting page=1 on any filter change.
  // Pass `null` to clear a param (instead of writing an empty value).
  const updateParams = useCallback(
    (updates: Record<string, string | null>, opts: { resetPage?: boolean } = {}) => {
      setSearchParams(
        (prev) => {
          const next = new URLSearchParams(prev);
          for (const [key, value] of Object.entries(updates)) {
            if (value === null || value === '' || value === ANY) {
              next.delete(key);
            } else {
              next.set(key, value);
            }
          }
          if (opts.resetPage && next.get('page') !== '1') {
            next.delete('page');
          }
          return next;
        },
        { replace: true }
      );
    },
    [setSearchParams]
  );

  // Sync the debounced text-input values into the URL (resetting page=1).
  useEffect(() => {
    if (debouncedFileName !== fileName) {
      updateParams({ file_name: debouncedFileName }, { resetPage: true });
    }
  }, [debouncedFileName, fileName, updateParams]);

  useEffect(() => {
    if (debouncedSourceName !== sourceName) {
      updateParams({ source_name: debouncedSourceName }, { resetPage: true });
    }
  }, [debouncedSourceName, sourceName, updateParams]);

  useEffect(() => {
    if (debouncedTargetTable !== targetTable) {
      updateParams({ target_table: debouncedTargetTable }, { resetPage: true });
    }
  }, [debouncedTargetTable, targetTable, updateParams]);

  useEffect(() => {
    if (debouncedKeyword !== urlKeyword) {
      updateParams({ keyword: debouncedKeyword }, { resetPage: true });
    }
  }, [debouncedKeyword, urlKeyword, updateParams]);

  const setFrom = (v: string) => updateParams({ from: v }, { resetPage: true });
  const setTo = (v: string) => updateParams({ to: v }, { resetPage: true });
  const setSqlType = (v: string) => updateParams({ sql_type: v }, { resetPage: true });
  const setSuccess = (v: string) => updateParams({ success: v }, { resetPage: true });
  const setLineageStatus = (v: string) => updateParams({ lineage_status: v }, { resetPage: true });
  const setPage = (next: number) => updateParams({ page: next === 1 ? null : String(next) });

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [data, setData] = useState<AuditQueryResponse | null>(null);

  // Build the request query string from the current URL state.
  const queryString = useMemo(() => {
    const p = new URLSearchParams();
    p.set('limit', String(PAGE_SIZE));
    p.set('offset', String((page - 1) * PAGE_SIZE));
    if (from.trim()) {
      const d = new Date(from);
      if (!Number.isNaN(d.getTime())) p.set('from', d.toISOString());
    }
    if (to.trim()) {
      const d = new Date(to);
      if (!Number.isNaN(d.getTime())) p.set('to', d.toISOString());
    }
    if (sqlType && sqlType !== ANY) p.set('sql_type', sqlType);
    if (lineageStatus !== ANY) p.set('lineage_status', lineageStatus);
    if (success === 'warn' || success === 'true') {
      p.set('success', 'true');
      p.set('alias_warning', String(success === 'warn'));
    } else if (success === 'false') {
      p.set('success', 'false');
    }
    if (fileName.trim()) p.set('file_name', fileName.trim());
    if (sourceName.trim()) p.set('source_name', sourceName.trim());
    if (targetTable.trim()) p.set('target_table', targetTable.trim());
    if (urlKeyword.trim()) p.set('keyword', urlKeyword.trim());
    return p.toString();
  }, [
    page,
    from,
    to,
    sqlType,
    success,
    lineageStatus,
    fileName,
    sourceName,
    targetTable,
    urlKeyword,
  ]);

  useEffect(() => {
    const controller = new AbortController();
    const { signal } = controller;
    let timer: number | undefined;
    let shouldPoll = false;

    const fetchList = async (background = false) => {
      // Poll queued writes silently so the table stays readable and interactive.
      if (!background) {
        setLoading(true);
        setError(null);
      }
      try {
        const res = await apiFetch(`/api/audit?${queryString}`, { signal });
        if (signal.aborted) return;
        if (!res.ok) {
          if (res.status === 401 || res.status === 403) shouldPoll = false;
          throw new Error(
            res.status === 401 ? '请先配置有效的访问凭据。' : `Request failed (${res.status})`
          );
        }
        // Guard against the Vite-dev-without-proxy footgun: when `/api/*` is
        // not proxied to the CLI server (default port 3099), the request
        // falls through to the SPA fallback and returns `index.html`. Parsing
        // that as JSON yields a cryptic `Unexpected token '<'`. Detect the
        // HTML shape up front and produce an actionable hint instead.
        const contentType = res.headers.get('content-type') ?? '';
        if (!contentType.includes('application/json')) {
          const preview = (await res.text()).slice(0, 60).replace(/\s+/g, ' ');
          throw new Error(
            `Audit API did not return JSON (got: "${preview}…"). ` +
              'In dev mode make sure the CLI is running on http://localhost:3099 ' +
              'and that Vite has `/api` proxied to it (see app/vite.config.ts).'
          );
        }
        const json = (await res.json()) as AuditQueryResponse;
        if (signal.aborted) return;
        shouldPoll = json.records.some(
          (r) => r.lineage_status === 'queued' || r.usage_status === 'queued'
        );
        setData(json);
        setError(null);
      } catch (e) {
        if (signal.aborted) return;
        setError(e instanceof Error ? e.message : String(e));
        if (!background) setData(null);
      } finally {
        if (!signal.aborted) {
          if (!background) setLoading(false);
          if (shouldPoll) timer = window.setTimeout(() => void fetchList(true), 2000);
        }
      }
    };

    void fetchList();
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [queryString]);

  // Persist the current list URL so "Back to audit list" on the lineage detail
  // can restore the exact same filtered/paginated view even after a hard refresh.
  useEffect(() => {
    const onlyListParams = new URLSearchParams();
    for (const key of URL_PARAM_KEYS) {
      const v = searchParams.get(key);
      if (v !== null && v !== '') onlyListParams.set(key, v);
    }
    try {
      window.localStorage.setItem(LAST_AUDIT_QUERY_KEY, onlyListParams.toString());
    } catch {
      // localStorage may be unavailable (private mode, quota); silently degrade.
    }
  }, [searchParams]);

  const totalPages = data ? Math.max(1, Math.ceil(data.total / PAGE_SIZE)) : 1;

  const openLineage = (id: number) => {
    navigate(`/?auditId=${id}`);
  };

  const resetFilters = () => {
    setFileNameInput('');
    setSourceNameInput('');
    setTargetTableInput('');
    setKeywordInput('');
    setSearchParams(new URLSearchParams(), { replace: true });
  };

  const auditDisabled =
    isBackendMode && backendAuditStorage !== null && !backendAuditStorage.enabled;

  return (
    <div className="flex flex-col h-svh bg-background text-foreground">
      <header className="flex items-center gap-3 px-4 h-12 border-b shrink-0">
        <Button variant="ghost" size="sm" className="gap-1" asChild>
          <Link to="/">
            <ArrowLeft className="size-4" />
            Lineage
          </Link>
        </Button>
        <h1 className="text-sm font-semibold">Audit log</h1>
        <Button variant="outline" size="sm" asChild>
          <Link to="/policies">写入策略</Link>
        </Button>
        <Button variant="ghost" size="sm" className="ml-auto" asChild>
          <Link to="/access">访问凭据</Link>
        </Button>
      </header>

      <div className="flex-1 overflow-auto p-4 space-y-4">
        {auditDisabled && (
          <div
            className="rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-950 dark:text-amber-100"
            data-testid="audit-disabled-banner"
          >
            Audit logging is not enabled on this server. Start FlowScope with{' '}
            <code className="rounded bg-background/60 px-1">--audit-log &lt;path&gt;</code>.
          </div>
        )}

        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">From</label>
            <Input
              type="datetime-local"
              className="h-9 w-[200px] text-xs"
              value={from}
              onChange={(e) => setFrom(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">To</label>
            <Input
              type="datetime-local"
              className="h-9 w-[200px] text-xs"
              value={to}
              onChange={(e) => setTo(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">SQL type</label>
            <Select value={sqlType} onValueChange={setSqlType}>
              <SelectTrigger className="h-9 w-[140px] text-xs">
                <SelectValue placeholder="Any" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ANY}>Any</SelectItem>
                {SQL_TYPE_OPTIONS.map(({ value, label }) => (
                  <SelectItem key={value} value={value}>
                    {label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <label htmlFor="audit-status" className="text-xs text-muted-foreground">
              解析状态
            </label>
            <Select value={success} onValueChange={setSuccess}>
              <SelectTrigger id="audit-status" className="h-9 w-[120px] text-xs">
                <SelectValue placeholder="Any" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ANY}>Any</SelectItem>
                <SelectItem value="true">Success</SelectItem>
                <SelectItem value="warn">Warn</SelectItem>
                <SelectItem value="false">Failed</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <label htmlFor="audit-lineage-status" className="text-xs text-muted-foreground">
              入图状态
            </label>
            <Select value={lineageStatus} onValueChange={setLineageStatus}>
              <SelectTrigger id="audit-lineage-status" className="h-9 w-[160px] text-xs">
                <SelectValue placeholder="全部">
                  {lineageStatus === 'unknown' ? '历史空白记录' : undefined}
                </SelectValue>
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ANY}>全部</SelectItem>
                {Object.entries(INGESTION_STATUS_LABELS).map(([value, label]) => (
                  <SelectItem key={value} value={value}>
                    {label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">File name</label>
            <Input
              className="h-9 w-[200px] text-xs"
              placeholder="Substring…"
              value={fileNameInput}
              onChange={(e) => setFileNameInput(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">Name</label>
            <Input
              className="h-9 w-[180px] text-xs"
              placeholder="sourceName…"
              value={sourceNameInput}
              onChange={(e) => setSourceNameInput(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">Target table</label>
            <Input
              className="h-9 w-[220px] text-xs"
              placeholder="db.table…"
              value={targetTableInput}
              onChange={(e) => setTargetTableInput(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">SQL keyword</label>
            <Input
              className="h-9 w-[220px] text-xs"
              placeholder="Search in SQL…"
              value={keywordInput}
              onChange={(e) => setKeywordInput(e.target.value)}
            />
          </div>
          <Button type="button" variant="outline" size="sm" className="h-9" onClick={resetFilters}>
            Reset
          </Button>
        </div>

        {error && (
          <div className="text-sm text-destructive border border-destructive/30 rounded-md px-3 py-2">
            {error}
          </div>
        )}

        <div className="rounded-md border overflow-hidden">
          <div className="flex items-center justify-between px-3 py-2 bg-muted/40 text-xs border-b">
            <span>
              {data !== null ? (
                <>
                  <span className="font-medium">{data.total}</span> record
                  {data.total === 1 ? '' : 's'}
                  {data.distinct_sql != null && ` · ${data.distinct_sql} distinct SQL`}
                </>
              ) : (
                '—'
              )}
            </span>
            <div className="flex items-center gap-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="h-7 px-2"
                disabled={page <= 1 || loading}
                onClick={() => setPage(Math.max(1, page - 1))}
              >
                <ChevronLeft className="size-4" />
              </Button>
              <span className="text-muted-foreground tabular-nums">
                Page {page} / {totalPages}
              </span>
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="h-7 px-2"
                disabled={loading || !data || page >= totalPages}
                onClick={() => setPage(page + 1)}
              >
                <ChevronRight className="size-4" />
              </Button>
            </div>
          </div>

          <div className="relative overflow-x-auto">
            {loading && (
              <div className="absolute inset-0 z-10 flex items-center justify-center bg-background/60">
                <Loader2 className="size-6 animate-spin text-muted-foreground" />
              </div>
            )}
            <table className="w-full min-w-[1200px] text-left text-xs">
              <thead className="bg-muted/30 text-muted-foreground border-b">
                <tr>
                  <th className="px-3 py-2 font-medium w-10">#</th>
                  <th className="px-3 py-2 font-medium">Time</th>
                  <th className="px-3 py-2 font-medium">File</th>
                  <th className="px-3 py-2 font-medium">Name</th>
                  <th className="px-3 py-2 font-medium">Target table</th>
                  <th className="px-3 py-2 font-medium">Type</th>
                  <th className="px-3 py-2 font-medium">解析</th>
                  <th className="px-3 py-2 font-medium">
                    <span className="inline-flex items-center gap-1 whitespace-nowrap text-foreground">
                      入图状态
                      <GraphIngestionStatusHelp />
                    </span>
                  </th>
                  <th className="px-3 py-2 font-medium">个人使用</th>
                  <th className="px-3 py-2 font-medium">调用方 / 原因</th>
                  <th className="px-3 py-2 font-medium">Endpoint</th>
                  <th className="px-3 py-2 font-medium">Dialect</th>
                  <th className="px-3 py-2 font-medium">ms</th>
                  <th className="px-3 py-2 font-medium">Tables</th>
                  <th className="px-3 py-2 font-medium text-right">Action</th>
                </tr>
              </thead>
              <tbody>
                {data?.records.map((r) => (
                  <tr
                    key={r.id}
                    className={cn('border-b border-border/60 hover:bg-muted/20 cursor-pointer')}
                    onClick={() => openLineage(r.id)}
                  >
                    <td className="px-3 py-2 font-mono text-muted-foreground">{r.id}</td>
                    <td className="px-3 py-2 whitespace-nowrap font-mono" title={r.ts}>
                      {formatLocalTs(r.ts)}
                    </td>
                    <td className="px-3 py-2 max-w-[180px] truncate" title={r.file_name ?? ''}>
                      {r.file_name ?? '—'}
                    </td>
                    <td className="px-3 py-2 max-w-[160px] truncate" title={r.source_name ?? ''}>
                      {r.source_name ?? '—'}
                    </td>
                    <td className="px-3 py-2 max-w-[220px] truncate" title={r.target_table ?? ''}>
                      {r.target_table ?? '—'}
                    </td>
                    <td className="px-3 py-2" title={r.sql_type ?? undefined}>
                      {SQL_TYPE_OPTIONS.find((option) => option.value === r.sql_type)?.label ?? '—'}
                    </td>
                    <td className="px-3 py-2">
                      {!r.success ? (
                        <XCircle
                          role="img"
                          aria-label="Failed"
                          className="size-4 text-destructive"
                        />
                      ) : r.alias_warning ? (
                        <span
                          title="Warn: alias should use backticks"
                          className="inline-flex items-center gap-1 text-amber-600 dark:text-amber-400"
                        >
                          <TriangleAlert aria-hidden="true" className="size-4" /> Warn
                        </span>
                      ) : (
                        <CheckCircle2
                          role="img"
                          aria-label="Success"
                          className="size-4 text-emerald-600"
                        />
                      )}
                    </td>
                    <td className="px-3 py-2 whitespace-nowrap">
                      <GraphIngestionStatus
                        status={r.lineage_status}
                        reason={r.lineage_reason ?? r.policy_reason ?? null}
                        changes={r.graph_changes ?? null}
                      />
                    </td>
                    <td className="px-3 py-2 whitespace-nowrap">{graphStatus(r.usage_status)}</td>
                    <td className="px-3 py-2 max-w-64">
                      <span className="block">{r.principal_id ?? '历史未知身份'}</span>
                      <span
                        className="block break-words text-muted-foreground"
                        title={r.policy_reason ?? ''}
                      >
                        {r.policy_reason}
                      </span>
                    </td>
                    <td className="px-3 py-2 max-w-[140px] truncate">{r.endpoint}</td>
                    <td className="px-3 py-2">{r.dialect}</td>
                    <td className="px-3 py-2 tabular-nums">{r.duration_ms}</td>
                    <td className="px-3 py-2 tabular-nums">{r.table_count ?? '—'}</td>
                    <td className="px-3 py-2 text-right">
                      <Button
                        type="button"
                        variant="secondary"
                        size="sm"
                        className="h-7 text-xs"
                        onClick={(e) => {
                          e.stopPropagation();
                          openLineage(r.id);
                        }}
                      >
                        Open lineage
                      </Button>
                    </td>
                  </tr>
                ))}
                {data && data.records.length === 0 && (
                  <tr>
                    <td colSpan={15} className="px-4 py-8 text-center text-muted-foreground">
                      No audit records match the current filters.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
  );
}
