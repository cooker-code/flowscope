import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '/Users/blank/.agents/skills/motion-showreel/scripts/node_modules/playwright/index.mjs';

const research = path.dirname(fileURLToPath(import.meta.url));
const binary = process.argv[2];
assert(binary, 'Usage: node verify_ui.mjs /absolute/path/to/flowscope');
const temp = await mkdtemp(path.join(tmpdir(), 'flowscope-audit-ui-'));
const token = randomBytes(32).toString('hex');
const { createServer } = await import('node:net');
const probe = createServer();
await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
const port = probe.address().port;
await new Promise((resolve) => probe.close(resolve));
const base = 'http://127.0.0.1:' + port;
const config = path.join(temp, 'config.json');
await writeFile(config, JSON.stringify({
  stateDb: path.join(temp, 'state.db'), adminTokenEnv: 'AUDIT_UI_ADMIN',
  neo4j: { uri: '127.0.0.1:9', user: 'neo4j', passwordEnv: 'AUDIT_UI_NEO4J',
    database: 'neo4j', environment: 'test' },
}));
const server = spawn(binary,
  ['--serve', '--port', String(port), '--audit-log', path.join(temp, 'state.db'),
    '--lineage-config', config], {
    cwd: temp, env: { ...process.env, AUDIT_UI_ADMIN: token, AUDIT_UI_NEO4J: 'isolated-unused-password' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
let logs = '';
server.stdout.on('data', (value) => { logs += value; });
server.stderr.on('data', (value) => { logs += value; });
const serverStopped = once(server, 'exit');
const report = { serverPid: server.pid, checks: [], browserPids: [] };
let browser;
let context;
let page;
const processTable = () => execFileSync('ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8' })
  .split('\n').map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/))
  .filter(Boolean).map((match) => ({ pid: Number(match[1]), parent: Number(match[2]), command: match[3] }));
try {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch(base + '/api/health', { headers: { Authorization: 'Bearer ' + token } });
      assert(response.ok);
      break;
    } catch (error) {
      if (attempt >= 100 || server.exitCode !== null) throw new Error(logs, { cause: error });
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  const sql = await readFile(path.resolve(research, '../../../../crates/flowscope-cli/tests/fixtures/audit-with-select.sql'), 'utf8');
  const analyzed = await fetch(base + '/api/analyze', {
    method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ sql, sourceName: 'regression-652177', storageMode: 'parse_only' }),
  });
  assert(analyzed.ok);
  const analysis = await analyzed.json();
  assert.equal(analysis.sqlType, 'select');
  assert.equal(analysis.summary.hasErrors, false);
  let auditType;
  for (let attempt = 0; attempt < 100; attempt++) {
    const response = await fetch(base + '/api/audit?source_name=regression-652177', {
      headers: { Authorization: 'Bearer ' + token },
    });
    const audit = await response.json();
    auditType = audit.records?.[0]?.sql_type;
    if (auditType) break;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.equal(auditType, 'SELECT');
  report.checks.push('real audit 652177 SQL returns select and persists SELECT through HTTP');
  browser = await chromium.launch({ headless: true });
  // Every action after successful launch is protected by the finally below.
  context = await browser.newContext({ viewport: { width: 1280, height: 960 }, colorScheme: 'dark' });
  await context.addInitScript((credential) => {
    sessionStorage.setItem('flowscope.lineage.sessionToken', credential);
  }, token);
  page = await context.newPage();
  page.setDefaultTimeout(10000);
  const browserErrors = [];
  page.on('pageerror', (error) => browserErrors.push(String(error)));
  await page.goto(base + '/policies');
  await page.getByRole('button', { name: 'Get Started', exact: true }).click();
  const input = page.getByLabel('保留天数', { exact: true });
  await input.waitFor();
  await page.waitForFunction(() => document.querySelector('#audit-retention-days')?.value === '7');
  report.checks.push('fresh embedded UI loads server default 7 days');
  await page.getByRole('button', { name: '新增调用方', exact: true }).click();
  await page.getByLabel('调用方 ID', { exact: true }).fill('unsaved-draft');
  await page.getByLabel('显示名称', { exact: true }).fill('未保存草稿');
  await input.fill('14');
  await page.getByRole('button', { name: '保存保留天数', exact: true }).click();
  await page.getByRole('status').filter({ hasText: '已保存，过期审计日志' }).waitFor();
  assert.equal(await page.getByLabel('调用方 ID', { exact: true }).inputValue(), 'unsaved-draft');
  report.checks.push('saving retention preserves unsaved caller draft');
  await page.goto(base + '/policies');
  await page.waitForFunction(() => document.querySelector('#audit-retention-days')?.value === '14');
  report.checks.push('reload reads persisted server value 14');
  await input.fill('0');
  assert.equal(await input.evaluate((element) => element.checkValidity()), false);
  report.checks.push('browser blocks non-positive values');
  await input.fill('7');
  await page.getByRole('button', { name: '保存保留天数', exact: true }).click();
  await page.getByRole('status').filter({ hasText: '已保存，过期审计日志' }).waitFor();
  await page.screenshot({ path: path.join(research, 'retention-desktop.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await input.scrollIntoViewIfNeeded();
  assert(await input.isVisible());
  assert(await page.getByRole('button', { name: '保存保留天数', exact: true }).isVisible());
  const widths = await page.evaluate(() => ({
    scroll: document.documentElement.scrollWidth, viewport: window.innerWidth,
  }));
  assert(widths.scroll <= widths.viewport, JSON.stringify(widths));
  await page.screenshot({ path: path.join(research, 'retention-mobile.png'), fullPage: true });
  report.checks.push('390px viewport keeps retention controls visible without page overflow');
  await input.fill('8');
  await input.focus();
  await page.keyboard.press('Tab');
  assert.equal(await page.evaluate(() => document.activeElement?.textContent), '保存保留天数');
  assert.deepEqual(browserErrors, []);
  report.checks.push('keyboard focus and page runtime have no errors');

} catch (error) {
  report.error = String(error);
  if (page) {
    report.bodyText = await page.locator('body').innerText().catch(() => 'unavailable');
    await page.screenshot({ path: path.join(research, 'retention-ui-failure.png'), fullPage: true }).catch(() => {});
  }
  process.exitCode = 1;
} finally {
  const table = processTable();
  const owned = new Set([process.pid]);
  for (let iteration = 0; iteration < 10; iteration++) {
    for (const item of table) if (owned.has(item.parent)) owned.add(item.pid);
  }
  report.browserPids = table.filter((item) => owned.has(item.pid) && /chromium|chrome|headless_shell/i.test(item.command))
    .map((item) => item.pid);

  try {
    try {
      if (context) await context.close();
    } finally {
      if (browser) await browser.close();
    }
  } finally {
    if (server.exitCode === null) server.kill('SIGINT');
    const timeout = setTimeout(() => server.kill('SIGKILL'), 10000);
    try {
      await serverStopped;
    } finally {
      clearTimeout(timeout);
      await rm(temp, { recursive: true, force: true });
    }
  }
  // Verify actual process exit independently of close() and wait().
  let survivors = [];
  for (let attempt = 0; attempt < 20; attempt++) {
    const current = new Set(processTable().map((item) => item.pid));
    survivors = [...report.browserPids, server.pid].filter((pid) => current.has(pid));
    if (survivors.length === 0) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  report.survivingOwnedPids = survivors;
  report.serverExitCode = server.exitCode;
  report.temporaryDirectoryRemoved = true;
  if (survivors.length || server.exitCode !== 0) process.exitCode = 1;
  await writeFile(path.join(research, 'ui-verification.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
}
