const { chromium } = require(process.env.FLOWSCOPE_PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const base = process.env.FLOWSCOPE_TEST_BASE_URL;
const adminToken = process.env.FLOWSCOPE_TEST_ADMIN_TOKEN;
const out = process.env.FLOWSCOPE_UI_EVIDENCE;
assert(base && new URL(base).hostname === '127.0.0.1', 'requires isolated loopback test server');
assert(adminToken && out, 'requires test admin token and evidence directory');
const suffix = Date.now().toString(36);
const aliceId = `ui_alice_${suffix}`;
const personId = `ui_person_${suffix}`;
fs.mkdirSync(out, { recursive: true });
const checks = [];
const processes = () =>
  cp
    .execFileSync('ps', ['-axo', 'pid,ppid,command'], { encoding: 'utf8' })
    .trim()
    .split('\n')
    .slice(1)
    .map((line) => {
      const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
      return m && { pid: +m[1], ppid: +m[2], command: m[3] };
    })
    .filter(Boolean);
(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.FLOWSCOPE_TEST_BROWSER_EXECUTABLE || chromium.executablePath(),
  });
  let context;
  const owned = [];
  const profiles = [];
  try {
    const now = processes();
    const pids = new Set([process.pid]);
    let changed = true;
    while (changed) {
      changed = false;
      for (const p of now)
        if (pids.has(p.ppid) && !pids.has(p.pid)) {
          pids.add(p.pid);
          changed = true;
        }
    }
    for (const p of now.filter((p) => pids.has(p.pid) && p.pid !== process.pid)) {
      owned.push(p);
      const m = p.command.match(/--user-data-dir=([^ ]+)/);
      if (m) profiles.push(m[1]);
    }
    context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(`${base}/access`);
    if (await page.getByRole('button', { name: 'Get Started' }).isVisible())
      await page.getByRole('button', { name: 'Get Started' }).click();
    await page.getByLabel('Bearer token').fill(adminToken);
    await page.getByRole('button', { name: '验证并使用' }).click();
    await page.waitForURL('**/policies');
    const identity = await fetch(`${base}/api/lineage/me`, {
      headers: { Authorization: `Bearer ${adminToken}` },
    }).then((r) => r.json());
    assert.equal(
      identity.environment,
      process.env.FLOWSCOPE_TEST_ENVIRONMENT || 'isolated-test',
      'requires an explicitly identified isolated environment'
    );
    await page.getByRole('columnheader', { name: '是否启用', exact: true }).waitFor();
    const bootstrap = page.getByRole('row').filter({ hasText: 'Bootstrap administrator' });
    assert.equal(
      await bootstrap.getByRole('button', { name: '删除', exact: true }).isEnabled(),
      false
    );
    await page.getByRole('button', { name: '新增调用方' }).click();
    await page.getByLabel('调用方 ID', { exact: true }).fill(aliceId);
    await page.getByLabel('显示名称', { exact: true }).fill('测试个人');
    await page.getByRole('button', { name: '保存并生效', exact: true }).click();
    await page.getByText('当前生效版本 1', { exact: true }).waitFor();
    await page.getByRole('status').filter({ hasText: '已保存并生效，版本 1' }).waitFor();
    for (const label of ['允许环境', '允许来源', '禁止来源', '允许表范围'])
      assert.equal(await page.getByLabel(label, { exact: true }).count(), 0);
    checks.push('UI create and save returns active revision 1');
    await page.getByRole('button', { name: '发放 token', exact: true }).click();
    const issued = page.getByTestId('token-value');
    await issued.waitFor();
    const aliceToken = await issued.textContent();
    assert(aliceToken.startsWith('fst_'));
    await page.reload();
    await issued.waitFor();
    assert.equal(await issued.textContent(), aliceToken);
    checks.push('The real issued token remains visible after reloading the policy');
    const tokenSection = page.getByRole('region', { name: 'Token 管理' });
    const tokenList = await fetch(`${base}/api/lineage/policies`, {
      headers: { Authorization: `Bearer ${adminToken}` },
    }).then((r) => r.json());
    const tokenRecord = tokenList.tokens.find((token) => token.principalId === aliceId);
    assert(!(await tokenSection.textContent().then((text) => text.includes(tokenRecord.id))));
    for (const width of [1440, 768, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await tokenSection.scrollIntoViewIfNeeded();
      assert(await issued.evaluate((element) => element.scrollWidth <= element.clientWidth));
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
      await page.screenshot({ path: path.join(out, `token-${width}.png`), fullPage: true });
    }
    await page.evaluate(() => document.documentElement.classList.add('dark'));
    await page.screenshot({ path: path.join(out, 'token-dark.png'), fullPage: true });
    await page.evaluate(() => document.documentElement.classList.remove('dark'));
    await page.setViewportSize({ width: 1440, height: 1000 });
    checks.push('Full credentials wrap without overflow at desktop, tablet and mobile widths');
    await page.route('**/api/lineage/policies', async (route) => {
      if (route.request().method() !== 'GET') return route.continue();
      await route.fulfill({
        json: {
          ...tokenList,
          tokens: tokenList.tokens.map((token) =>
            token.id === tokenRecord.id ? { ...token, token: null } : token
          ),
        },
      });
    });
    await page.reload();
    await page.getByText('该历史 Token 下次成功调用后可显示完整值。', { exact: true }).waitFor();
    assert.equal(await issued.count(), 0);
    assert(!(await tokenSection.textContent().then((text) => text.includes(tokenRecord.id))));
    await page.unroute('**/api/lineage/policies');
    await page.reload();
    await issued.waitFor();
    checks.push(
      'Unavailable legacy values have an explicit explanation and never fall back to UUIDs'
    );
    await page.getByRole('button', { name: '预览，不写图' }).click();
    await page.getByText('调用方已启用 · 记录个人查询使用', { exact: true }).waitFor();
    checks.push('Preview shows the personal action and zero-write statement');
    await page.getByLabel('启用此调用方', { exact: true }).uncheck();
    await page.getByRole('button', { name: '保存并生效', exact: true }).click();
    await page.getByText('当前生效版本 2', { exact: true }).waitFor();
    await page
      .getByRole('row')
      .filter({ hasText: aliceId })
      .getByText('已停用', { exact: true })
      .waitFor();
    assert.equal(
      (
        await fetch(`${base}/api/lineage/me`, {
          headers: { Authorization: `Bearer ${aliceToken}` },
        })
      ).status,
      403
    );
    await page.getByLabel('启用此调用方', { exact: true }).check();
    await page.getByRole('button', { name: '保存并生效', exact: true }).click();
    await page.getByText('当前生效版本 3', { exact: true }).waitFor();
    assert.equal(
      (
        await fetch(`${base}/api/lineage/me`, {
          headers: { Authorization: `Bearer ${aliceToken}` },
        })
      ).status,
      200
    );
    checks.push('Enable state is visible and disabling/re-enabling controls the same token');
    await page.getByRole('button', { name: '撤销', exact: true }).click();
    await page.getByTestId('caller-token').waitFor({ state: 'detached' });
    assert.equal(await page.getByText('已撤销', { exact: true }).count(), 0);
    checks.push('Revoked tokens disappear from the list');
    // A stale form must show 409 instead of claiming activation.
    const adminHeaders = {
      Authorization: `Bearer ${adminToken}`,
      'Content-Type': 'application/json',
    };
    const before = await fetch(`${base}/api/lineage/policies`, { headers: adminHeaders }).then(
      (r) => r.json()
    );
    const policy = before.principals.find((p) => p.id === aliceId);
    const saved = await fetch(`${base}/api/lineage/policies`, {
      method: 'POST',
      headers: adminHeaders,
      body: JSON.stringify({ ...policy, name: '外部更新' }),
    });
    assert.equal(saved.status, 200);
    await page.getByLabel('显示名称', { exact: true }).fill('我的旧表单');
    await page.getByRole('button', { name: '保存并生效', exact: true }).click();
    await page.getByRole('alert').filter({ hasText: '409' }).waitFor();
    checks.push('Concurrent policy update produces a visible revision conflict');
    await page.getByRole('button', { name: '重新加载', exact: true }).click();
    await page.getByText('当前生效版本 4', { exact: true }).waitFor();
    for (const [name, width, height] of [
      ['desktop', 1440, 1000],
      ['user-viewport', 1076, 986],
      ['tablet', 900, 900],
      ['mobile', 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.evaluate(() => document.querySelector('main').scrollTo(0, 0));
      assert(
        await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
        `${name}: document overflow`
      );
      if (name === 'user-viewport') {
        const remove = await page
          .getByRole('row')
          .filter({ hasText: aliceId })
          .getByRole('button', { name: '删除', exact: true })
          .boundingBox();
        assert(
          remove && remove.x >= 0 && remove.x + remove.width <= width,
          'caller delete must fit in the user viewport without horizontal scrolling'
        );
      }
      await page.screenshot({ path: path.join(out, `policies-${name}.png`) });
    }
    checks.push('Desktop/tablet/mobile no document overflow');
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.evaluate(() => document.documentElement.classList.add('dark'));
    // Inspect the settled theme rather than a frame from the control's color transition.
    await page.waitForFunction(() => {
      const link = document.querySelector('header a');
      const heading = document.querySelector('h1');
      const input = document.querySelector('input');
      const select = document.querySelector('select');
      return (
        link &&
        heading &&
        input &&
        select &&
        getComputedStyle(link).color === getComputedStyle(heading).color &&
        getComputedStyle(input).backgroundColor === getComputedStyle(select).backgroundColor
      );
    });

    await page.screenshot({ path: path.join(out, 'policies-dark.png') });
    await page.evaluate(() => document.documentElement.classList.remove('dark'));

    // A separate token proves physical deletion invalidates every token, not just a UI row.
    const extra = await fetch(`${base}/api/lineage/tokens`, {
      method: 'POST',
      headers: adminHeaders,
      body: JSON.stringify({ principalId: aliceId }),
    }).then((r) => r.json());
    const aliceRow = page.getByRole('row').filter({ hasText: aliceId });
    await aliceRow.getByRole('button', { name: '删除', exact: true }).click();
    await page
      .getByRole('region', { name: '删除调用方确认' })
      .getByRole('button', { name: '取消', exact: true })
      .click();
    assert.equal(
      (
        await fetch(`${base}/api/lineage/me`, {
          headers: { Authorization: `Bearer ${extra.token}` },
        })
      ).status,
      200
    );
    await aliceRow.getByRole('button', { name: '删除', exact: true }).click();
    await page.getByRole('button', { name: '确认物理删除', exact: true }).click();
    await page.getByRole('status').filter({ hasText: '已物理删除调用方' }).waitFor();
    assert.equal(await aliceRow.count(), 0);
    assert.equal(
      (
        await fetch(`${base}/api/lineage/me`, {
          headers: { Authorization: `Bearer ${extra.token}` },
        })
      ).status,
      401
    );
    checks.push('Delete confirmation/cancel, row removal, and deleted token rejection');

    await page.setViewportSize({ width: 1440, height: 1000 });
    // Use the token issued by the API for a separate personal caller.
    let res = await fetch(`${base}/api/lineage/policies`, {
      method: 'POST',
      headers: adminHeaders,
      body: JSON.stringify({
        id: personId,
        name: 'UI personal',
        kind: 'person',
        enabled: true,
        action: 'record_usage',
        revision: 0,
      }),
    });
    assert.equal(res.status, 200);
    const personal = await fetch(`${base}/api/lineage/tokens`, {
      method: 'POST',
      headers: adminHeaders,
      body: JSON.stringify({ principalId: personId }),
    }).then((r) => r.json());
    await page.evaluate(
      (token) => sessionStorage.setItem('flowscope.lineage.sessionToken', token),
      personal.token
    );
    await page.goto(`${base}/policies`);
    await page.getByRole('alert').filter({ hasText: '403' }).waitFor();
    assert.equal(await page.getByRole('button', { name: '新增调用方' }).count(), 0);
    checks.push('Personal token cannot access policy controls');
    // Token management can be verified without an isolated Neo4j fixture.
    if (process.env.FLOWSCOPE_TEST_TOKEN_ONLY !== '1') {
      const query = await fetch(`${base}/api/analyze`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${personal.token}` },
        body: JSON.stringify({
          sql: 'SELECT id FROM dw.audit_example WHERE id > 10',
          sourceName: '个人使用验证',
        }),
      });
      assert.equal(query.status, 200);
      const eventId = query.headers.get('x-flowscope-event-id');
      for (let i = 0; i < 100; i++) {
        const event = await fetch(`${base}/api/lineage/events/${eventId}`, {
          headers: adminHeaders,
        }).then((r) => r.json());
        if (event.status !== 'queued') break;
        await new Promise((r) => setTimeout(r, 100));
      }
      await page.goto(`${base}/audit`);
      await page.getByRole('columnheader', { name: /入图状态/ }).waitFor();
      await page.getByRole('columnheader', { name: '个人使用', exact: true }).waitFor();
      await page.getByRole('cell', { name: '已提交', exact: true }).waitFor();
      await page.getByRole('cell', { name: '未请求入图', exact: true }).waitFor();
      await page.screenshot({ path: path.join(out, 'audit-personal.png') });
      checks.push('Personal audit shows separate parse/formal/usage states');
      await page.getByRole('button', { name: 'Open lineage', exact: true }).click();
      await page.waitForURL(/auditId=/);
      await page.getByTestId('app-header').waitFor();
      await page
        .getByText(/audit#/)
        .first()
        .waitFor();
      checks.push('Personal audit details open without server file access');
    }

    assert.deepEqual(errors, []);
    const removedPerson = await fetch(`${base}/api/lineage/policies/${personId}`, {
      method: 'DELETE',
      headers: adminHeaders,
      body: JSON.stringify({ revision: 1 }),
    });
    assert.equal(removedPerson.status, 200);
    checks.push('Synthetic personal caller removed after verification; audit history retained');
  } finally {
    try {
      if (context) await context.close();
    } finally {
      await browser.close();
    }
    const alive = processes().filter((p) =>
      owned.some((o) => o.pid === p.pid && o.command === p.command)
    );
    const remainingProfiles = profiles.filter((p) => fs.existsSync(p));
    fs.writeFileSync(
      path.join(out, 'browser-cleanup.json'),
      JSON.stringify(
        {
          ownedPids: owned.map((p) => p.pid),
          remainingPids: alive.map((p) => p.pid),
          remainingProfiles,
        },
        null,
        2
      )
    );
    assert.equal(alive.length, 0, 'owned browser process leaked');
    assert.equal(remainingProfiles.length, 0, 'temporary browser profile leaked');
  }
  fs.writeFileSync(
    path.join(out, 'ui-checks.json'),
    JSON.stringify(
      {
        checks,
        scope: process.env.FLOWSCOPE_TEST_TOKEN_ONLY === '1' ? 'token-management' : 'full-lineage',
        result: 'passed',
      },
      null,
      2
    )
  );
  console.log(JSON.stringify({ checks, result: 'passed', cleanup: 'passed' }));
})().catch((e) => {
  console.error(e.stack);
  process.exitCode = 1;
});
