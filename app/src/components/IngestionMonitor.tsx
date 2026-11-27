import { useEffect, useState } from 'react';
import { apiFetch } from '@/lib/lineage-api';
import { formatLocalTs } from '@/lib/utils';

export interface IngestionSnapshot {
  scope: 'all' | 'own';
  action: 'publish' | 'record_usage';
  sampledAt: string;
  lastAcceptedAt: string | null;
  queued: number;
  retrying: number;
  blocked: number;
  failed: number;
  committed: number;
  rate: {
    monitoringSince: string;
    windowSeconds: number;
    observedSeconds: number;
    warmingUp: boolean;
    confirmedEvents: number;
    eventsPerMinute: number | null;
  };
}

/** Independent of list filters: an empty page must still show live ingestion. */
export function IngestionMonitor({ onActivityChange }: { onActivityChange?: () => void }) {
  const [snapshot, setSnapshot] = useState<IngestionSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    let timer: number | undefined;
    let stopped = false;
    let previousActivity: string | undefined;
    const refresh = async () => {
      try {
        const response = await apiFetch('/api/lineage/metrics', { signal: controller.signal });
        if (controller.signal.aborted) return;
        if (!response.ok) {
          if ([401, 403, 404, 503].includes(response.status)) {
            stopped = true;
            setSnapshot(null);
          }
          throw new Error(
            response.status === 401 || response.status === 403
              ? '当前凭据无法读取入图监测。'
              : response.status === 404 || response.status === 503
                ? '当前服务未提供入图监测。'
                : `入图监测更新失败（${response.status}）。`
          );
        }
        if (!(response.headers.get('content-type') ?? '').includes('application/json')) {
          throw new Error('入图监测接口未返回 JSON。');
        }
        const value: IngestionSnapshot = await response.json();
        if (controller.signal.aborted) return;
        const activity = JSON.stringify([
          value.lastAcceptedAt,
          value.queued,
          value.blocked,
          value.failed,
          value.committed,
        ]);
        if (previousActivity !== undefined && previousActivity !== activity) onActivityChange?.();
        previousActivity = activity;
        setSnapshot(value);
        setError(null);
      } catch (e) {
        if (!controller.signal.aborted) {
          setError(e instanceof Error ? e.message : String(e));
        }
      } finally {
        if (!controller.signal.aborted && !stopped) {
          timer = window.setTimeout(() => void refresh(), 5000);
        }
      }
    };
    void refresh();
    return () => {
      stopped = true;
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [onActivityChange]);

  return (
    <section aria-label="入图运行情况" className="rounded-md border px-3 py-2 text-xs">
      {!snapshot ? (
        <span className="text-muted-foreground">{error ?? '正在读取入图运行情况…'}</span>
      ) : (
        <>
          <div className="flex flex-wrap items-baseline gap-x-5 gap-y-2">
            <span className="font-medium">
              {snapshot.action === 'publish' ? '正式血缘' : '个人使用'}
              <span className="ml-2 font-normal text-muted-foreground">
                {snapshot.scope === 'all' ? '全部调用方' : '当前调用方'}
              </span>
            </span>
            <span title="近 60 秒首次确认成功的去重事件数。重试不重复计数，检查阻止和仅存证不计入。统计从本次服务启动开始。">
              入图速率{' '}
              <strong className="tabular-nums">
                {snapshot.rate.warmingUp || snapshot.rate.eventsPerMinute === null
                  ? '统计预热中'
                  : `${snapshot.rate.eventsPerMinute.toLocaleString()} 条/分钟`}
              </strong>
            </span>
            <span>
              待处理 <strong className="tabular-nums">{snapshot.queued}</strong>
            </span>
            <span title="待处理事件中，已经失败过并将继续重试的数量。">
              其中重试 <strong className="tabular-nums">{snapshot.retrying}</strong>
            </span>
            <span title="被解析检查或调用策略阻止，不会自动重试，不属于待处理队列。">
              检查阻止 <strong className="tabular-nums">{snapshot.blocked}</strong>
            </span>
            <span>
              失败 <strong className="tabular-nums">{snapshot.failed}</strong>
            </span>
          </div>
          <p className="mt-2 text-muted-foreground">
            最近接收：
            {snapshot.lastAcceptedAt ? formatLocalTs(snapshot.lastAcceptedAt) : '暂无记录'}
            {' · '}
            {snapshot.rate.warmingUp
              ? `已观测 ${snapshot.rate.observedSeconds} 秒，满 60 秒显示速率`
              : `近 60 秒确认 ${snapshot.rate.confirmedEvents} 个事件`}
            {' · '}不受下方列表筛选影响，每 5 秒更新
          </p>
          {error && (
            <p role="status" className="mt-1 text-destructive">
              {error} 当前保留 {formatLocalTs(snapshot.sampledAt)} 的结果。
            </p>
          )}
        </>
      )}
    </section>
  );
}
