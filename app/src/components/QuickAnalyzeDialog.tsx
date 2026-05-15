import { useState, startTransition } from 'react';
import { Loader2, Zap } from 'lucide-react';
import { SqlView, useLineageActions } from '@pondpilot/flowscope-react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { useBackend } from '@/lib/backend-context';
import { useProject } from '@/lib/project-store';
import { useThemeStore, resolveTheme } from '@/lib/theme-store';

interface QuickAnalyzeDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}


export function QuickAnalyzeDialog({ open, onOpenChange }: QuickAnalyzeDialogProps) {
  const [sql, setSql] = useState('');
  const [isAnalyzing, setIsAnalyzing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const { adapter, ready } = useBackend();
  const { currentProject } = useProject();
  const theme = useThemeStore((s) => s.theme);
  const isDark = resolveTheme(theme) === 'dark';

  const { setResult, setAnalyzedContent, setStalePaths } = useLineageActions();

  const handleAnalyze = async () => {
    const trimmed = sql.trim();
    if (!trimmed || !adapter) return;

    setIsAnalyzing(true);
    setError(null);

    try {
      const payload = {
        files: [{ name: '__quick__.sql', content: trimmed }],
        dialect: currentProject?.dialect ?? 'ansi',
        schemaSQL: currentProject?.schemaSQL ?? '',
        hideCTEs: false,
        enableColumnLineage: true,
      };

      const response = await adapter.analyze(payload);

      if (response.result) {
        startTransition(() => {
          setResult(response.result);
          setAnalyzedContent(new Map([['__quick__.sql', trimmed]]));
          setStalePaths([]);
        });
        onOpenChange(false);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : '分析失败，请检查 SQL 语法');
    } finally {
      setIsAnalyzing(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-3xl h-[580px] flex flex-col gap-0 p-0">
        <DialogHeader className="px-5 pt-5 pb-3 shrink-0">
          <DialogTitle className="flex items-center gap-2 text-base">
            <Zap className="h-4 w-4 text-brand-blue-500" />
            Quick Analyze
          </DialogTitle>
          <DialogDescription className="text-xs">
            粘贴 SQL → 点击 Analyze，结果直接显示在右侧面板
          </DialogDescription>
        </DialogHeader>

        {/* SQL 编辑区 */}
        <div className="flex-1 min-h-0 border-y mx-0 overflow-hidden">
          <SqlView
            value={sql}
            onChange={setSql}
            className="h-full text-sm"
            editable
            isDark={isDark}
          />
        </div>

        {/* 底部操作栏 */}
        <div className="flex items-center justify-between px-5 py-3 shrink-0">
          <div className="text-xs text-muted-foreground">
            {error ? (
              <span className="text-destructive">{error}</span>
            ) : (
              <span>支持单条或多条 SQL；dialect 跟随当前项目配置</span>
            )}
          </div>
          <div className="flex items-center gap-2">
            <Button variant="outline" size="sm" onClick={() => onOpenChange(false)}>
              取消
            </Button>
            <Button
              size="sm"
              disabled={!sql.trim() || isAnalyzing || !ready}
              onClick={handleAnalyze}
              className="gap-1.5 bg-brand-blue-500 hover:bg-brand-blue-700 text-white"
            >
              {isAnalyzing ? (
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
              ) : (
                <Zap className="h-3.5 w-3.5" />
              )}
              Analyze
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
