import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { AuditRetentionSettings } from '@/components/AuditRetentionSettings';
import {
  ACTION_LABELS,
  apiJson,
  setApiToken,
  type CallerIdentity,
  type CallerPolicy,
  type CallerToken,
  type StorageAction,
} from '@/lib/lineage-api';
import { formatLocalTs } from '@/lib/utils';

const fieldClass =
  'w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus-visible:outline-2 focus-visible:outline-ring';
interface PolicyList {
  principals: CallerPolicy[];
  tokens: CallerToken[];
}
interface Preview {
  allowed: boolean;
  action: StorageAction;
  reason: string;
  qualityIssues: string[];
  writesGraph: false;
}
const KIND_LABELS = { scheduler: '调度系统', person: '个人', admin: '管理员' };

export function PolicyPage() {
  const [params, setParams] = useSearchParams();
  const [data, setData] = useState<PolicyList | null>(null);
  const [identity, setIdentity] = useState<CallerIdentity | null>(null);
  const [draft, setDraft] = useState<CallerPolicy | null>(null);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [deleting, setDeleting] = useState<CallerPolicy | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const selected = params.get('principal') ?? '';
  const creating = params.get('create') === '1';
  const auditId = params.get('auditId') ?? '';
  const refresh = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const me = await apiJson<CallerIdentity>('/api/lineage/me');
      setIdentity(me);
      const list = await apiJson<PolicyList>('/api/lineage/policies');
      setData(list);
      setDeleting(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  useEffect(() => {
    setDraft(
      creating
        ? {
            id: '',
            name: '',
            kind: 'person',
            enabled: true,
            action: 'record_usage',
            revision: 0,
          }
        : (data?.principals.find((p) => p.id === selected) ?? null)
    );
  }, [data, selected, creating]);
  useEffect(() => {
    setPreview(null);
  }, [selected, creating]);
  function choose(id: string) {
    setNotice('');
    setParams((old) => {
      const next = new URLSearchParams(old);
      next.delete('create');
      next.set('principal', id);
      return next;
    });
  }
  async function perform(action: () => Promise<void>) {
    setBusy(true);
    setError('');
    try {
      await action();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }
  function update<K extends keyof CallerPolicy>(key: K, value: CallerPolicy[K]) {
    setDraft((current) => (current ? { ...current, [key]: value } : null));
    setPreview(null);
    setNotice('');
  }
  const create = () => {
    setNotice('');
    setParams(new URLSearchParams({ create: '1' }));
    setDraft({
      id: '',
      name: '',
      kind: 'person',
      enabled: true,
      action: 'record_usage',
      revision: 0,
    });
  };
  const save = (event: FormEvent) => {
    event.preventDefault();
    if (!draft) return;
    void perform(async () => {
      const saved = await apiJson<{ policy: CallerPolicy; activeRevision: number }>(
        '/api/lineage/policies',
        draft
      );
      if (
        saved.policy.id === identity?.principalId &&
        (!saved.policy.enabled || saved.policy.kind !== 'admin')
      ) {
        setApiToken('');
        window.location.assign('/access');
        return;
      }
      await refresh();
      choose(saved.policy.id);
      setDraft(saved.policy);
      setNotice(`已保存并生效，版本 ${saved.activeRevision}。仅影响后续请求和尚未开始写入的事件。`);
    });
  };
  const editable = draft?.id !== 'bootstrap';
  const options: StorageAction[] =
    draft?.kind === 'scheduler'
      ? ['publish', 'observe', 'parse_only']
      : draft?.kind === 'person'
        ? ['record_usage', 'observe', 'parse_only']
        : ['observe', 'parse_only'];
  return (
    <div className="flex h-svh flex-col bg-background text-foreground">
      <header className="flex min-h-12 shrink-0 flex-wrap items-center gap-3 border-b px-4 py-2">
        <Button className="text-foreground!" variant="ghost" size="sm" asChild>
          <Link to="/audit">返回审计</Link>
        </Button>
        <h1 className="text-sm font-semibold">写入策略</h1>
        <span className="text-xs text-muted-foreground">
          {identity ? `${identity.name} · ${identity.environment}` : '需要管理员 token'}
        </span>
        <Button
          className="ml-auto bg-background! text-foreground!"
          variant="outline"
          size="sm"
          asChild
        >
          <Link to="/access">访问凭据</Link>
        </Button>
      </header>
      <main className="min-h-0 flex-1 overflow-auto p-4 md:p-6">
        <p className="mb-5 max-w-3xl text-sm text-muted-foreground">
          token
          对应调用方的启用状态和默认动作。调度系统可更新正式血缘；个人只记录查询使用。保存策略不会自动发布历史
          SQL。
        </p>
        {error && (
          <div
            role="alert"
            className="mb-4 rounded-md border border-destructive/30 p-3 text-sm text-destructive"
          >
            {error}{' '}
            <Button variant="link" onClick={() => void refresh()}>
              重新加载
            </Button>
          </div>
        )}
        {loading && !data && (
          <div role="status" className="h-24 animate-pulse rounded-md bg-muted p-4 text-sm">
            正在加载调用方与策略…
          </div>
        )}
        {notice && (
          <p role="status" className="mb-4 text-sm text-emerald-700 dark:text-emerald-400">
            {notice}
          </p>
        )}
        {data && (
          <div className="grid items-start gap-6 xl:grid-cols-[minmax(480px,1fr)_minmax(360px,1.5fr)]">
            <section aria-label="调用方列表" className="min-w-0">
              <div className="mb-3 flex items-center justify-between">
                <h2 className="font-semibold">调用方</h2>
                <Button
                  className="bg-background! text-foreground!"
                  size="sm"
                  variant="outline"
                  onClick={create}
                >
                  新增调用方
                </Button>
              </div>
              <div className="overflow-x-auto rounded-md border">
                <table className="w-full min-w-[480px] text-left text-sm">
                  <thead className="border-b bg-muted/30 text-xs text-muted-foreground">
                    <tr>
                      <th className="p-3">名称</th>
                      <th className="p-3 whitespace-nowrap">默认动作</th>
                      <th className="p-3 whitespace-nowrap">是否启用</th>
                      <th className="p-3 whitespace-nowrap">版本</th>
                      <th className="p-3 whitespace-nowrap">操作</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.principals.map((p) => (
                      <tr
                        key={p.id}
                        className={`border-b last:border-0 ${selected === p.id ? 'bg-muted' : 'hover:bg-muted/30'}`}
                      >
                        <td className="p-3">
                          <button
                            type="button"
                            className="text-left underline-offset-4 hover:underline focus-visible:outline-2 focus-visible:outline-ring"
                            onClick={() => choose(p.id)}
                          >
                            <span className="block font-medium">{p.name}</span>
                            <span className="text-xs text-muted-foreground">
                              {p.id} · {KIND_LABELS[p.kind]}
                              {p.id === 'bootstrap' && ' · 部署管理'}
                            </span>
                          </button>
                        </td>
                        <td className="p-3 text-xs">{ACTION_LABELS[p.action]}</td>
                        <td className="p-3 whitespace-nowrap text-xs">
                          {p.enabled ? '已启用' : '已停用'}
                        </td>
                        <td className="p-3 font-mono text-xs">{p.revision}</td>
                        <td className="p-3">
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            className="text-destructive"
                            disabled={busy || p.id === 'bootstrap'}
                            title={p.id === 'bootstrap' ? '启动管理员由部署配置管理' : undefined}
                            onClick={() => setDeleting(p)}
                          >
                            删除
                          </Button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {deleting && (
                <div
                  role="region"
                  aria-label="删除调用方确认"
                  className="mt-4 space-y-3 rounded-md border border-destructive/40 p-4 text-sm"
                >
                  <p>
                    确定永久删除 <strong>{deleting.name}</strong>（{deleting.id}）？
                  </p>
                  <p className="text-muted-foreground">
                    调用方及其全部 token 将从数据库删除，旧 token
                    立即失效。历史审计和已提交血缘保留。
                  </p>
                  <div className="flex flex-wrap gap-2">
                    <Button
                      type="button"
                      variant="destructive"
                      disabled={busy}
                      onClick={() =>
                        void perform(async () => {
                          const removed = deleting;
                          await apiJson(
                            `/api/lineage/policies/${encodeURIComponent(removed.id)}`,
                            { revision: removed.revision },
                            'DELETE'
                          );
                          setDeleting(null);
                          if (removed.id === identity?.principalId) {
                            setApiToken('');
                            window.location.assign('/access');
                            return;
                          }
                          if (selected === removed.id) {
                            setParams(new URLSearchParams(), { replace: true });
                            setDraft(null);
                          }
                          await refresh();
                          setNotice(`已物理删除调用方 ${removed.name} 及其 token。`);
                        })
                      }
                    >
                      {busy ? '删除中…' : '确认物理删除'}
                    </Button>
                    <Button
                      type="button"
                      variant="outline"
                      className="bg-background! text-foreground!"
                      disabled={busy}
                      onClick={() => setDeleting(null)}
                    >
                      取消
                    </Button>
                  </div>
                </div>
              )}
              <AuditRetentionSettings />
            </section>
            <section className="min-w-0" aria-label="策略编辑">
              {!draft ? (
                <div className="rounded-md border p-6 text-sm text-muted-foreground">
                  选择调用方编辑策略，或新增调度系统、个人调用方。新 token 需要先保存调用方后发放。
                </div>
              ) : (
                <>
                  <form onSubmit={save} className="space-y-5">
                    <div className="flex flex-wrap items-baseline justify-between gap-2">
                      <h2 className="font-semibold">
                        {draft.revision ? `编辑 ${draft.name}` : '新增调用方'}
                      </h2>
                      <span className="text-xs text-muted-foreground">
                        {draft.revision ? `当前生效版本 ${draft.revision}` : '尚未保存'}
                      </span>
                    </div>
                    {!editable && (
                      <p className="text-sm text-muted-foreground">
                        初始管理员由服务部署配置管理，可创建其他管理员供日常使用。
                      </p>
                    )}
                    <fieldset
                      disabled={busy || !editable}
                      className="space-y-4 disabled:opacity-70"
                    >
                      <div className="grid gap-4 sm:grid-cols-2">
                        <label className="space-y-1 text-sm">
                          <span>调用方 ID</span>
                          <Input
                            className="bg-background! text-foreground!"
                            required
                            pattern="[A-Za-z0-9_.-]+"
                            maxLength={128}
                            disabled={draft.revision > 0}
                            value={draft.id}
                            onChange={(e) => update('id', e.target.value)}
                          />
                        </label>
                        <label className="space-y-1 text-sm">
                          <span>显示名称</span>
                          <Input
                            className="bg-background! text-foreground!"
                            required
                            value={draft.name}
                            onChange={(e) => update('name', e.target.value)}
                          />
                        </label>
                        <label className="space-y-1 text-sm">
                          <span>调用方类型</span>
                          <select
                            className={fieldClass}
                            value={draft.kind}
                            onChange={(e) => {
                              const kind = e.target.value as CallerPolicy['kind'];
                              update('kind', kind);
                              update(
                                'action',
                                kind === 'scheduler'
                                  ? 'publish'
                                  : kind === 'person'
                                    ? 'record_usage'
                                    : 'observe'
                              );
                            }}
                          >
                            {Object.entries(KIND_LABELS).map(([key, label]) => (
                              <option key={key} value={key}>
                                {label}
                              </option>
                            ))}
                          </select>
                        </label>
                        <label className="space-y-1 text-sm">
                          <span>默认动作</span>
                          <select
                            className={fieldClass}
                            value={draft.action}
                            onChange={(e) => update('action', e.target.value as StorageAction)}
                          >
                            {options.map((action) => (
                              <option key={action} value={action}>
                                {ACTION_LABELS[action]}
                              </option>
                            ))}
                          </select>
                        </label>
                      </div>
                      <label className="flex items-center gap-2 text-sm">
                        <input
                          type="checkbox"
                          checked={draft.enabled}
                          onChange={(e) => update('enabled', e.target.checked)}
                        />
                        启用此调用方
                      </label>
                      <Button type="submit" disabled={!draft.id || !draft.name}>
                        {busy ? '保存中…' : '保存并生效'}
                      </Button>
                    </fieldset>
                  </form>
                  {editable && draft.revision > 0 && (
                    <section className="mt-6 space-y-3 border-t pt-5" aria-label="Token 管理">
                      <div className="flex flex-wrap items-center justify-between gap-3">
                        <h3 className="text-sm font-semibold">Token</h3>
                        <Button
                          className="bg-background! text-foreground!"
                          variant="outline"
                          size="sm"
                          disabled={busy}
                          onClick={() =>
                            void perform(async () => {
                              await apiJson('/api/lineage/tokens', { principalId: draft.id });
                              const list = await apiJson<PolicyList>('/api/lineage/policies');
                              setData(list);
                              setNotice('Token 已发放，可在列表中查看和复制。');
                            })
                          }
                        >
                          发放 token
                        </Button>
                      </div>
                      <p className="text-xs text-muted-foreground">
                        下方为可直接用于接口请求的完整 Token，仅显示未撤销的记录。
                      </p>
                      {!data.tokens.some((t) => t.principalId === draft.id && t.enabled) && (
                        <p className="py-3 text-sm text-muted-foreground">暂无有效 Token。</p>
                      )}
                      <ul className="divide-y text-xs" aria-label="有效 Token">
                        {data.tokens
                          .filter((t) => t.principalId === draft.id && t.enabled)
                          .map((t) => (
                            <li
                              key={t.id}
                              data-testid="caller-token"
                              className="flex flex-wrap items-center gap-x-3 gap-y-2 py-3"
                            >
                              {t.token ? (
                                <code
                                  data-testid="token-value"
                                  className="min-w-0 flex-[1_1_24rem] select-all break-all font-mono text-sm"
                                >
                                  {t.token}
                                </code>
                              ) : (
                                <span className="min-w-0 flex-[1_1_24rem] text-muted-foreground">
                                  该历史 Token 下次成功调用后可显示完整值。
                                </span>
                              )}
                              <time title={t.createdAt}>{formatLocalTs(t.createdAt)}</time>
                              <span>有效</span>
                              <Button
                                className="bg-background! text-foreground!"
                                variant="outline"
                                size="sm"
                                disabled={busy}
                                onClick={() =>
                                  void perform(async () => {
                                    await apiJson(
                                      `/api/lineage/tokens/${encodeURIComponent(t.id)}/revoke`,
                                      {}
                                    );
                                    await refresh();
                                  })
                                }
                              >
                                撤销
                              </Button>
                            </li>
                          ))}
                      </ul>
                    </section>
                  )}
                  {editable && (
                    <section className="mt-6 space-y-3 border-t pt-5" aria-label="策略预览">
                      <h3 className="text-sm font-semibold">预览判定</h3>
                      <p className="text-xs text-muted-foreground">
                        按当前表单检查启用状态和默认动作，不保存、不写图。调度发布仍需提供任务
                        ID、版本并通过解析质量检查。
                      </p>
                      <label className="block space-y-1 text-sm">
                        <span>历史审计 ID（可选）</span>
                        <Input
                          className="bg-background! text-foreground!"
                          inputMode="numeric"
                          value={auditId}
                          onChange={(e) =>
                            setParams(
                              (old) => {
                                const next = new URLSearchParams(old);
                                if (e.target.value) next.set('auditId', e.target.value);
                                else next.delete('auditId');
                                return next;
                              },
                              { replace: true }
                            )
                          }
                        />
                      </label>
                      <Button
                        className="bg-background! text-foreground!"
                        variant="outline"
                        disabled={busy}
                        onClick={() =>
                          void perform(async () => {
                            const result = await apiJson<Preview>('/api/lineage/policies/preview', {
                              policy: draft,
                              ...(auditId ? { auditId: Number(auditId) } : {}),
                            });
                            setPreview(result);
                          })
                        }
                      >
                        预览，不写图
                      </Button>
                      {preview && (
                        <div role="status" className="rounded-md border bg-muted/30 p-3 text-sm">
                          <p className="font-medium">
                            {preview.allowed ? '调用方已启用' : '调用方已停用'} ·{' '}
                            {ACTION_LABELS[preview.action]}
                          </p>
                          <p className="mt-1 break-words text-xs text-muted-foreground">
                            {preview.allowed
                              ? '按上述默认动作处理请求；正式更新还需要完整解析结果和有效任务版本。'
                              : '该调用方的 token 请求将被拒绝。'}
                          </p>
                          {preview.qualityIssues.length > 0 && (
                            <p className="mt-2 break-words text-xs">
                              解析待处理：{preview.qualityIssues.join(', ')}
                            </p>
                          )}
                        </div>
                      )}
                    </section>
                  )}
                </>
              )}
            </section>
          </div>
        )}
      </main>
    </div>
  );
}
