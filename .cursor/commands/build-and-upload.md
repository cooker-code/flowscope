# 编译打包 + 上传 CLI 二进制

一键完成：**前端构建 → 嵌入 CLI → 交叉编译 Linux 二进制 → 产物校验 → 上传 CDN**。

最终产物只有一个：`target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope`（~72 MB）。
前端 `app/dist/` 通过 `rust-embed` 编译进二进制，**不单独上传** —— 服务器拉一份 binary 重启即拿到对应的前端版本，UI/CLI 永远一致。

> **不是 Trellis 流程**。这个 command 假定 bug 已修完、代码已 commit、测试已绿。如果你刚改完代码还没提交，先回 `/trellis-finish-work` 走完归档再来。
>
> **何时用**：
> - 修完 bug 要发版给后端服务器拉取
> - 需要把当前 master 的 CLI 二进制分享给同事 / 部署到测试环境
> - 不需要 scp（如果服务器无法直接外网 pull，那再走 `docs/release-workflow.md` 的 scp 流程）

---

## Step 0 — 预检（30 秒，快速失败）

```bash
cd /Users/blank/wangliang/gitcode/flowscope

# 工作区状态（不要带未提交的功能改动上船）
git status --porcelain

# 核心引擎单测必须全绿
cargo test -p flowscope-core --lib 2>&1 | tail -5

# Rust ↔ TS schema 兼容（确认前后端字段同源）
yarn workspace @pondpilot/flowscope-core test schema-compat.test.ts --silent 2>&1 | tail -5

# 真实生产 SQL 头部字段回归（钉死在 test-sql/.regression-expect.json）
python3 ./scripts/regression-test-sql.py 2>&1 | tail -5
```

**失败处理**：
- 工作区脏 → 决定是 commit 还是 stash，再回来
- 单测红 → 修完再发，绝不带红发
- schema-compat 红 → 多半改了 `AnalyzeResult` 结构，先跑 `node ./scripts/update_api_schema.cjs` 再 commit
- regression 红 → 看 `.regression-expect.json` 钉的字段是哪个漂了，决定是 bug 还是要更新 baseline

---

## Step 1 — 编译前端（生成 `app/dist/`）

```bash
cd app && yarn build && cd ..
```

预期产物：
- `app/dist/index.html`
- `app/dist/assets/*` （含 `index-<hash>.js` ≈ 6.8 MB，是 bundle 主体）
- `app/dist/wasm/*` （DuckDB wasm 等）
- `app/dist/favicon.svg` / `polly-icon.svg`
- 总大小 ≈ 19 MB

> 出现 `(!) Some chunks are larger than 500 kB` 是已知警告（主 bundle 体积），不阻塞发版。

---

## Step 2 — 同步前端资产到 CLI 嵌入目录

```bash
rm -rf crates/flowscope-cli/embedded-app
mkdir -p crates/flowscope-cli/embedded-app
cp -R app/dist/. crates/flowscope-cli/embedded-app/

# 自检：embedded-app 与 dist 必须一致
diff -q app/dist/index.html crates/flowscope-cli/embedded-app/index.html
```

`diff -q` 无输出 = 同步成功。这是"UI/CLI 一致性"的物理保障（同一份 `dist` 同时进 `embedded-app/` 和发布 zip / CDN —— 但本 command 只走 embedded 路径，不打 dist zip）。

---

## Step 3 — 交叉编译 CLI（Linux glibc 2.17，服务器可跑）

```bash
cargo zigbuild \
  --target x86_64-unknown-linux-gnu.2.17 \
  --target-dir target-zigbuild \
  -p flowscope-cli \
  --features serve \
  --release
```

> 增量编译大约 25 秒；首次/clean build 5-10 分钟。
> `target-zigbuild/` 与本机 `target/` 隔离，避免 build cache 互相污染。

产物路径：

```
target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope
```

---

## Step 4 — 产物校验（每次都做，3 个硬指标）

```bash
BIN=target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope

# 1. 文件格式必须是 Linux ELF + stripped
file "$BIN"
# ✅ 期望：ELF 64-bit LSB pie executable, x86-64, ..., for GNU/Linux 2.0.0, stripped

# 2. 最高 GLIBC 引用 ≤ 2.17（CentOS 7 / 阿里内网服务器底线）
strings "$BIN" | rg '^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V -u | tail -3
# ✅ 期望：GLIBC_2.15 / GLIBC_2.16 / GLIBC_2.17（不能出现 2.18+）

# 3. libstdc++ 必须静态链接（动态会缺 GLIBCXX_3.4.21+）
strings "$BIN" | rg '^GLIBCXX_' | head -1
# ✅ 期望：空输出
```

任一不符 → 回 Step 3 排查 zigbuild 配置（极少见，通常是 toolchain 漂了）。

---

## Step 5 — 双端一致性 self-check（强烈建议）

mac 本机版的输出必须和 Linux 交叉编译版完全一致（同一份代码、同一份 schema）。

**Baseline 不写死在 command 里**：直接读 `test-sql/.regression-expect.json`，跟那里钉的字段对比。任意一个 fixture 都可以做 self-check，默认用 `dwd_conan_user_order_da.sql`（生产 5-source INSERT，覆盖面够广）。

```bash
# 本机 mac 版（与交叉编译同一份代码）
cargo build -p flowscope-cli --features serve --release

# 一键对照：读 expect.json 期望 vs CLI 实际输出
FIXTURE="${FIXTURE:-dwd_conan_user_order_da.sql}"
./target/release/flowscope "test-sql/$FIXTURE" -d hive -f json > /tmp/flowscope-mac.json

python3 - "$FIXTURE" <<'PY'
import json, sys
fixture = sys.argv[1]
expect = json.load(open('test-sql/.regression-expect.json'))[fixture]
got = json.load(open('/tmp/flowscope-mac.json'))

tt = got.get('targetTable') or {}
target = tt.get('qualifiedName') if isinstance(tt, dict) else tt
got_stmts = [s.get('statementType') for s in got.get('statements', [])]
got_src_count = len(got.get('sourceTables') or [])
got_errs = sum(1 for i in got.get('issues', []) if i.get('severity') == 'error')

checks = [
    ('sqlType',        expect.get('sqlType'),         got.get('sqlType')),
    ('insertType',     expect.get('insertType'),      got.get('insertType')),
    ('targetTable',    expect.get('targetTable'),     target),
    ('sourceCount',    expect.get('sourceCount'),     got_src_count),
    ('statementTypes', expect.get('statementTypes'),  got_stmts),
    ('errorCount',     expect.get('errorCount'),      got_errs),
]

fail = False
for name, exp, act in checks:
    if exp is None:
        print(f'  {name:14s} skipped (not pinned in expect.json)')
        continue
    ok = exp == act
    mark = '✅' if ok else '❌'
    print(f'  {mark} {name:14s} expect={exp!r} got={act!r}')
    if not ok:
        fail = True

sys.exit(1 if fail else 0)
PY
```

任一字段漂 → 说明这次的预处理 / 分析逻辑出了非预期变化，**停下来 `git bisect` 定位再发**。

> 切换 baseline 用 `FIXTURE=29463.sql ...` 即可。所有钉在 `.regression-expect.json` 里的 fixture 都可以当 baseline。

---

## Step 6 — 上传 CLI 二进制到 CDN

```bash
# upload-h5.sh 已经支持任意文件类型，自动识别 mime；二进制走 application/octet-stream
# UPLOAD_MAX_MB 默认 200，足够当前 ~72 MB 的 flowscope
# 用 tee 同时打屏 + 抓输出，最后行就是 CDN URL
UPLOAD_LOG=$(mktemp)
./scripts/upload-h5.sh target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope | tee "$UPLOAD_LOG"

# 提取最后一行的 URL（脚本以 `URL: http://...` 结尾），传给 Step 7
CDN_URL=$(rg -o 'http://[^[:space:]]+' "$UPLOAD_LOG" | tail -1)
echo "CDN_URL=$CDN_URL"
rm -f "$UPLOAD_LOG"
```

脚本会：
1. 计算本地 sha256，POST 到 `https://upload.zhenguanyu.com/upfile`
2. 拿到 CDN URL：`http://upload.zhenguanyu.com/uploads/<hash>_flowscope`
3. 下载 remote 副本对比 sha256，**不一致直接 exit 1**

> 如果端点开始要求 SSO（出现 302 或非 URL 响应），改走浏览器上传：[https://upload.zhenguanyu.com/h5/](https://upload.zhenguanyu.com/h5/) 然后手动把返回的 URL 赋给 `CDN_URL` 变量交给 Step 7
>
> 如果 size 检查报错 → `UPLOAD_MAX_MB=500 ./scripts/upload-h5.sh ...` 临时放宽，并查一下是不是二进制意外变胖了

---

## Step 7 — 写入归档 release notes

每次发版**必须**生成一份归档 release note 到 `release-notes/<YYYYMMDD-HHMM>.md`，并 commit 进 git，方便后续追溯哪个二进制对应哪个 commit / CDN URL。

依赖 Step 6 设置的 `$CDN_URL` 变量；如果走的是浏览器手动上传，先 `export CDN_URL=http://upload.zhenguanyu.com/uploads/...`。

```bash
[ -n "${CDN_URL:-}" ] || { echo "error: CDN_URL not set, did Step 6 succeed?" >&2; exit 1; }

mkdir -p release-notes
TS=$(date +%Y%m%d-%H%M)
NOTE="release-notes/${TS}.md"
BIN=target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope
LOCAL_SHA=$(shasum -a 256 "$BIN" | awk '{print $1}')
SIZE=$(du -h "$BIN" | cut -f1)
HEAD_COMMIT=$(git log -1 --pretty='format:%h %s')
PREV_NOTE=$(ls release-notes/ 2>/dev/null | rg -v "${TS}" | sort | tail -1)

# 列出最近 3 个非 chore commits（功能/修复主线，方便看本次发版包含什么）
RECENT_WORK=$(git log -20 --pretty='format:- %h %s' | rg -v ' chore(\(|:)' | head -3)

cat > "$NOTE" <<EOF
# FlowScope CLI Release — ${TS}

## Binary

- **size**: ${SIZE}
- **sha256**: \`${LOCAL_SHA}\`
- **format**: ELF/x86-64, GLIBC ≤ 2.17, libstdc++ static
- **CDN URL**: <${CDN_URL}>

## Source

- **HEAD**: \`${HEAD_COMMIT}\`
- **本次包含的非 chore commits（最近 3 条）**:
${RECENT_WORK}

## 部署（拷给运维 / 拉新版的同事）

\`\`\`bash
cd ~/wangliang/flowscope-main
curl -fsSL "${CDN_URL}" -o flowscope.new
chmod +x flowscope.new
./flowscope.new --version
echo "${LOCAL_SHA}  flowscope.new" | shasum -a 256 -c -        # 必须 OK
mv flowscope.new flowscope
tmux kill-session -t flowscope 2>/dev/null || true
tmux new -d -s flowscope "./flowscope --serve --host 0.0.0.0 --port 7681 --audit-log data/audit.db"
\`\`\`

## 回滚

上一份归档：${PREV_NOTE:+\`release-notes/${PREV_NOTE}\`}${PREV_NOTE:-_(首次发版，无前序)_}
EOF

echo "Wrote $NOTE"

git add "$NOTE"
git commit -m "chore(release): cli binary ${TS}"
```

完成后给用户简短汇总（**不要把 release note 整段复述**，已经写进文件了，告知文件路径 + CDN URL + commit hash 即可）。

---

## 失败回退

- Step 0 预检红 → 不发，回去修
- Step 3 zigbuild 失败 → 通常是 `cargo install cargo-zigbuild` 没装 / zig 版本不对，参考 `docs/release-workflow.md` 一次性环境准备
- Step 4 校验失败 → 99% 是 toolchain 漂，`rustup target add x86_64-unknown-linux-gnu` 重装再试
- Step 5 双端不一致 → **严重**，停下来 git bisect 定位哪次改动引入了非确定性
- Step 6 上传失败 → 看 stderr，常见：网络断 / SSO 启用 / size 超过 `UPLOAD_MAX_MB`

---

## 参考

完整发布 SOP（含 H5 前端 zip 上传、scp 到 Neo4j 服务器、tmux 重启）：[`docs/release-workflow.md`](../../docs/release-workflow.md)

本 command 是 SOP 的**轻量子集**，专门处理"只更新 CLI 二进制"的最常见场景。
