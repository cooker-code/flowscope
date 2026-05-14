import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ArrowLeft, CheckCircle2, ChevronLeft, ChevronRight, Loader2, XCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';
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
import { cn } from '@/lib/utils';

const PAGE_SIZE = 50;

const ANY = '__any__';
const SQL_TYPE_OPTIONS = ['SELECT', 'INSERT', 'WITH', 'CREATE', 'UPDATE', 'DELETE', 'MERGE'];

interface AuditListRecord {
  id: number;
  ts: string;
  endpoint: string;
  dialect: string;
  file_name: string | null;
  sql_type: string | null;
  success: boolean;
  duration_ms: number;
  table_count: number | null;
}

interface AuditQueryResponse {
  total: number;
  records: AuditListRecord[];
}

export function AuditPage() {
  const navigate = useNavigate();
  const { isBackendMode, backendAuditStorage } = useProject();

  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [sqlType, setSqlType] = useState(ANY);
  const [success, setSuccess] = useState(ANY);
  const [fileName, setFileName] = useState('');
  const [keyword, setKeyword] = useState('');
  const debouncedKeyword = useDebounce(keyword, 300);

  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [data, setData] = useState<AuditQueryResponse | null>(null);

  useEffect(() => {
    setPage(1);
  }, [from, to, sqlType, success, fileName, debouncedKeyword]);

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
    if (success === 'true' || success === 'false') p.set('success', success);
    if (fileName.trim()) p.set('file_name', fileName.trim());
    if (debouncedKeyword.trim()) p.set('keyword', debouncedKeyword.trim());
    return p.toString();
  }, [page, from, to, sqlType, success, fileName, debouncedKeyword]);

  const fetchList = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(`/api/audit?${queryString}`);
      if (!res.ok) {
        setError(`Request failed (${res.status})`);
        setData(null);
        return;
      }
      const json = (await res.json()) as AuditQueryResponse;
      setData(json);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setData(null);
    } finally {
      setLoading(false);
    }
  }, [queryString]);

  useEffect(() => {
    void fetchList();
  }, [fetchList]);

  const totalPages = data ? Math.max(1, Math.ceil(data.total / PAGE_SIZE)) : 1;

  const openLineage = (id: number) => {
    navigate(`/?auditId=${id}`);
  };

  const resetFilters = () => {
    setFrom('');
    setTo('');
    setSqlType(ANY);
    setSuccess(ANY);
    setFileName('');
    setKeyword('');
    setPage(1);
  };

  const auditDisabled = isBackendMode && backendAuditStorage !== null && !backendAuditStorage.enabled;

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
                {SQL_TYPE_OPTIONS.map((t) => (
                  <SelectItem key={t} value={t}>
                    {t}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">Success</label>
            <Select value={success} onValueChange={setSuccess}>
              <SelectTrigger className="h-9 w-[120px] text-xs">
                <SelectValue placeholder="Any" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ANY}>Any</SelectItem>
                <SelectItem value="true">Success</SelectItem>
                <SelectItem value="false">Failed</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">File name</label>
            <Input
              className="h-9 w-[200px] text-xs"
              placeholder="Substring…"
              value={fileName}
              onChange={(e) => setFileName(e.target.value)}
            />
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">SQL keyword</label>
            <Input
              className="h-9 w-[220px] text-xs"
              placeholder="Search in SQL…"
              value={keyword}
              onChange={(e) => setKeyword(e.target.value)}
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
                onClick={() => setPage((p) => Math.max(1, p - 1))}
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
                onClick={() => setPage((p) => p + 1)}
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
            <table className="w-full text-left text-xs">
              <thead className="bg-muted/30 text-muted-foreground border-b">
                <tr>
                  <th className="px-3 py-2 font-medium w-10">#</th>
                  <th className="px-3 py-2 font-medium">Time</th>
                  <th className="px-3 py-2 font-medium">Endpoint</th>
                  <th className="px-3 py-2 font-medium">Dialect</th>
                  <th className="px-3 py-2 font-medium">File</th>
                  <th className="px-3 py-2 font-medium">Type</th>
                  <th className="px-3 py-2 font-medium">OK</th>
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
                    <td className="px-3 py-2 whitespace-nowrap font-mono">{r.ts}</td>
                    <td className="px-3 py-2 max-w-[140px] truncate">{r.endpoint}</td>
                    <td className="px-3 py-2">{r.dialect}</td>
                    <td className="px-3 py-2 max-w-[180px] truncate" title={r.file_name ?? ''}>
                      {r.file_name ?? '—'}
                    </td>
                    <td className="px-3 py-2">{r.sql_type ?? '—'}</td>
                    <td className="px-3 py-2">
                      {r.success ? (
                        <CheckCircle2 className="size-4 text-emerald-600" />
                      ) : (
                        <XCircle className="size-4 text-destructive" />
                      )}
                    </td>
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
                    <td colSpan={10} className="px-4 py-8 text-center text-muted-foreground">
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
