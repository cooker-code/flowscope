# `scripts/` 目录说明

> FlowScope 仓库的辅助脚本集合。**所有脚本必须从仓库根目录调用**（`./scripts/xxx`），脚本内部已固定 `cd "$(dirname "$0")/.."` 或假设 cwd 为 repo root。

## 调用方式速查

每个脚本都有"自动入口"和"手动入口"两种用法。自动入口是 `just <target>` / pre-commit / CI；手动入口是 `./scripts/xxx`。**新代码请优先用自动入口**，自动入口出问题再降级手动调试。

---

## 一、构建 & schema 同步

### `build-rust.sh`

编译 Rust workspace（release）+ WASM 模块，并把 WASM 产物同步到 3 个位置：
- `packages/core/wasm/`（npm 发布目录，提交进 git）
- `packages/core/src/wasm`（指向上面目录的 symlink，给 TS import 用）
- `app/public/wasm/`（Vite dev server 直接对外服务）

| 入口 | 命令 |
|---|---|
| 自动 | `just build-wasm` / `just build-wasm-dev`（后者跳过 `wasm-opt`，开发更快） |
| 手动 | `./scripts/build-rust.sh [--no-opt]` |

> ⚠️ 依赖 `wasm-pack`，没装先跑 `just install-rust-tools`。

### `update_api_schema.cjs`

从 Rust 的 `flowscope-core::schema_guard` 测试里抽出 `AnalyzeRequest`/`AnalyzeResult` 等 schema JSON，写入 `docs/api_schema.json`。前后端用它做契约一致性校验。

| 入口 | 命令 |
|---|---|
| 自动 | `just update-schema` |
| 手动 | `node ./scripts/update_api_schema.cjs` |

### `check_schema_sync.sh`

pre-commit 钩子：跑 `update_api_schema.cjs` 后用 `git diff` 检查 `docs/api_schema.json` 是否被改动；如果改动了说明 Rust 改了 schema 但没同步 docs，**直接 fail commit**。

| 入口 | 命令 |
|---|---|
| 自动 | `.pre-commit-config.yaml`（`prek install` 之后每次 commit 自动跑） |
| 手动 | `./scripts/check_schema_sync.sh` |

---

## 二、线上部署（serve 模式）

### `serve-restart.sh`

线上 Neo4j 服务器侧使用，一键"停旧 → nohup 启新 → 健康检查 → 报告退出码"。健壮性要点：
- pid 文件 + 端口占用进程双重 kill（兜底 lsof / ss / fuser）
- SIGTERM 10s 超时后强制 SIGKILL（可调 `SHUTDOWN_TIMEOUT_SEC`）
- 启动后 30s 内每秒重试 `/api/health`（可调 `HEALTH_TIMEOUT_SEC`）
- 新进程刚启就崩 → `tail -30` 日志 + 退出码 2
- 日志自动归档为 `*.log.YYYYMMDD-HHMMSS.bak`，不会无限增长

环境变量（全部可覆盖）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `BIN` | `./flowscope` | 二进制路径（服务器上一般就在工作目录） |
| `PORT` | `7681` | 监听端口 |
| `HOST` | `0.0.0.0` | 监听地址 |
| `WATCH_DIR` | `/tmp/sql` | `--watch` 监听目录 |
| `AUDIT_LOG` | `data/audit.db` | 审计日志 SQLite 路径 |
| `LOG_FILE` | `logs/flowscope-serve.log` | 进程日志 |
| `PID_FILE` | `logs/flowscope-serve.pid` | pid 文件 |
| `HEALTH_PATH` | `/api/health` | 健康检查路径 |
| `HEALTH_TIMEOUT_SEC` | `30` | 健康检查超时秒数 |
| `SHUTDOWN_TIMEOUT_SEC` | `10` | TERM → KILL 超时秒数 |

退出码：

| 码 | 含义 |
|---|---|
| 0 | 重启成功 |
| 1 | 前置检查失败（二进制不存在/不可执行） |
| 2 | 新进程启动后立刻崩了 |
| 3 | 健康检查超时未通过 |

```bash
./scripts/serve-restart.sh                     # 用默认参数重启
PORT=8080 ./scripts/serve-restart.sh           # 覆盖端口
AUDIT_LOG=/data/audit.db ./scripts/serve-restart.sh
```

### `serve-stop.sh`

线上停服。pid 文件 + 端口占用 双重 kill，**幂等**（已停止时返回 0）。

```bash
./scripts/serve-stop.sh         # 默认 PORT=7681
PORT=8080 ./scripts/serve-stop.sh
```

---

## 三、发布 & 上传

### `upload-h5.sh`

把任意文件上传到 `https://upload.zhenguanyu.com/upfile`，返回 CDN URL，并**下载远端副本对比 sha256**（不一致直接 `exit 1`）。

- 原本只给 H5 前端 zip 用，现已扩展到任意文件（CLI 二进制、tar、原始 binary 都行）。
- 默认上限 200MB（覆盖当前 ~72MB 的 flowscope binary），需要更大用 `UPLOAD_MAX_MB=500`。
- 不带参数时自动选 repo 根目录最新的 `flowscope-h5-*.zip`。

| 入口 | 命令 |
|---|---|
| 自动 | `just upload-h5 [FILE]` / `build-and-upload.md` Step 6 |
| 手动 | `./scripts/upload-h5.sh path/to/file` |

完整发布流程参考 [`docs/release-workflow.md`](../docs/release-workflow.md) 和 [`.cursor/commands/build-and-upload.md`](../.cursor/commands/build-and-upload.md)。

---

## 四、质量回归

### `regression-test-sql.py`

跑 release CLI 把 `test-sql/` 下每个 SQL 跑一遍，验证：
- CLI 返回 0 + 输出合法 JSON
- `issues` 无 error（warning 容忍但会报告）
- `statements` 至少 1 个（防止 SET/USE 等被全部过滤后留空）
- 若 `test-sql/.regression-expect.json` 钉了字段（`sqlType`/`insertType`/`targetTable`/`sourceTables`/`statementTypes`/`errorCount`），做严格 match

新 fixture 拖进 `test-sql/` 即自动入套件（无 expect 时只跑软检查）。

| 入口 | 命令 |
|---|---|
| 自动 | `just regression-sql` (会先 build-cli) / `just regression-sql-fast`（跳 build） |
| 手动 | `python3 ./scripts/regression-test-sql.py [--bin ...] [--dialect hive]` |

### `sqlfluff-parity-report.py`

读 SQLFluff 源码里的 `test/fixtures/rules/std_rule_cases/*.yml`，对每个 case：
- `pass_str` → 验证 FlowScope **不**报该规则
- `fail_str` → 验证 FlowScope **报**该规则
- `fix_str` → 对比 FlowScope `--fix` 输出与期望

| 入口 | 命令 |
|---|---|
| 自动 | `just sqlfluff-parity /path/to/sqlfluff` |
| 手动 | `python3 scripts/sqlfluff-parity-report.py /path/to/sqlfluff` |

> 依赖 SQLFluff 源码 checkout 的 `.venv/bin/python`（含 PyYAML）。

### `sql-corpus-parity-report.py`

在**真实 SQL 语料**上同时跑 FlowScope 和 SQLFluff，输出：
- 总违规数 before/after 对比
- 每条规则 before/after 增量
- 各规则的 parity gap（SQLFluff 修了多少 vs FlowScope 修了多少）
- FlowScope 的 fix 遥测（applied / skipped / blocked 候选分布）
- SQLFluff 的 fixability 摘要

| 入口 | 命令 |
|---|---|
| 自动 | `just sql-corpus-parity /path/to/sql-dir /path/to/sqlfluff` |
| 手动 | `python3 scripts/sql-corpus-parity-report.py --sql-dir ... --sqlfluff-bin ... --dialect postgres` |

### `lt02-indent-parity-workbench.py`

LT02 缩进规则**专项**对比 workbench（`sql-corpus-parity-report.py` 的窄版）：
- LT02 only 模式跑两侧
- 报告 LT02 修复前后计数 / parity gap / fix 遥测
- 列出 FlowScope 修复后残留的 LT02 issue 分组
- 输出 per-file / per-line 与 SQLFluff 的分歧

| 入口 | 命令 |
|---|---|
| 自动 | `just lt02-corpus-parity /path/to/sql-dir /path/to/sqlfluff [DIALECT] [JSON_OUTPUT]` |
| 手动 | `python3 scripts/lt02-indent-parity-workbench.py --sql-dir ... --sqlfluff-bin ... --dialect postgres` |

### `sql-corpus-fix-benchmark.py`

在 SQL 语料上 benchmark FlowScope 的 fix 性能。**默认 batch 模式**（一次性 CLI 调用覆盖整个目录，避免 per-file 进程开销，匹配真实使用场景）。

| 入口 | 命令 |
|---|---|
| 自动 | `.github/workflows/ci.yml`（CI 跑） |
| 手动 | `python3 scripts/sql-corpus-fix-benchmark.py --sql-dir ... [--mode batch|per-file]` |

---

## 五、一次性业务工具

### `xlsx_to_schema.py`

把客户/上游给的 Excel 元数据文件（列：`SCHEMA` / `TABLE_NAME` / `COLUMN_NAME` / 可选 `DATA_TYPE`）转成 FlowScope 用的 `SchemaMetadata` JSON。

**没有自动入口**，需要时手动跑：

```bash
pip install openpyxl
python scripts/xlsx_to_schema.py metadata.xlsx -o oracle_schema.json
python scripts/xlsx_to_schema.py metadata.xlsx --upper   # 强制列名大写
```

> 此脚本一个月没人调用过，但属于业务工具不是开发冗余，**保留**。如果将来一直不用了再删。

---

## 六、加新脚本的约定

1. **文件名**：日常 = `kebab-case`，Python 偶有 `snake_case` 历史遗留可保留
2. **shebang**：bash → `#!/usr/bin/env bash` + `set -euo pipefail`；Python → `#!/usr/bin/env python3`
3. **可执行权限**：`chmod +x` 之后再 `git add`
4. **cwd**：脚本顶部 `cd "$(dirname "$0")/.."` 确保从仓库根目录运行
5. **自动入口**：除非真的一次性，否则在 `justfile` 加一行 wrapper
6. **README**：在本文件对应章节加一段（用途 / 入口 / 关键参数 / 退出码）
7. **CI 引用**：如果被 `.github/workflows/ci.yml` 引用，README 标明"CI 跑"

---

## 七、变更记录

| 日期 | 变更 | 原因 |
|---|---|---|
| 2026-05-22 | 创建本 README | 全量梳理 12 个脚本，标明用途/入口/引用方，避免再次出现"误删后查不到"的事故 |
| 2026-05-22 | 恢复 `serve-restart.sh` / `serve-stop.sh` | 之前未 commit 被误删，从 agent transcript 完整恢复 |
