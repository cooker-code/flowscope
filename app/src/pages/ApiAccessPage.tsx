import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { apiFetch, API_TOKEN_KEY, setApiToken, type CallerIdentity } from '@/lib/lineage-api';

export function ApiAccessPage() {
  const [token, setToken] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  return (
    <main className="min-h-svh bg-background text-foreground p-6">
      <div className="mx-auto max-w-xl space-y-6">
        <Button className="text-foreground!" variant="ghost" asChild>
          <Link to="/audit">返回审计记录</Link>
        </Button>
        <div>
          <h1 className="text-xl font-semibold">访问凭据</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            使用管理员发放给你的 token。凭据只保存在当前标签页会话中，不会写入 URL。
          </p>
        </div>
        <form
          className="space-y-4"
          onSubmit={async (event) => {
            event.preventDefault();
            setBusy(true);
            setError('');
            try {
              const response = await apiFetch('/api/lineage/me', {
                headers: { Authorization: `Bearer ${token.trim()}` },
              });
              if (!response.ok) throw new Error(`凭据不可用或策略已停用 (${response.status})`);
              if (!(response.headers.get('content-type') ?? '').includes('application/json'))
                throw new Error('API 未返回 JSON，请检查后端连接。');
              const caller = (await response.json()) as CallerIdentity;
              setApiToken(token.trim());
              setToken('');
              window.location.assign(caller.kind === 'admin' ? '/policies' : '/audit');
            } catch (e) {
              setError(e instanceof Error ? e.message : String(e));
            } finally {
              setBusy(false);
            }
          }}
        >
          <label htmlFor="api-token" className="block text-sm font-medium">
            Bearer token
          </label>
          <Input
            className="bg-background! text-foreground!"
            id="api-token"
            type="password"
            autoComplete="off"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            required
          />
          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
          <div className="flex flex-wrap gap-3">
            <Button type="submit" disabled={busy || !token.trim()}>
              {busy ? '验证中…' : '验证并使用'}
            </Button>
            <Button
              className="bg-background! text-foreground!"
              type="button"
              variant="outline"
              onClick={() => {
                window.sessionStorage.removeItem(API_TOKEN_KEY);
                window.location.assign('/access');
              }}
            >
              清除当前凭据
            </Button>
          </div>
        </form>
      </div>
    </main>
  );
}
