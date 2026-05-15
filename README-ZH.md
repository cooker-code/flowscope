# FlowScope 中文使用说明

> 本文档说明 FlowScope 本地开发环境的两种启动方式、各自的能力边界和适用场景。

---

## ⚡ 标准开发工作流（重点）

```
改代码 → 在 3000 验证 → 满意后 embed → 3099 同步更新
```

**第一步：开发阶段，只看 `localhost:3000`**

```bash
# 终端 1：CLI serve 在后台提供 /api/* 和审计日志
./target/release/flowscope --serve --port 3099 --dialect hive --audit-log ./data/audit.db

# 终端 2：Vite dev server，前端改动立刻生效
cd app && yarn dev
# 浏览器打开 http://localhost:3000
```

> 开发期间所有验证都在 `3000` 上做，`3099` 只是后端。**不要去看 `3099` 的页面，它是旧快照。**

**第二步：验证满意后，执行一次 embed**

```bash
cd app && yarn build
cargo build -p flowscope-cli --features serve --release
```

**第三步：重启 CLI serve，3099 页面同步更新**

```bash
./target/release/flowscope --serve --port 3099 --dialect hive --audit-log ./data/audit.db
# 此时 http://localhost:3099 和 http://localhost:3000 显示同一版本
```

> **何时需要 embed？** 只要前端代码有改动（`app/src/` 下任何文件），就需要重新 embed 一次。纯 Rust 改动不需要。

---

## 两种启动模式

FlowScope 有两种运行模式，**相互独立，可以同时启动，也可以单独启动**。

### 模式一：WASM 模式（Vite dev server）

Vite dev server 本身**没有分析能力**，它只是一个前端开发服务器。分析引擎运行在浏览器内的 WebAssembly 里。

- 当 CLI serve **未启动**时：Vite 的 `/api/*` 代理请求失败，UI 自动降级为 WASM 模式
- 当 CLI serve **已启动**时：Vite 将 `/api/*` 代理到 3099，UI 切换为 REST 模式（有审计日志）

```
Vite dev (3000)  ──/api/*──代理──>  CLI serve (3099)
                                          ↓
                                     audit.db（写日志）
```

### 模式二：CLI Serve 模式

使用本地编译的 Rust binary 提供 HTTP 服务，对外暴露 `/api/analyze`、`/api/audit` 等接口，同时可内嵌前端页面（需提前 embed）。这是历史上有审计日志的方式，真实端口 **3099**。

---

## 两种模式详细对比

| 维度 | WASM 模式 | CLI Serve 模式 |
|------|----------|---------------|
| 分析引擎 | 浏览器内 WebAssembly | 本地 Rust binary |
| 审计日志 | ❌ 无 | ✅ SQLite（需传 `--audit-log`） |
| `dialect` | 每个项目独立配置 | 全局固定（CLI 启动参数） |
| `schema` | 每个项目 SchemaEditor 独立写 DDL | 全局固定（CLI 启动参数 `--schema`） |
| 多项目切换 | ✅（项目数据存浏览器 localStorage） | ✅（同上） |
| JSON 分析结果来源 | WASM 引擎输出 | `/api/analyze` 直接返回 |
| 前端热更新 | ✅ 改代码立刻生效 | ✅ 改前端代码生效；但需重新 embed 才能更新 binary 内嵌页面 |
| 适合场景 | 前端开发调试 | 完整功能验证、生产部署、审计需求 |

---

## 三种使用场景

| 场景 | 启动什么 | 访问方式 |
|------|---------|---------|
| 纯 API 调用（脚本/自动化） | 只起 CLI serve | `curl http://localhost:3099/api/...` |
| 完整 UI + 审计日志 | CLI serve + Vite dev | 浏览器 `http://localhost:3000`（Vite 代理 /api/* 到 3099） |
| 纯前端开发（无审计） | 只起 Vite dev | 浏览器 `http://localhost:3000`（3099 不在，自动 WASM 降级） |

> **常见疑问：为什么上面两个场景都是 3000，而不是 3099？**
>
> 用户**永远只访问 3000**（Vite dev server），3099 是否在运行只影响后端分析引擎和审计日志，不影响前端访问入口。
>
> - `localhost:3000` — Vite dev server，实时读取 `app/src/` 源码，前端改动立刻生效
> - `localhost:3099` — CLI serve binary，前端是**编译时 embed 进去的快照**，不会自动更新
>
> 所以现在直接访问 `localhost:3099` 看到的是旧版前端（没有 Quick Analyze、JSON Tab 等新功能），要让它和 3000 一致需要重新 embed（见下方"生产模式"命令）。

---

## 启动命令

### ① 只启动 WASM 模式

```bash
cd app && yarn dev
# 浏览器打开 http://localhost:3000
```

### ② 只启动 CLI serve（纯 API，无前端）

```bash
./target/release/flowscope \
  --serve \
  --port 3099 \
  --dialect hive \
  --audit-log ./data/audit.db

# API 可直接使用：
curl -s http://localhost:3099/api/health
```

### ③ 完整模式：CLI serve + Vite dev（推荐开发调试）

```bash
# 终端 1：起 CLI serve（带审计日志）
./target/release/flowscope \
  --serve \
  --port 3099 \
  --dialect hive \
  --audit-log ./data/audit.db

# 终端 2：起 Vite dev（/api/* 自动代理到 3099）
cd app && yarn dev
# 浏览器打开 http://localhost:3000
```

### ④ 生产模式：前端打包内嵌进 binary（UI + API 一体）

> 每次前端有改动，都需要重新执行这两步。

```bash
# Step 1：把前端打包进 binary
cd app && yarn build
cargo build -p flowscope-cli --features serve --release

# Step 2：启动（UI + API 一体，直接访问 3099）
./target/release/flowscope \
  --serve \
  --port 3099 \
  --dialect hive \
  --audit-log ./data/audit.db
# 浏览器打开 http://localhost:3099
```

---

## 常用 API 命令（CLI serve 启动后）

```bash
# 健康检查
curl -s http://localhost:3099/api/health

# 分析 SQL（inline）
curl -s -X POST http://localhost:3099/api/analyze \
  -H 'Content-Type: application/json' \
  -d '{"files":[{"name":"test.sql","content":"SELECT a.id FROM orders a JOIN users b ON a.user_id = b.id"}]}' \
  | python3 -m json.tool

# 分析本地 SQL 文件
curl -s -X POST http://localhost:3099/api/analyze \
  -H 'Content-Type: application/json' \
  -d "{\"files\":[{\"name\":\"test.sql\",\"content\":$(cat test-sql/dwd_conan_user_order_da.sql | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}]}" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print(json.dumps(r['summary'], indent=2, ensure_ascii=False))"

# 查审计日志列表
curl -s http://localhost:3099/api/audit | python3 -m json.tool

# 查单条审计详情（含完整 sql_text + result_json）
curl -s http://localhost:3099/api/audit/1 | python3 -m json.tool
```

---

## 注意事项

- `./data/audit.db` 路径可以自定义，不传 `--audit-log` 则不写审计日志
- CLI serve 的 `--dialect` 是全局的，影响所有 `/api/analyze` 请求；WASM 模式下 dialect 每个项目独立
- debug binary（`target/debug/flowscope`）**不包含** serve 功能，必须用 `target/release/flowscope`
- 前端改动后，若只用 Vite dev + CLI serve 组合，不需要重新编译 binary；若用生产一体模式则需要重新 embed
