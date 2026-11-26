/** The caller supplies its own credential. Never embed service credentials in a bundle. */
export const API_TOKEN_KEY = 'flowscope.lineage.sessionToken';
export function getApiToken(): string {
  try {
    return window.sessionStorage.getItem(API_TOKEN_KEY) ?? '';
  } catch {
    return '';
  }
}
export function setApiToken(token: string): void {
  if (token) window.sessionStorage.setItem(API_TOKEN_KEY, token);
  else window.sessionStorage.removeItem(API_TOKEN_KEY);
}
export function apiFetch(input: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  // Do not send a FlowScope token to AI services, CDN URLs, or another origin.
  const url = new URL(input, window.location.href);
  if (url.origin === window.location.origin && url.pathname.startsWith('/api/')) {
    const token = getApiToken();
    if (token && !headers.has('Authorization')) headers.set('Authorization', `Bearer ${token}`);
  }
  return fetch(input, { ...init, headers });
}
export async function apiJson<T>(
  path: string,
  body?: unknown,
  method?: 'POST' | 'DELETE'
): Promise<T> {
  const response = await apiFetch(
    path,
    body === undefined
      ? { method: method ?? 'GET' }
      : {
          method: method ?? 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        }
  );
  if (!response.ok) {
    const detail = await response.text();
    const hint =
      detail === 'principal_id_previously_used'
        ? '该调用方 ID 关联已有历史记录，删除后不能复用，请使用新的 ID。'
        : response.status === 401
          ? '请先配置有效的访问凭据。'
          : response.status === 403
            ? '当前 token 没有此操作权限。'
            : response.status === 409
              ? '策略已被其他请求修改，请重新加载后再编辑。'
              : '';
    throw new Error(`${hint} ${detail} (${response.status})`.trim());
  }
  if (!(response.headers.get('content-type') ?? '').includes('application/json')) {
    throw new Error('API 未返回 JSON，请检查 FlowScope 后端与 /api 代理配置。');
  }
  return response.json() as Promise<T>;
}
export type StorageAction = 'parse_only' | 'observe' | 'record_usage' | 'publish';
export interface CallerPolicy {
  id: string;
  name: string;
  kind: 'scheduler' | 'person' | 'admin';
  enabled: boolean;
  action: StorageAction;
  revision: number;
}
export interface CallerIdentity {
  principalId: string;
  name: string;
  kind: CallerPolicy['kind'];
  action: StorageAction;
  activeRevision: number;
  environment: string;
}
export interface CallerToken {
  id: string;
  principalId: string;
  enabled: boolean;
  createdAt: string;
}
export const ACTION_LABELS: Record<StorageAction, string> = {
  publish: '更新正式血缘',
  record_usage: '记录个人查询使用',
  observe: '仅留存观察记录',
  parse_only: '仅解析',
};
export function graphStatus(value?: string): string {
  const labels: Record<string, string> = {
    committed: '已提交',
    queued: '待写入',
    blocked: '已阻止',
    blocked_policy: '策略已阻止',
    failed: '写入失败',
    not_requested: '未请求',
  };
  return value ? (labels[value] ?? value) : '未请求';
}
