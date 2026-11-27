import { useEffect, useState, type FormEvent } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { apiJson } from '@/lib/lineage-api';

interface AuditSettings {
  retentionDays: number;
}

export function AuditRetentionSettings() {
  const [saved, setSaved] = useState<number | null>(null);
  const [days, setDays] = useState('');
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError('');
    void apiJson<AuditSettings>('/api/audit/settings')
      .then((settings) => {
        if (!active) return;
        setSaved(settings.retentionDays);
        setDays(String(settings.retentionDays));
      })
      .catch((e: unknown) => {
        if (active) setError(e instanceof Error ? e.message : String(e));
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [reload]);

  async function save(event: FormEvent) {
    event.preventDefault();
    const retentionDays = Number(days);
    setNotice('');
    if (!Number.isSafeInteger(retentionDays) || retentionDays < 1) {
      setError('保留天数必须为正整数。');
      return;
    }
    setSaving(true);
    setError('');
    try {
      const settings = await apiJson<AuditSettings>('/api/audit/settings', { retentionDays });
      setSaved(settings.retentionDays);
      setDays(String(settings.retentionDays));
      setNotice('已保存，过期审计日志将在后台分批清理。');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="mt-6 border-t pt-5" aria-labelledby="audit-retention-heading">
      <h3 id="audit-retention-heading" className="font-semibold">
        审计日志保留
      </h3>
      <p
        id="audit-retention-description"
        className="mt-2 max-w-prose text-sm text-muted-foreground"
      >
        全局设置，默认保留 7 天。超过保留时间的审计日志和解析结果将自动删除，已提交血缘不受影响。
        待处理事件的日志会保留至处理结束。
      </p>
      <form className="mt-4" onSubmit={(event) => void save(event)}>
        <label htmlFor="audit-retention-days" className="mb-2 block text-sm">
          保留天数
        </label>
        <div className="flex flex-wrap items-center gap-2">
          <Input
            id="audit-retention-days"
            aria-describedby="audit-retention-description"
            className="w-24"
            type="number"
            min={1}
            step={1}
            required
            value={days}
            disabled={loading || saving || saved === null}
            onChange={(event) => {
              setDays(event.target.value);
              setError('');
              setNotice('');
            }}
          />
          <span className="text-sm text-muted-foreground">天</span>
          <Button
            type="submit"
            variant="outline"
            className="bg-background! text-foreground!"
            disabled={loading || saving || saved === null || Number(days) === saved}
          >
            {saving ? '保存中…' : '保存保留天数'}
          </Button>
        </div>
      </form>
      {loading && (
        <p role="status" className="mt-3 text-sm text-muted-foreground">
          正在加载保留设置…
        </p>
      )}
      {error && (
        <div role="alert" className="mt-3 text-sm text-destructive">
          {error}
          {saved === null && (
            <Button variant="link" onClick={() => setReload((value) => value + 1)}>
              重新加载
            </Button>
          )}
        </div>
      )}
      {notice && (
        <p role="status" className="mt-3 text-sm text-emerald-700 dark:text-emerald-400">
          {notice}
        </p>
      )}
    </section>
  );
}
