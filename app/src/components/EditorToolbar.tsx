import { Play, Loader2, ChevronDown, Braces, Code } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
} from '@/components/ui/dropdown-menu';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';
import { FileSelector } from './FileSelector';
import { SqlPreviewCapsule } from './SqlPreviewCapsule';
import { DIALECT_OPTIONS, isValidDialect } from '@/lib/project-store';
import type { AnalyzeResult } from '@pondpilot/flowscope-core';
import type { Dialect } from '@pondpilot/flowscope-core';

export type SqlViewMode = 'template' | 'resolved';

interface EditorToolbarProps {
  isAnalyzing: boolean;
  backendReady: boolean;
  onAnalyze: () => void;
  fileSelectorOpen: boolean;
  onFileSelectorOpenChange: (open: boolean) => void;
  sqlViewMode?: SqlViewMode;
  onSqlViewModeChange?: (mode: SqlViewMode) => void;
  showSqlViewToggle?: boolean;
  hasResolvedSql?: boolean;
  setResultFromCache?: (result: AnalyzeResult) => void;
  /** Audit deep-link: replaces file selector */
  auditId?: string | null;
  /** In backend (CLI serve) mode the file selector is hidden */
  isBackendMode?: boolean;
  /** Active file name shown in backend mode instead of the selector */
  activeFileName?: string;
  /** Current SQL dialect */
  dialect?: Dialect;
  /** Called when user picks a different dialect */
  onDialectChange?: (dialect: Dialect) => void;
}

export function EditorToolbar({
  isAnalyzing,
  backendReady,
  onAnalyze,
  fileSelectorOpen,
  onFileSelectorOpenChange,
  sqlViewMode = 'template',
  onSqlViewModeChange,
  showSqlViewToggle = false,
  hasResolvedSql = false,
  setResultFromCache,
  auditId,
  isBackendMode = false,
  activeFileName,
  dialect,
  onDialectChange,
}: EditorToolbarProps) {
  return (
    <div className="flex items-center justify-between px-3 py-2 border-b h-[44px] shrink-0 bg-muted/30 overflow-hidden gap-2">
      <div className="flex items-center gap-2 min-w-0 flex-1">
        {auditId ? (
          <SqlPreviewCapsule auditId={auditId} />
        ) : isBackendMode ? (
          <span className="text-xs text-muted-foreground truncate px-1">
            {activeFileName ?? 'stdin.sql'}
          </span>
        ) : (
          <FileSelector
            open={fileSelectorOpen}
            onOpenChange={onFileSelectorOpenChange}
            setResultFromCache={setResultFromCache}
          />
        )}

        {showSqlViewToggle && (
          <TooltipProvider>
            <Tooltip>
              <TooltipTrigger asChild>
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-7 w-7 p-0"
                  disabled={!hasResolvedSql || !onSqlViewModeChange}
                  aria-label={
                    sqlViewMode === 'template'
                      ? 'Switch to resolved SQL view'
                      : 'Switch to template SQL view'
                  }
                  aria-pressed={sqlViewMode === 'resolved'}
                  onClick={() => {
                    onSqlViewModeChange?.(sqlViewMode === 'template' ? 'resolved' : 'template');
                  }}
                >
                  {sqlViewMode === 'template' ? (
                    <Braces className="h-4 w-4" />
                  ) : (
                    <Code className="h-4 w-4" />
                  )}
                </Button>
              </TooltipTrigger>
              <TooltipContent>
                {!hasResolvedSql ? (
                  <p>Run analysis to see resolved SQL</p>
                ) : sqlViewMode === 'template' ? (
                  <p>Viewing template SQL. Click to see resolved.</p>
                ) : (
                  <p>Viewing resolved SQL. Click to see template.</p>
                )}
              </TooltipContent>
            </Tooltip>
          </TooltipProvider>
        )}
      </div>

      <div className="flex items-center gap-2 shrink-0">
        <div className="flex items-center rounded-full overflow-hidden shadow-xs">
          <Button
            onClick={onAnalyze}
            disabled={!backendReady || isAnalyzing}
            size="sm"
            className="h-[34px] gap-1.5 bg-brand-blue-500 hover:bg-brand-blue-700 text-white font-medium rounded-none rounded-l-full border-r border-brand-blue-400/30 px-3"
          >
            {isAnalyzing ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" />
            ) : (
              <Play className="h-3.5 w-3.5 fill-current" />
            )}
            <span className="hidden sm:inline">Lineage</span>
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button
                size="sm"
                className="h-[34px] px-3 bg-brand-blue-500 hover:bg-brand-blue-700 text-white rounded-none rounded-r-full border-l border-brand-blue-700/30"
                disabled={!backendReady || isAnalyzing}
              >
                <ChevronDown className="size-3.5" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuLabel>SQL Dialect</DropdownMenuLabel>
              <DropdownMenuSeparator />
              <DropdownMenuRadioGroup
                value={dialect ?? 'generic'}
                onValueChange={(v) => {
                  if (isValidDialect(v)) onDialectChange?.(v);
                }}
              >
                {DIALECT_OPTIONS.map((opt) => (
                  <DropdownMenuRadioItem key={opt.value} value={opt.value} className="text-xs">
                    {opt.label}
                  </DropdownMenuRadioItem>
                ))}
              </DropdownMenuRadioGroup>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>
    </div>
  );
}
