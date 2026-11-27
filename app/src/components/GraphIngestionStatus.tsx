import { useRef, useState, type ReactNode } from 'react';
import { Portal as TooltipPortal } from '@radix-ui/react-tooltip';
import {
  CheckCircle2,
  CircleHelp,
  Clock3,
  MinusCircle,
  XCircle,
  type LucideIcon,
} from 'lucide-react';
import { Badge, badgeVariants } from '@/components/ui/badge';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';
import { cn } from '@/lib/utils';
import { INGESTION_STATUS_LABELS, type ChangeCounts, type GraphChanges } from '@/lib/lineage-api';
import { explainGraphIngestionReason } from '@/lib/graph-ingestion-reasons';

interface IngestionStatus {
  label: string;
  description: string;
  icon: LucideIcon;
  className: string;
}

const INGESTION_STATUSES = {
  queued: {
    label: INGESTION_STATUS_LABELS.queued,
    description: '策略允许且入图前置检查已通过，正在排队、处理中或等待重试。',
    icon: Clock3,
    className: 'border-status-info/25 bg-status-info/10 text-status-info',
  },
  committed: {
    label: INGESTION_STATUS_LABELS.committed,
    description:
      '正式血缘已确认处理成功。悬停或点击可查看实际新增、更新、删除的节点和关系；已是当前版本时无变更。',
    icon: CheckCircle2,
    className: 'border-status-success/25 bg-status-success/10 text-status-success',
  },
  failed: {
    label: INGESTION_STATUS_LABELS.failed,
    description: '已进入入图流程，但最终失败或被存储规则拒绝。悬停或点击可查看具体原因。',
    icon: XCircle,
    className: 'border-status-error/25 bg-status-error/10 text-status-error',
  },
  not_requested: {
    label: INGESTION_STATUS_LABELS.not_requested,
    description:
      '解析失败、策略不允许或入图前置检查未通过，未执行正式血缘更新。悬停或点击可查看原因。',
    icon: MinusCircle,
    className: 'text-foreground/75',
  },
} satisfies Record<keyof typeof INGESTION_STATUS_LABELS, IngestionStatus>;

type IngestionStatusKey = keyof typeof INGESTION_STATUSES;

function statusKey(value?: string | null, reason?: string | null): IngestionStatusKey | null {
  // Legacy API values remain readable during a frontend/backend version change.
  if (value === 'blocked_policy') return 'not_requested';
  if (value === 'blocked')
    return reason === 'parse_failed' || reason?.startsWith('incomplete_analysis:')
      ? 'not_requested'
      : 'failed';
  return value && Object.prototype.hasOwnProperty.call(INGESTION_STATUSES, value)
    ? (value as IngestionStatusKey)
    : null;
}

function ChangeTable({
  title,
  groups,
  total,
}: {
  title: string;
  groups: Record<string, ChangeCounts>;
  total: ChangeCounts;
}) {
  return (
    <table className="w-full text-xs tabular-nums">
      <caption className="pb-2 text-left text-sm font-medium">{title}</caption>
      <thead>
        <tr className="border-b text-foreground/75">
          <th scope="col" className="pb-1 text-left font-normal">
            分组
          </th>
          <th scope="col" className="pb-1 text-right font-normal">
            新增
          </th>
          <th scope="col" className="pb-1 text-right font-normal">
            更新
          </th>
          <th scope="col" className="pb-1 text-right font-normal">
            删除
          </th>
        </tr>
      </thead>
      <tbody>
        {[...Object.entries(groups), ['合计', total] as const].map(([name, count]) => (
          <tr key={name} className={name === '合计' ? 'border-t font-medium' : ''}>
            <th scope="row" className="break-all py-1 pr-2 text-left font-normal">
              {name}
            </th>
            <td className="py-1 text-right">{count.created}</td>
            <td className="py-1 text-right">{count.updated}</td>
            <td className="py-1 text-right">{count.deleted}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function GraphChangeSummary({ changes }: { changes?: GraphChanges | null }) {
  if (!changes) return <p className="text-sm">该次入图未记录变更统计。</p>;
  const noChanges = [changes.nodeTotals, changes.relationshipTotals].every(
    (count) => count.created === 0 && count.updated === 0 && count.deleted === 0
  );
  return (
    <div className="space-y-4" data-testid="ingestion-changes">
      <p className="text-xs text-foreground/75">
        本次入图请求的业务变更，不含内部事件、版本和锁。仅刷新维护时间不计为更新。
      </p>
      {noChanges && <p className="text-sm">本次无变更，正式血缘已是当前版本。</p>}
      <ChangeTable
        title="节点（按 label 标签）"
        groups={changes.nodes}
        total={changes.nodeTotals}
      />
      <ChangeTable
        title="关系（按 type 类型）"
        groups={changes.relationships}
        total={changes.relationshipTotals}
      />
    </div>
  );
}

export function GraphIngestionStatus({
  status,
  reason,
  changes,
}: {
  status?: string | null;
  reason?: string | null;
  changes?: GraphChanges | null;
}) {
  const key = statusKey(status, reason);
  if (!key) return null;
  const item = INGESTION_STATUSES[key];
  const Icon = item.icon;
  const content = (
    <>
      <Icon className="size-3.5" aria-hidden="true" />
      {item.label}
    </>
  );
  const canExplain =
    (reason !== undefined || changes !== undefined) &&
    (key === 'committed' || key === 'not_requested' || key === 'failed' || Boolean(reason?.trim()));
  if (!canExplain) {
    return (
      <Badge
        variant="outline"
        className={cn('gap-1.5 whitespace-nowrap', item.className)}
        title={item.description}
        data-ingestion-status={key}
      >
        {content}
      </Badge>
    );
  }
  const issues = explainGraphIngestionReason(reason);
  return (
    <StatusExplanation
      label={key === 'committed' ? '查看入图变更统计' : `查看${item.label}原因`}
      status={key}
      testPrefix="ingestion-reason"
      triggerClassName={cn(
        badgeVariants({ variant: 'outline' }),
        'gap-1.5 whitespace-nowrap hover:brightness-95',
        item.className
      )}
      panelWidth="w-96"
      content={
        <div className="space-y-3 text-left font-normal">
          <p className="text-sm font-medium">
            {key === 'committed' ? '本次入图变更统计' : `${item.label}原因`}
          </p>
          <p className="text-xs leading-relaxed text-foreground/75">{item.description}</p>
          {key === 'committed' ? (
            <GraphChangeSummary changes={changes} />
          ) : issues.length ? (
            <ul className="space-y-3 text-sm">
              {issues.map((issue, index) => (
                <li key={index} className="break-words">
                  <p>{issue.label}</p>
                  {issue.detail && (
                    <p className="mt-1 break-all text-xs text-foreground/75">{issue.detail}</p>
                  )}
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm">后台尚未记录具体原因。</p>
          )}
          {reason?.trim() && (
            <details className="border-t pt-2">
              <summary className="cursor-pointer text-xs text-foreground/75">原始原因</summary>
              <pre className="mt-2 whitespace-pre-wrap break-all text-xs leading-relaxed">
                {reason}
              </pre>
            </details>
          )}
        </div>
      }
    >
      {content}
      <CircleHelp className="size-3 opacity-70" aria-hidden="true" />
    </StatusExplanation>
  );
}

function StatusLegend() {
  return (
    <div className="flex flex-col gap-3 text-left">
      <div>
        <p className="font-medium">入图状态说明</p>
        <p className="mt-1 text-xs text-foreground/75">
          表示本次请求的正式血缘写入结果。解析成功不代表已入图。
        </p>
      </div>
      <dl className="flex flex-col gap-2.5">
        {Object.entries(INGESTION_STATUSES).map(([key, item]) => (
          <div key={key} className="flex flex-col gap-1">
            <dt>
              <GraphIngestionStatus status={key} />
            </dt>
            <dd className="text-xs leading-relaxed text-foreground/75">{item.description}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

export function GraphIngestionStatusHelp() {
  return (
    <StatusExplanation
      label="入图状态说明"
      testPrefix="ingestion-status"
      triggerClassName="size-7 shrink-0 hover:bg-accent/10"
      content={<StatusLegend />}
    >
      <CircleHelp className="size-4" aria-hidden="true" />
    </StatusExplanation>
  );
}

/** Shared hover/focus tooltip and click/touch panel; clicks must not open the audit row. */
function StatusExplanation({
  label,
  children,
  content,
  triggerClassName,
  testPrefix,
  status,
  panelWidth = 'w-80',
}: {
  label: string;
  children: ReactNode;
  content: ReactNode;
  triggerClassName: string;
  testPrefix: string;
  status?: IngestionStatusKey;
  panelWidth?: string;
}) {
  const [popoverOpen, setPopoverOpen] = useState(false);
  const [tooltipOpen, setTooltipOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  return (
    <TooltipProvider delayDuration={200}>
      <Popover
        open={popoverOpen}
        onOpenChange={(open) => {
          setPopoverOpen(open);
          setTooltipOpen(false);
        }}
      >
        <Tooltip open={tooltipOpen && !popoverOpen} onOpenChange={setTooltipOpen}>
          <TooltipTrigger asChild>
            <PopoverTrigger asChild>
              <button
                ref={trigger}
                type="button"
                aria-label={label}
                data-ingestion-status={status}
                className={cn(
                  'inline-flex cursor-pointer items-center justify-center rounded-full transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2',
                  triggerClassName
                )}
                onClick={(event) => event.stopPropagation()}
              >
                {children}
              </button>
            </PopoverTrigger>
          </TooltipTrigger>
          {!popoverOpen && (
            <TooltipPortal>
              <TooltipContent
                data-testid={`${testPrefix}-tooltip`}
                side="bottom"
                align="start"
                onClick={(event) => event.stopPropagation()}
                className={cn(
                  'max-h-[var(--radix-tooltip-content-available-height)] max-w-[calc(100vw-2rem)] overflow-y-auto p-4 font-normal motion-reduce:animate-none',
                  panelWidth
                )}
              >
                {content}
              </TooltipContent>
            </TooltipPortal>
          )}
        </Tooltip>
        <PopoverContent
          data-testid={`${testPrefix}-popover`}
          side="bottom"
          align="start"
          aria-label={label}
          onClick={(event) => event.stopPropagation()}
          className={cn(
            'max-h-[var(--radix-popover-content-available-height)] max-w-[calc(100vw-2rem)] overflow-y-auto motion-reduce:animate-none',
            panelWidth
          )}
          onCloseAutoFocus={(event) => {
            event.preventDefault();
            trigger.current?.focus();
            setTooltipOpen(false);
          }}
        >
          {content}
        </PopoverContent>
      </Popover>
    </TooltipProvider>
  );
}
