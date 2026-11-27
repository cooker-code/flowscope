import { act, cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { IngestionMonitor, type IngestionSnapshot } from './IngestionMonitor';
const fetchMock = vi.fn<typeof fetch>();
function response(patch: Partial<IngestionSnapshot> = {}) {
  return Response.json({
    scope: 'all',
    action: 'publish',
    sampledAt: '2026-11-27T02:00:00Z',
    lastAcceptedAt: '2026-11-26T08:21:36Z',
    queued: 0,
    retrying: 0,
    blocked: 2003,
    failed: 0,
    committed: 1367,
    rate: {
      monitoringSince: '2026-11-27T01:00:00Z',
      windowSeconds: 60,
      observedSeconds: 60,
      warmingUp: false,
      confirmedEvents: 6,
      eventsPerMinute: 6,
    },
    ...patch,
  });
}
async function mount(callback?: () => void) {
  const view = render(<IngestionMonitor onActivityChange={callback} />);
  await act(async () => {});
  return view;
}
async function tick() {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(5000);
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
describe('IngestionMonitor', () => {
  it('keeps polling with no queue and refreshes the list only when activity changes', async () => {
    const changed = vi.fn();
    fetchMock
      .mockResolvedValueOnce(response())
      .mockResolvedValueOnce(response({ queued: 2 }))
      .mockResolvedValue(response({ queued: 2 }));
    await mount(changed);
    expect(screen.getByText('6 条/分钟')).toBeInTheDocument();
    expect(changed).not.toHaveBeenCalled();
    await tick();
    expect(changed).toHaveBeenCalledTimes(1);
    await tick();
    expect(changed).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
  it('does not invent a zero rate while warming up', async () => {
    const b = await response().json();
    b.rate = { ...b.rate, warmingUp: true, eventsPerMinute: null, observedSeconds: 12 };
    fetchMock.mockResolvedValueOnce(Response.json(b));
    await mount();
    expect(screen.getByText('统计预热中')).toBeInTheDocument();
    expect(screen.queryByText('0 条/分钟')).not.toBeInTheDocument();
  });
  it('preserves stale results on transient errors then recovers', async () => {
    fetchMock
      .mockResolvedValueOnce(response())
      .mockRejectedValueOnce(new Error('Network unavailable'))
      .mockResolvedValueOnce(response());
    await mount();
    await tick();
    expect(screen.getByText('6 条/分钟')).toBeInTheDocument();
    expect(screen.getByRole('status')).toHaveTextContent('当前保留');
    await tick();
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
  });
  it.each([401, 403, 404, 503])('clears old data and stops on %s', async (status) => {
    fetchMock
      .mockResolvedValueOnce(response())
      .mockResolvedValueOnce(new Response(null, { status }));
    await mount();
    await tick();
    expect(screen.queryByText('6 条/分钟')).not.toBeInTheDocument();
    await tick();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
  it('does not overlap requests and aborts owned timers and requests', async () => {
    let resolve!: (r: Response) => void;
    fetchMock.mockReturnValue(
      new Promise<Response>((r) => {
        resolve = r;
      })
    );
    const view = await mount();
    await tick();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const signal = fetchMock.mock.calls[0][1]?.signal;
    view.unmount();
    expect(signal?.aborted).toBe(true);
    await act(async () => resolve(response()));
    expect(vi.getTimerCount()).toBe(0);
  });
});
