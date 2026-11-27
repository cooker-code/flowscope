import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { GraphIngestionStatus, GraphIngestionStatusHelp } from './GraphIngestionStatus';
import type { GraphChanges } from '@/lib/lineage-api';

afterEach(cleanup);

describe('formal graph status', () => {
  it.each([undefined, null, 'unknown', 'future_status'])(
    'leaves missing evidence blank: %s',
    (status) => {
      const { container } = render(<GraphIngestionStatus status={status} reason={null} />);
      expect(container).toBeEmptyDOMElement();
    }
  );

  it('lists exactly four statuses in the requested order', () => {
    render(<GraphIngestionStatusHelp />);
    fireEvent.click(screen.getByRole('button', { name: '入图状态说明' }));
    const panel = screen.getByTestId('ingestion-status-popover');
    expect([...panel.querySelectorAll('dt')].map((node) => node.textContent)).toEqual([
      '待入图',
      '已入图',
      '未入图',
      '未请求入图',
    ]);
    expect(within(panel).queryByText('入图失败')).not.toBeInTheDocument();
    expect(within(panel).queryByText('入图状态未知')).not.toBeInTheDocument();
  });

  it.each([
    ['blocked_policy', null, '未请求入图'],
    ['blocked', 'incomplete_analysis:pending_metadata:dw.a', '未请求入图'],
    ['blocked', 'parse_failed', '未请求入图'],
    ['blocked', 'stale_source_version', '未入图'],
  ])('reads legacy status %s with its reason', (status, reason, label) => {
    render(<GraphIngestionStatus status={status} reason={reason} />);
    expect(screen.getByRole('button', { name: `查看${label}原因` })).toHaveTextContent(label);
  });

  it('shows the parse rejection without opening the audit row', () => {
    const openRow = vi.fn();
    render(
      <div onClick={openRow}>
        <GraphIngestionStatus status="not_requested" reason="parse_failed" />
      </div>
    );
    fireEvent.click(screen.getByRole('button', { name: '查看未请求入图原因' }));
    expect(screen.getByText('SQL 解析失败，未请求更新正式血缘')).toBeInTheDocument();
    fireEvent.click(screen.getByText('原始原因'));
    expect(screen.getByText('parse_failed')).toBeInTheDocument();
    expect(openRow).not.toHaveBeenCalled();
  });

  it('distinguishes an old committed result from a measured zero', () => {
    const view = render(<GraphIngestionStatus status="committed" reason={null} />);
    fireEvent.click(screen.getByRole('button', { name: '查看入图变更统计' }));
    expect(screen.getByText('该次入图未记录变更统计。')).toBeInTheDocument();
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
    view.unmount();
    const zero = { created: 0, updated: 0, deleted: 0 };
    render(
      <GraphIngestionStatus
        status="committed"
        reason="already_current"
        changes={{
          nodes: {},
          relationships: {},
          nodeTotals: zero,
          relationshipTotals: zero,
        }}
      />
    );
    fireEvent.click(screen.getByRole('button', { name: '查看入图变更统计' }));
    expect(screen.getByText('本次无变更，正式血缘已是当前版本。')).toBeInTheDocument();
    expect(screen.getAllByRole('table')).toHaveLength(2);
  });

  it('renders actual node labels and relationship types with distinct change counts', () => {
    const changes: GraphChanges = {
      nodes: { M_TABLE: { created: 2, updated: 1, deleted: 0 } },
      relationships: { READS_FROM: { created: 1, updated: 0, deleted: 3 } },
      nodeTotals: { created: 2, updated: 1, deleted: 0 },
      relationshipTotals: { created: 1, updated: 0, deleted: 3 },
    };
    render(<GraphIngestionStatus status="committed" reason={null} changes={changes} />);
    fireEvent.click(screen.getByRole('button', { name: '查看入图变更统计' }));
    expect(
      within(screen.getByRole('row', { name: 'M_TABLE 2 1 0' }))
        .getAllByRole('cell')
        .map((cell) => cell.textContent)
    ).toEqual(['2', '1', '0']);
    expect(screen.getByRole('row', { name: 'READS_FROM 1 0 3' })).toBeInTheDocument();
  });
});
