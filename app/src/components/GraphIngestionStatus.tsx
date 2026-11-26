import { useRef, useState, type ReactNode } from 'react';
import { Portal as TooltipPortal } from '@radix-ui/react-tooltip';
import {
  Ban,
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
import { INGESTION_STATUS_LABELS } from '@/lib/lineage-api';
import { explainGraphIngestionReason } from '@/lib/graph-ingestion-reasons';

interface IngestionStatus {
  label: string;
  description: string;
  icon: LucideIcon;
  className: string;
}

const INGESTION_STATUSES = {
  committed: {
    label: INGESTION_STATUS_LABELS.committed,
    description: '本次请求的正式血缘已成功写入 Neo4j。',
    icon: CheckCircle2,
    className: 'border-status-success/25 bg-status-success/10 text-status-success',
  },
  queued: {
    label: INGESTION_STATUS_LABELS.queued,
    description: '请求已受理，正在排队、入图处理或等待重试，尚未确认提交成功。',
    icon: Clock3,
    className: 'border-status-info/25 bg-status-info/10 text-status-info',
  },
  blocked: {
    label: INGESTION_STATUS_LABELS.blocked,
    description:
      '本次请求被入图检查或策略阻止，未更新正式血缘，不会自动重试。悬停或点击状态可查看具体原因。',
    icon: Ban,
    className: 'border-status-warning/30 bg-status-warning/10 text-status-warning',
  },
  failed: {
    label: INGESTION_STATUS_LABELS.failed,
    description: '写入正式血缘时发生错误，未能确认提交成功。',
    icon: XCircle,
    className: 'border-status-error/25 bg-status-error/10 text-status-error',
  },
  not_requested: {
    label: INGESTION_STATUS_LABELS.not_requested,
    description: '本次请求的策略没有要求更新正式血缘。解析或个人使用记录可能已完成。',
    icon: MinusCircle,
    className: 'text-foreground/75',
  },
  unknown: {
    label: INGESTION_STATUS_LABELS.unknown,
    description: '该审计未保存入图结果，无法确认是否入过图，常见于历史记录。',
    icon: CircleHelp,
    className: 'text-foreground/75',
  },
} satisfies Record<keyof typeof INGESTION_STATUS_LABELS, IngestionStatus>;

type IngestionStatusKey = keyof typeof INGESTION_STATUSES;

function statusKey(value?: string | null): IngestionStatusKey {
  if (value === 'blocked_policy') return 'blocked';
  return value && Object.prototype.hasOwnProperty.call(INGESTION_STATUSES, value)
    ? (value as IngestionStatusKey)
    : 'unknown';
}

export function GraphIngestionStatus({
  status,
  reason,
}: {
  status?: string | null;
  reason?: string | null;
}) {
  const key = statusKey(status);
  const item = INGESTION_STATUSES[key];
  const Icon = item.icon;
  const content = (
    <>
      <Icon className="size-3.5" aria-hidden="true" />
      {item.label}
    </>
  );
  const canExplain =
    reason !== undefined &&
    key !== 'not_requested' &&
    key !== 'unknown' &&
    (Boolean(reason?.trim()) || key === 'blocked' || key === 'failed');
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
      label={`查看${item.label}原因`}
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
          <p className="text-sm font-medium">{item.label}原因</p>
          <p className="text-xs leading-relaxed text-foreground/75">{item.description}</p>
          {issues.length ? (
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
