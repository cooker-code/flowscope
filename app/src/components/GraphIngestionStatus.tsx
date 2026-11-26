import { useRef, useState } from 'react';
import {
  Ban,
  CheckCircle2,
  CircleHelp,
  Clock3,
  MinusCircle,
  XCircle,
  type LucideIcon,
} from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';
import { cn } from '@/lib/utils';

interface IngestionStatus {
  label: string;
  description: string;
  icon: LucideIcon;
  className: string;
}

const INGESTION_STATUSES = {
  committed: {
    label: '已入图',
    description: '本次请求的正式血缘已成功写入 Neo4j。',
    icon: CheckCircle2,
    className: 'border-status-success/25 bg-status-success/10 text-status-success',
  },
  queued: {
    label: '待入图',
    description: '请求已受理，正在排队或等待重试，尚未确认写入成功。',
    icon: Clock3,
    className: 'border-status-info/25 bg-status-info/10 text-status-info',
  },
  blocked: {
    label: '未入图',
    description: '解析、元数据、权限或策略检查未通过。具体原因见该行“调用方 / 原因”。',
    icon: Ban,
    className: 'border-status-warning/30 bg-status-warning/10 text-status-warning',
  },
  failed: {
    label: '入图失败',
    description: '写入正式血缘时发生错误，未能确认提交成功。',
    icon: XCircle,
    className: 'border-status-error/25 bg-status-error/10 text-status-error',
  },
  not_requested: {
    label: '未请求入图',
    description: '本次请求的策略没有要求更新正式血缘。解析或个人使用记录可能已完成。',
    icon: MinusCircle,
    className: 'text-foreground/75',
  },
  unknown: {
    label: '入图状态未知',
    description: '该审计未保存入图结果，无法确认是否入过图，常见于历史记录。',
    icon: CircleHelp,
    className: 'text-foreground/75',
  },
} satisfies Record<string, IngestionStatus>;

type IngestionStatusKey = keyof typeof INGESTION_STATUSES;

function statusKey(value?: string | null): IngestionStatusKey {
  if (value === 'blocked_policy') return 'blocked';
  return value && Object.prototype.hasOwnProperty.call(INGESTION_STATUSES, value)
    ? (value as IngestionStatusKey)
    : 'unknown';
}

export function GraphIngestionStatus({ status }: { status?: string | null }) {
  const key = statusKey(status);
  const item = INGESTION_STATUSES[key];
  const Icon = item.icon;

  return (
    <Badge
      variant="outline"
      className={cn('gap-1.5 whitespace-nowrap', item.className)}
      title={item.description}
      data-ingestion-status={key}
    >
      <Icon className="size-3.5" aria-hidden="true" />
      {item.label}
    </Badge>
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
              <Button
                ref={trigger}
                type="button"
                variant="ghost"
                size="icon"
                className="size-7 shrink-0"
                aria-label="入图状态说明"
              >
                <CircleHelp aria-hidden="true" />
              </Button>
            </PopoverTrigger>
          </TooltipTrigger>
          {!popoverOpen && (
            <TooltipContent
              data-testid="ingestion-status-tooltip"
              side="bottom"
              align="start"
              className="max-h-[var(--radix-tooltip-content-available-height)] w-80 max-w-[calc(100vw-2rem)] overflow-y-auto p-4 font-normal motion-reduce:animate-none"
            >
              <StatusLegend />
            </TooltipContent>
          )}
        </Tooltip>
        <PopoverContent
          data-testid="ingestion-status-popover"
          side="bottom"
          align="start"
          className="max-h-[var(--radix-popover-content-available-height)] w-80 max-w-[calc(100vw-2rem)] overflow-y-auto motion-reduce:animate-none"
          aria-label="入图状态说明"
          onCloseAutoFocus={(event) => {
            event.preventDefault();
            trigger.current?.focus();
            setTooltipOpen(false);
          }}
        >
          <StatusLegend />
        </PopoverContent>
      </Popover>
    </TooltipProvider>
  );
}
