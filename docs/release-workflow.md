# FlowScope 打包发布 SOP

> **核心目标**：一次打包，前端（H5 CDN）和 CLI（Neo4j 服务器）看到的分析结果**完全一致**。
>
> **唯一来源**：`app/dist/` 是前端唯一产物，同时被 ① 上传到 H5 CDN，② 通过 `sync-cli-serve-assets` 嵌入 CLI 二进制。两边永远是同一份。
>
> **核心约束**：
> - 服务器（CentOS 7 / glibc 2.17 / 阿里内网）不能本机编 → 必须 `cargo zigbuild` 交叉编译。
> - 生产分析跑后端（CLI serve），前端只走 REST，**WASM 用不到** → 不需要 `wasm-pack`。

以后说"打包发布"就走这份文档。

---

## 一、一次性环境准备（本机 Mac，只做一次）

```bash
brew install zig
cargo install cargo-zigbuild
rustup target add x86_64-unknown-linux-gnu
```

> 不需要 `wasm-pack`、不需要 `just`（本文档全部用原生命令，便于复制粘贴）。

验证：

```bash
zig version              # ≥ 0.13
cargo-zigbuild --version
rustup target list --installed | grep x86_64-unknown-linux-gnu
```

---

## 二、UI/CLI 一致性原理（必读，理解了才不会踩坑）

```
                              app/dist/
                          （单一前端产物）
                         /                 \
                        /                   \
              ① 上传到 H5 CDN          ② sync-cli-serve-assets
              https://upload.            ↓
              zhenguanyu.com/h5/    crates/flowscope-cli/embedded-app/
                                          ↓
                                    cargo zigbuild
                                          ↓
                                  target-zigbuild/.../flowscope
                                          ↓
                                  scp 到 Neo4j 服务器
                                  flowscope --serve
```

**只要这两条路出自同一次 `yarn build`，UI 和 CLI 看到的就是同一份代码、同一份 schema。** 顺序绝对不能颠倒，不能跨次混用。

---

## 三、标准发布流程（每次发版完整走一遍）

### Step 0 — 预检（30 秒）

```bash
cd /Users/blank/wangliang/gitcode/flowscope

git status                                     # 工作区干净，或确认要发版的改动都在
cargo test -p flowscope-core --lib             # 核心引擎单测必须全绿
yarn workspace @pondpilot/flowscope-core test schema-compat.test.ts --silent
just regression-sql                            # 真实生产 SQL 头部字段回归（test-sql/*.sql）
```

> `just regression-sql` 会跑 `test-sql/*.sql` 全集（含 `ads_course_user_gift_card_stat_di.sql` 等真实生产脚本）。
> 钉死的预期在 `test-sql/.regression-expect.json`：`sqlType` / `insertType` / `targetTable` / `sourceCount` / `sources` / `statementTypes` / `errorCount` 任一字段漂移立即 FAIL。
> 新增 SQL 只需丢进 `test-sql/`，脚本自动纳入（不在 expect.json 里的文件只做"无 error + 至少一条 statement"的软校验）。

如果 Rust 改了 `AnalyzeResult` 结构，必须先跑：

```bash
node ./scripts/update_api_schema.cjs           # 重新生成 docs/api_schema.json
```

### Step 1 — 构建前端（生成 `app/dist/`）

```bash
cd app && yarn build && cd ..
```

产物：`app/dist/`（约 19 MB，含 `index.html`、`assets/`、`wasm/`、`favicon.svg`）。

### Step 2 — 同步前端资产到 CLI 嵌入目录

```bash
rm -rf crates/flowscope-cli/embedded-app
mkdir -p crates/flowscope-cli/embedded-app
cp -R app/dist/. crates/flowscope-cli/embedded-app/
```

> 这一步等价于 `just sync-cli-serve-assets`，手工写出来是为了让 CI/无 just 的环境也能跑。

**自检**：

```bash
ls crates/flowscope-cli/embedded-app/index.html   # 必须存在，没有就是 sync 失败
diff -q app/dist/index.html crates/flowscope-cli/embedded-app/index.html   # 必须无输出
```

### Step 3 — 交叉编译 CLI（Linux glibc 2.17）

```bash
cargo zigbuild \
  --target x86_64-unknown-linux-gnu.2.17 \
  --target-dir target-zigbuild \
  -p flowscope-cli \
  --features serve \
  --release
```

**为什么 `target-zigbuild/` 是独立目录**：与默认 `target/`（本机 macOS 调试产物）隔离，避免 build cache 互相污染。这也是 `target-zigbuild/` 名字的由来——`cargo-zigbuild` 用的工作目录。

产物：

```
target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope
```

约 **72 MB**（stripped、内嵌了 ~19 MB 前端资产）。

### Step 4 — 验证产物（每次都做）

```bash
BIN=target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope

file "$BIN"
# ✅ 期望：ELF 64-bit LSB pie executable, x86-64, ..., for GNU/Linux 2.0.0, stripped

strings "$BIN" | rg '^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V -u | tail -3
# ✅ 期望：最高 GLIBC_2.17（出现 2.18+ 服务器跑不了，立刻回 Step 3 排查）

strings "$BIN" | rg '^GLIBCXX_' | head -1
# ✅ 期望：空输出（libstdc++ 已静态链接）
```

### Step 5 — 双端一致性自检（强烈建议）

用一个固定的回归 SQL（例如 `test-sql/dwd_conan_user_order_da.sql`）做 diff：

```bash
cargo build -p flowscope-cli --features serve --release  # 本机 macOS 版
./target/release/flowscope test-sql/dwd_conan_user_order_da.sql -d hive -f json \
  > /tmp/flowscope-mac.json

# 关键字段对照（sqlType / insertType / targetTable / sourceTables / statements）
python3 -c "import json; d=json.load(open('/tmp/flowscope-mac.json')); \
  print('sqlType:', d['sqlType']); \
  print('insertType:', d.get('insertType')); \
  print('targetTable:', (d.get('targetTable') or {}).get('qualifiedName')); \
  print('sourceTables:', len(d.get('sourceTables') or [])); \
  print('statements:', [(s['statementIndex'], s['statementType']) for s in d['statements']])"
```

预期（以当前回归 SQL 为基线）：

```
sqlType: insert
insertType: overwrite
targetTable: dw_conan_dwd.dwd_conan_user_order_da
sourceTables: 5
statements: [(0, 'INSERT')]
```

Linux 二进制不能在 mac 直接跑，但同一份代码在两端表现一致——本机 `target/release` 跑通即可代表 `target-zigbuild/` 也跑通。

---

## 四、发布上线

### 4.1 上传 H5 前端到 CDN

**自动上传（推荐，无需登录）**：

```bash
cd /Users/blank/wangliang/gitcode/flowscope
(cd app/dist && zip -qr "$OLDPWD/flowscope-h5-$(date +%Y%m%d-%H%M).zip" .)
./scripts/upload-h5.sh         # 自动选最新 flowscope-h5-*.zip，上传 + 校验 sha256
# 或指定文件：
# ./scripts/upload-h5.sh flowscope-h5-20260521-1829.zip
```

脚本会：
1. POST 到 `https://upload.zhenguanyu.com/upfile`（Huploadify 字段 `file`，10MB 上限）
2. 拿到 CDN URL：`http://upload.zhenguanyu.com/uploads/<hash>_<filename>.zip`
3. 下载 remote 副本验证 sha256，**不一致直接 exit 1**

> 命名约定：`flowscope-h5-YYYYMMDD-HHMM.zip`，方便回滚定位版本。
> 服务端按文件名 hash 去重：同名文件重复上传返回同一个 URL（rename + 重传可拿新 URL）。
> 已知探测结果：端点目前对公司内网开放、不需要 cookie/SSO。如果未来开始要求登录（脚本报"non-URL response"），回退到浏览器：[https://upload.zhenguanyu.com/h5/](https://upload.zhenguanyu.com/h5/) 手动上传。

**手动上传（备份方案）**：浏览器打开上面的入口，拖拽 zip。完成后页面会显示 `http://upload.zhenguanyu.com/uploads/...` URL。

### 4.2 部署 CLI 到 Neo4j 服务器

```bash
scp target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope \
  maintain@alibjh-op-neo4j1-vm:~/wangliang/flowscope-main/
```

服务器侧重启：

```bash
ssh maintain@alibjh-op-neo4j1-vm

cd ~/wangliang/flowscope-main
chmod +x flowscope
./flowscope --version                                  # 确认版本号

# 重启 tmux 后台进程
tmux kill-session -t flowscope 2>/dev/null || true
tmux new -d -s flowscope "./flowscope --serve \
  --host 0.0.0.0 --port 7681 \
  --audit-log data/audit.db"

# 健康检查
sleep 2
curl -fsS http://localhost:7681/api/health
```

> `--audit-log` **必须携带**（详见 `CLAUDE.md` 与 `AGENTS.md`），不带会导致审计功能不可用。

### 4.3 线上回归（双端各跑一次同样 SQL）

1. 浏览器访问 H5 地址，在 UI 里跑回归 SQL，记录 `sqlType / insertType / targetTable / sourceTables`。
2. CLI 上跑同一份 SQL：

   ```bash
   ssh maintain@alibjh-op-neo4j1-vm \
     "cd ~/wangliang/flowscope-main && ./flowscope /tmp/regression.sql -d hive -f json" \
     | python3 -c "import sys,json; d=json.load(sys.stdin); \
       print(d['sqlType'], d.get('insertType'), \
             (d.get('targetTable') or {}).get('qualifiedName'), \
             len(d.get('sourceTables') or []))"
   ```

3. 两边数字/字段必须一致。**不一致就是上下游版本错位**，立刻回滚（保留前一次 zip 和上一份 CLI 二进制）。

---

## 五、回滚

| 类型 | 操作 |
|------|------|
| H5 前端回滚 | 在 `upload.zhenguanyu.com/h5/` 后台切回上一版本（保留至少最近 3 个版本的 zip） |
| CLI 回滚 | 服务器侧把 `flowscope` 替换为上一版备份，`tmux kill-session` 后重启 |
| 一致性回滚 | 永远 H5 和 CLI 一起回，不允许只回单边 |

建议每次 scp 前在服务器上备份：

```bash
ssh maintain@alibjh-op-neo4j1-vm \
  "cd ~/wangliang/flowscope-main && cp flowscope flowscope.bak.$(date +%Y%m%d-%H%M)"
```

---

## 六、常见错误对照表

| 现象 | 根因 | 修复 |
|------|------|------|
| CLI 输出新字段、H5 没有 | 只跑了 zigbuild、忘了上传 H5 | 重新走 Step 1 → 4.1 |
| H5 有新字段、CLI 没有 | 只 `yarn build` 没 `sync-cli-serve-assets` 或没 zigbuild | 重新走 Step 2 → 4.2 |
| 服务器报 `GLIBC_2.18 not found` | 误用 `cargo build` 或 `cross build` | 回 Step 3 严格用 `cargo zigbuild` |
| Step 4 出现 `GLIBCXX_` 符号 | libstdc++ 没静态链接 | zig 版本太老，`brew upgrade zig` 到 0.13+ |
| `embedded-app/index.html` 缺失 | 跳过了 Step 2 | 重跑 Step 2 |
| CLI 二进制突然变大 | 漏了 `--release` | 回 Step 3 加回 |
| 服务器内网访问不到 7681 | 启动漏了 `--host 0.0.0.0` 或公司防火墙 | 检查 `ss -tlnp \| grep 7681` |

---

## 七、流程速查（贴墙版）

```bash
# 一行版（按顺序复制粘贴即可）
cd /Users/blank/wangliang/gitcode/flowscope \
  && (cd app && yarn build) \
  && rm -rf crates/flowscope-cli/embedded-app \
  && mkdir -p crates/flowscope-cli/embedded-app \
  && cp -R app/dist/. crates/flowscope-cli/embedded-app/ \
  && cargo zigbuild \
       --target x86_64-unknown-linux-gnu.2.17 \
       --target-dir target-zigbuild \
       -p flowscope-cli --features serve --release \
  && BIN=target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope \
  && file "$BIN" \
  && strings "$BIN" | rg '^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V -u | tail -1 \
  && (cd app/dist && zip -qr "$OLDPWD/flowscope-h5-$(date +%Y%m%d-%H%M).zip" .) \
  && ./scripts/upload-h5.sh \
  && echo "==> 然后 scp $BIN maintain@alibjh-op-neo4j1-vm:~/wangliang/flowscope-main/"
```

---

## 八、相关文档

- `docs/build-for-neo4j-server.md` — `cargo-zigbuild` 方案的历史背景和深度排错（必读一次）。
- `AGENTS.md` § Build Commands — 本机日常开发命令。
- `CLAUDE.md` § 本地开发完整启动顺序 — dev 模式启动顺序。
- `justfile` § `sync-cli-serve-assets` / `build-cli-serve` — `just` 用户的等价命令。

---

## 九、变更记录

| 日期 | 变更 | 触发原因 |
|------|------|---------|
| 2026-05-21 | 初版，沉淀"前端单一产物 + zigbuild + H5 上传"完整发布流程 | 之前每次发布都临时拼步骤，UI 和 CLI 字段对不上时排查成本高 |
| 2026-05-21 | 加入 `scripts/upload-h5.sh` 自动上传 + sha256 校验；加入 `just regression-sql` 真实 SQL 回归 | 探明上传站点对内网公开（无需 SSO），可自动化；同时把生产 SQL 沉淀成回归套件 |
