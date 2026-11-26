import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { AuditRetentionSettings } from './AuditRetentionSettings';

const fetchMock = vi.fn<typeof fetch>();

beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal('fetch', fetchMock);
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it('loads seven days, persists changes and reloads the server value', async () => {
  fetchMock.mockResolvedValueOnce(Response.json({ retentionDays: 7 }));
  const view = render(<AuditRetentionSettings />);
  await act(async () => {});
  expect(screen.getByLabelText('保留天数')).toHaveValue(7);
  fireEvent.change(screen.getByLabelText('保留天数'), { target: { value: '14' } });
  let resolve!: (value: Response) => void;
  fetchMock.mockReturnValueOnce(
    new Promise<Response>((done) => {
      resolve = done;
    })
  );
  fireEvent.click(screen.getByRole('button', { name: '保存保留天数' }));
  expect(screen.getByRole('button', { name: '保存中…' })).toBeDisabled();
  expect(screen.queryByText(/已保存/)).toBeNull();
  expect(fetchMock.mock.calls[1][0]).toBe('/api/audit/settings');
  expect(JSON.parse(String(fetchMock.mock.calls[1][1]?.body))).toEqual({ retentionDays: 14 });
  await act(async () => resolve(Response.json({ retentionDays: 14 })));
  expect(screen.getByRole('status')).toHaveTextContent('已保存');
  view.unmount();
  fetchMock.mockResolvedValueOnce(Response.json({ retentionDays: 14 }));
  render(<AuditRetentionSettings />);
  await act(async () => {});
  expect(screen.getByLabelText('保留天数')).toHaveValue(14);
});

it('keeps the draft after a failed save and allows retry', async () => {
  fetchMock
    .mockResolvedValueOnce(Response.json({ retentionDays: 7 }))
    .mockResolvedValueOnce(new Response('database busy', { status: 500 }))
    .mockResolvedValueOnce(Response.json({ retentionDays: 3 }));
  render(<AuditRetentionSettings />);
  await act(async () => {});
  fireEvent.change(screen.getByLabelText('保留天数'), { target: { value: '3' } });
  fireEvent.click(screen.getByRole('button', { name: '保存保留天数' }));
  await act(async () => {});
  expect(screen.getByRole('alert')).toHaveTextContent('database busy');
  expect(screen.queryByText(/已保存/)).toBeNull();
  expect(screen.getByLabelText('保留天数')).toHaveValue(3);
  fireEvent.click(screen.getByRole('button', { name: '保存保留天数' }));
  await act(async () => {});
  expect(screen.getByRole('status')).toHaveTextContent('已保存');
});

it('does not show a fake default when loading fails and can reload', async () => {
  fetchMock
    .mockRejectedValueOnce(new Error('Network unavailable'))
    .mockResolvedValueOnce(Response.json({ retentionDays: 7 }));
  render(<AuditRetentionSettings />);
  await act(async () => {});
  expect(screen.getByRole('alert')).toHaveTextContent('Network unavailable');
  expect(screen.getByLabelText('保留天数')).toBeDisabled();
  fireEvent.click(screen.getByRole('button', { name: '重新加载' }));
  await act(async () => {});
  expect(screen.getByLabelText('保留天数')).toHaveValue(7);
  expect(screen.queryByRole('alert')).toBeNull();
});

it.each(['0', '-1', '1.5'])(
  'rejects invalid retention %s without sending a write',
  async (value) => {
    fetchMock.mockResolvedValueOnce(Response.json({ retentionDays: 7 }));
    render(<AuditRetentionSettings />);
    await act(async () => {});
    const input = screen.getByLabelText('保留天数');
    fireEvent.change(input, { target: { value } });
    fireEvent.submit(input.closest('form')!);
    expect(screen.getByRole('alert')).toHaveTextContent('正整数');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  }
);
