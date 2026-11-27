import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AuditPage } from './AuditPage';

vi.mock('@/lib/project-store', () => ({
  useProject: () => ({ isBackendMode: true, backendAuditStorage: { enabled: true } }),
}));

vi.mock('@/components/IngestionMonitor', () => ({
  IngestionMonitor: ({ onActivityChange }: { onActivityChange: () => void }) => (
    <button onClick={onActivityChange}>模拟入图变化</button>
  ),
}));

const fetchMock = vi.fn<typeof fetch>();

function auditResponse(lineageStatus = 'committed', usageStatus = 'not_requested', id = 1) {
  return Response.json({
    total: 100,
    records: [
      {
        id,
        ts: '2026-11-26T01:00:00Z',
        endpoint: '/api/analyze',
        dialect: 'hive',
        file_name: `query-${id}.sql`,
        source_name: null,
        target_table: null,
        sql_type: 'SELECT',
        success: true,
        alias_warning: false,
        duration_ms: 10,
        table_count: 1,
        lineage_status: lineageStatus,
        usage_status: usageStatus,
      },
    ],
  });
}

function pendingResponse() {
  let resolve!: (response: Response) => void;
  const promise = new Promise<Response>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

async function renderAudit() {
  const view = render(
    <MemoryRouter future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
      <AuditPage />
    </MemoryRouter>
  );
  await act(async () => {});
  return view;
}

async function poll() {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(2000);
  });
}

beforeEach(() => {
  vi.useFakeTimers();
  fetchMock.mockReset();
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('AuditPage polling', () => {
  it('finishes loading if ingestion changes during the initial list request', async () => {
    const initial = pendingResponse();
    fetchMock.mockReturnValueOnce(initial.promise).mockResolvedValueOnce(auditResponse());
    const { container } = await renderAudit();
    expect(container.querySelector('.animate-spin')).not.toBeNull();
    fireEvent.click(screen.getByText('模拟入图变化'));
    await act(async () => {});
    expect(fetchMock.mock.calls[0][1]?.signal?.aborted).toBe(true);
    expect(container.querySelector('.animate-spin')).toBeNull();
    expect(screen.getByText('query-1.sql')).toBeInTheDocument();
    await act(async () => initial.resolve(Response.json({ total: 0, records: [] })));
    expect(screen.getByText('query-1.sql')).toBeInTheDocument();
  });

  it('quietly refreshes an empty filtered page when ingestion activity changes', async () => {
    const response = pendingResponse();
    fetchMock
      .mockResolvedValueOnce(Response.json({ total: 0, records: [] }))
      .mockReturnValueOnce(response.promise);
    const { container } = render(
      <MemoryRouter
        initialEntries={['/audit?lineage_status=queued&page=2']}
        future={{ v7_startTransition: true, v7_relativeSplatPath: true }}
      >
        <AuditPage />
      </MemoryRouter>
    );
    await act(async () => {});
    const initialUrl = fetchMock.mock.calls[0][0];
    expect(initialUrl).toContain('offset=50');
    fireEvent.click(screen.getByText('模拟入图变化'));
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[1][0]).toEqual(initialUrl);
    expect(container.querySelector('.animate-spin')).toBeNull();
    await act(async () => response.resolve(auditResponse('queued')));
    expect(screen.getByText('query-1.sql')).toBeInTheDocument();
  });

  it.each([
    ['queued', 'not_requested'],
    ['committed', 'queued'],
  ])(
    'refreshes %s / %s without covering the table or disabling pagination',
    async (lineage, usage) => {
      const refresh = pendingResponse();
      fetchMock
        .mockResolvedValueOnce(auditResponse(lineage, usage))
        .mockReturnValueOnce(refresh.promise);
      const { container } = await renderAudit();
      const row = screen.getByText('query-1.sql').closest('tr');
      const nextPage = screen.getByText('Page 1 / 2').nextElementSibling;

      await poll();

      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(container.querySelector('.animate-spin')).toBeNull();
      expect(screen.getByText('query-1.sql').closest('tr')).toBe(row);
      expect(nextPage).toBeEnabled();
      await poll();
      expect(fetchMock).toHaveBeenCalledTimes(2);

      await act(async () => refresh.resolve(auditResponse()));
      expect(screen.getByText('已入图')).toBeInTheDocument();
      expect(screen.getByText('query-1.sql').closest('tr')).toBe(row);
      await poll();
      expect(fetchMock).toHaveBeenCalledTimes(2);
    }
  );

  it('keeps the table on a background failure and retries queued records', async () => {
    fetchMock
      .mockResolvedValueOnce(auditResponse('queued'))
      .mockRejectedValueOnce(new Error('Network unavailable'))
      .mockResolvedValueOnce(auditResponse());
    const { container } = await renderAudit();

    await poll();
    expect(screen.getByText('query-1.sql')).toBeInTheDocument();
    expect(screen.getByText('Network unavailable')).toBeInTheDocument();
    expect(container.querySelector('.animate-spin')).toBeNull();

    await poll();
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(screen.getByText('已入图')).toBeInTheDocument();
    expect(screen.queryByText('Network unavailable')).not.toBeInTheDocument();
  });

  it('cancels a background refresh when changing page and ignores its late response', async () => {
    const refresh = pendingResponse();
    const nextPageResponse = pendingResponse();
    fetchMock
      .mockResolvedValueOnce(auditResponse('queued'))
      .mockReturnValueOnce(refresh.promise)
      .mockReturnValueOnce(nextPageResponse.promise);
    const { container } = await renderAudit();
    await poll();
    const refreshSignal = fetchMock.mock.calls[1][1]?.signal;

    fireEvent.click(screen.getByText('Page 1 / 2').nextElementSibling!);
    expect(refreshSignal?.aborted).toBe(true);
    expect(fetchMock.mock.calls[2][0]).toContain('offset=50');
    expect(container.querySelector('.animate-spin')).not.toBeNull();

    await act(async () =>
      nextPageResponse.resolve(auditResponse('committed', 'not_requested', 51))
    );
    await act(async () => refresh.resolve(auditResponse('queued')));
    expect(screen.getByText('query-51.sql')).toBeInTheDocument();
    expect(screen.queryByText('query-1.sql')).not.toBeInTheDocument();
    expect(container.querySelector('.animate-spin')).toBeNull();
    await poll();
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it('shows a loading state for the initial request and an error for a failed query', async () => {
    const initial = pendingResponse();
    fetchMock.mockReturnValueOnce(initial.promise);
    const { container } = await renderAudit();
    expect(container.querySelector('.animate-spin')).not.toBeNull();

    await act(async () => initial.resolve(new Response(null, { status: 401 })));
    expect(screen.getByText('请先配置有效的访问凭据。')).toBeInTheDocument();
    expect(container.querySelector('.animate-spin')).toBeNull();
    await poll();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('aborts pending refreshes and removes polling timers when unmounted', async () => {
    const refresh = pendingResponse();
    fetchMock.mockResolvedValueOnce(auditResponse('queued')).mockReturnValueOnce(refresh.promise);
    const { unmount } = await renderAudit();
    await poll();
    const signal = fetchMock.mock.calls[1][1]?.signal;

    unmount();
    expect(signal?.aborted).toBe(true);
    await act(async () => refresh.resolve(auditResponse('queued')));
    await poll();
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe('AuditPage SQL types', () => {
  it.each([
    ['INSERT INTO', 'ii'],
    ['INSERT OVERWRITE', 'io'],
    ['SELECT', 'select'],
    ['WITH', '—'],
    ['INSERT', '—'],
  ])('displays %s as %s', async (sqlType, label) => {
    const response = await auditResponse().json();
    response.records[0].sql_type = sqlType;
    fetchMock.mockResolvedValueOnce(Response.json(response));
    await renderAudit();

    const row = screen.getByText('query-1.sql').closest('tr')!;
    expect(within(row).getAllByRole('cell')[5].textContent).toBe(label);
  });
});
