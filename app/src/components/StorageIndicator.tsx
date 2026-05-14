import { Database } from 'lucide-react';
import type { AuditStorageInfo } from '@/hooks/useBackendFiles';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';

function formatStorageLabel(type: string | null): string {
  if (!type) return 'Database';
  const t = type.toLowerCase();
  if (t === 'sqlite') return 'SQLite';
  if (t === 'mysql') return 'MySQL';
  if (t === 'postgres') return 'PostgreSQL';
  return type.charAt(0).toUpperCase() + type.slice(1);
}

interface StorageIndicatorProps {
  audit: AuditStorageInfo | null;
}

/**
 * Serve-mode header chip: storage kind + truncated path (full path in tooltip).
 * Hidden when audit logging is disabled.
 */
export function StorageIndicator({ audit }: StorageIndicatorProps) {
  if (!audit?.enabled || !audit.location) {
    return null;
  }

  const label = formatStorageLabel(audit.type);
  const path = audit.location;

  return (
    <TooltipProvider delayDuration={300}>
      <Tooltip>
        <TooltipTrigger asChild>
          <div
            className="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm max-w-[320px] min-w-0"
            data-testid="serve-mode-indicator"
            data-audit-storage="true"
          >
            <div className="flex size-6 shrink-0 items-center justify-center rounded-md border bg-background">
              <Database className="size-3.5 text-muted-foreground" />
            </div>
            <span className="font-medium shrink-0">{label}</span>
            <span className="text-muted-foreground truncate text-xs font-mono">{path}</span>
          </div>
        </TooltipTrigger>
        <TooltipContent side="bottom" align="start" className="max-w-lg">
          <p className="text-xs whitespace-pre-wrap break-all font-mono">{path}</p>
        </TooltipContent>
      </Tooltip>
    </TooltipProvider>
  );
}
