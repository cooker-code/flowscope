import { useCallback, useEffect, useState } from 'react';
import { ChevronRight } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Separator } from '@/components/ui/separator';
import { LAST_AUDIT_QUERY_KEY } from '@/pages/AuditPage';
import { formatLocalTs } from '@/lib/utils';

interface AuditDetail {
  id: number;
  ts: string;
  dialect: string;
  file_name: string | null;
  source_name: string | null;
  sql_type: string | null;
  success: boolean;
  duration_ms: number;
  table_count: number | null;
  has_cte: boolean;
  sql_text: string;
}

interface SqlPreviewCapsuleProps {
  auditId: string;
}

export function SqlPreviewCapsule({ auditId }: SqlPreviewCapsuleProps) {
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const [detail, setDetail] = useState<AuditDetail | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  const loadDetail = useCallback(async () => {
    setLoadError(null);
    try {
      const res = await fetch(`/api/audit/${auditId}`);
      if (!res.ok) {
        setLoadError(`HTTP ${res.status}`);
        setDetail(null);
        return;
      }
      const data = (await res.json()) as AuditDetail;
      setDetail(data);
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : String(e));
      setDetail(null);
    }
  }, [auditId]);

  useEffect(() => {
    void loadDetail();
  }, [loadDetail]);

  const sqlType = detail?.sql_type ?? '—';

  return (
    <>
      <Button
        type="button"
        variant="outline"
        size="sm"
        className="h-[30px] max-w-full rounded-full border-border-primary-light dark:border-border-primary-dark px-3 text-xs font-normal gap-1"
        data-testid="sql-preview-capsule"
        onClick={() => {
          setOpen(true);
          void loadDetail();
        }}
      >
        <span className="truncate font-mono">audit#{auditId}</span>
        <span className="text-muted-foreground shrink-0">·</span>
        <span className="truncate shrink-0 max-w-[100px]">{sqlType}</span>
        <ChevronRight className="size-3.5 shrink-0 opacity-60" />
      </Button>

      <Sheet open={open} onOpenChange={setOpen}>
        <SheetContent side="right" className="w-full sm:max-w-lg flex flex-col gap-0 p-0">
          <SheetHeader className="p-6 pb-2 space-y-1">
            <SheetTitle className="text-base">Audit record #{auditId}</SheetTitle>
            <SheetDescription
              className="text-xs font-mono break-all"
              title={detail?.ts ?? undefined}
            >
              {formatLocalTs(detail?.ts)}
            </SheetDescription>
          </SheetHeader>

          <div className="px-6 pb-4 flex flex-wrap gap-2 text-xs">
            <Button
              variant="link"
              className="h-auto p-0 text-xs"
              onClick={() => {
                // Restore the filters/page the user had on the list page (saved
                // by AuditPage to localStorage). Falls back to a bare /audit
                // when there's no recorded query (e.g. user landed on
                // /?auditId=N directly via a shared link).
                let saved = '';
                try {
                  saved = window.localStorage.getItem(LAST_AUDIT_QUERY_KEY) ?? '';
                } catch {
                  // ignore
                }
                navigate(saved ? `/audit?${saved}` : '/audit');
              }}
            >
              Back to audit list
            </Button>
          </div>

          <Separator />

          <div className="px-6 py-3 text-xs text-muted-foreground space-y-1">
            {loadError && <p className="text-destructive">Failed to load: {loadError}</p>}
            {detail && (
              <>
                <p>
                  <span className="font-medium text-foreground">Dialect:</span> {detail.dialect}
                </p>
                <p>
                  <span className="font-medium text-foreground">File:</span>{' '}
                  {detail.file_name ?? '(inline)'}
                </p>
                <p>
                  <span className="font-medium text-foreground">Name:</span>{' '}
                  {detail.source_name ?? '—'}
                </p>
                <p>
                  <span className="font-medium text-foreground">SQL type:</span>{' '}
                  {detail.sql_type ?? '—'}
                </p>
                <p>
                  <span className="font-medium text-foreground">Success:</span>{' '}
                  {detail.success ? 'yes' : 'no'}
                </p>
                <p>
                  <span className="font-medium text-foreground">Duration:</span> {detail.duration_ms}{' '}
                  ms
                </p>
                <p>
                  <span className="font-medium text-foreground">Tables:</span>{' '}
                  {detail.table_count ?? '—'}
                </p>
                <p>
                  <span className="font-medium text-foreground">CTE:</span>{' '}
                  {detail.has_cte ? 'yes' : 'no'}
                </p>
              </>
            )}
          </div>

          <Separator />

          <ScrollArea className="flex-1 min-h-0 px-6 py-4">
            <pre className="text-xs font-mono whitespace-pre-wrap break-words pr-4">
              {detail?.sql_text ?? 'Loading…'}
            </pre>
          </ScrollArea>
        </SheetContent>
      </Sheet>
    </>
  );
}
