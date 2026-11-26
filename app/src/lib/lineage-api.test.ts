import { afterEach, describe, expect, it, vi } from 'vitest';
import { apiFetch, apiJson } from './lineage-api';

afterEach(() => {
  vi.unstubAllGlobals();
});
function browser() {
  vi.stubGlobal('window', {
    location: { href: 'http://localhost:3000/audit', origin: 'http://localhost:3000' },
    sessionStorage: { getItem: () => 'test-caller-token' },
  });
  const fetchMock = vi
    .fn()
    .mockResolvedValue(new Response('{}', { headers: { 'Content-Type': 'application/json' } }));
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}
describe('caller credential boundaries', () => {
  it('authenticates same-origin API calls without leaking into remote API or AI calls', async () => {
    const fetchMock = browser();
    await apiFetch('/api/analyze');
    expect(fetchMock.mock.calls[0][1].headers.get('Authorization')).toBe(
      'Bearer test-caller-token'
    );
    await apiFetch('https://ai.example/v1/chat/completions');
    expect(fetchMock.mock.calls[1][1].headers.has('Authorization')).toBe(false);
    await apiFetch('https://other.example/api/analyze');
    expect(fetchMock.mock.calls[2][1].headers.has('Authorization')).toBe(false);
    await apiFetch('/api/lineage/me', { headers: { Authorization: 'Bearer replacement-token' } });
    expect(fetchMock.mock.calls[3][1].headers.get('Authorization')).toBe(
      'Bearer replacement-token'
    );
  });
  it('reports concurrent save conflicts and catches missing API proxy HTML', async () => {
    const fetchMock = browser();
    fetchMock.mockResolvedValueOnce(new Response('policy_revision_conflict', { status: 409 }));
    await expect(apiJson('/api/lineage/policies', {})).rejects.toThrow('409');
    fetchMock.mockResolvedValueOnce(
      new Response('<html></html>', { headers: { 'Content-Type': 'text/html' } })
    );
    await expect(apiJson('/api/lineage/policies')).rejects.toThrow('API 未返回 JSON');
  });
  it('deletes callers with their revision and explains retired identities', async () => {
    const fetchMock = browser();
    await apiJson('/api/lineage/policies/person_1', { revision: 3 }, 'DELETE');
    const init = fetchMock.mock.calls[0][1];
    expect(init.method).toBe('DELETE');
    expect(init.body).toBe('{"revision":3}');
    expect(init.headers.get('Authorization')).toBe('Bearer test-caller-token');
    fetchMock.mockResolvedValueOnce(new Response('principal_id_previously_used', { status: 409 }));
    await expect(apiJson('/api/lineage/policies', {})).rejects.toThrow('删除后不能复用');
  });
});
