# Neo4j 服务器编译部署 SOP

> **适用场景**：在本机（Apple Silicon Mac）交叉编译 `flowscope-cli --features serve`，产物部署到 Neo4j 生产机（CentOS 7 / glibc 2.17 / 阿里内网）。
>
> **核心约束**：服务器是离线/受限网络 + 老 glibc（2.17）+ 老 GCC（4.8.5），**不能在服务器上编译**。
>
> **唯一可行方案**：本机用 `cargo-zigbuild` 交叉编译，目标 glibc 2.17 + 静态链接 libstdc++，产物拷到服务器直接跑。

---

## 一、为什么必须这么编（背景）

历史上尝试过的失败路径，请勿走回头路：

| 方案 | 失败原因 |
|---|---|
| 服务器直接 `cargo build` | DuckDB 是 C++，CentOS 7 的 GCC 4.8.5 不支持 `_u""` user-defined literal 语法 |
| 服务器升级 GCC（devtoolset） | 只能升 libstdc++，**升不动 glibc**（系统级，跟内核绑定） |
| 本机 `cross build` 默认镜像 | cross 默认基底是 Ubuntu 22.04 → glibc 2.35，编出二进制要求 ≥ 2.30，服务器 2.17 跑不了 |
| `LD_LIBRARY_PATH` 黑魔法 | `ld-linux` 系统强绑，不可换 |
| musl 静态链接 | DuckDB C++ 项目 musl 兼容性差，多半编不过 |

**`cargo-zigbuild` 是当前唯一稳定方案**，因为 zig 自带 glibc headers 可以精确指定目标版本，并且能把 libstdc++ 静态打包。

---

## 二、一次性环境准备（本机 Mac，只做一次）

```bash
brew install zig

cargo install cargo-zigbuild

rustup target add x86_64-unknown-linux-gnu
```

验证：

```bash
zig version           # 期望 ≥ 0.13
cargo-zigbuild --version
rustup target list --installed | grep x86_64-unknown-linux-gnu
```

---

## 三、编译命令（本机执行）

```bash
cd /Users/blank/wangliang/gitcode/flowscope

cargo zigbuild \
  --target x86_64-unknown-linux-gnu.2.17 \
  --target-dir target-zigbuild \
  -p flowscope-cli \
  --features serve \
  --release
```

**关键参数说明**：

| 参数 | 说明 | 改它意味着什么 |
|---|---|---|
| `--target x86_64-unknown-linux-gnu.2.17` | 目标架构 + 锁定 glibc 2.17 | 改高了服务器跑不了；改低意义不大 |
| `--target-dir target-zigbuild` | 独立产物目录，与默认 `target/` 隔离 | 避免和本机调试产物相互污染 |
| `-p flowscope-cli` | 只编 CLI 一个包 | 不带会顺带编 workspace 其它 crate，浪费时间 |
| `--features serve` | 启用 HTTP serve + 嵌入前端 | 不带就没 `--serve` 子命令 |
| `--release` | 优化构建 | debug 模式跑起来慢且体积大，生产部署必须 release |

### 编译耗时参考

| 情况 | 耗时 |
|---|---|
| 首次（含 DuckDB C++ 编译） | **~5 min** |
| 增量（只改 Rust 代码） | 30s ~ 2 min |
| 改了 DuckDB / 大 C++ 依赖 | 3 ~ 5 min |

### 产物路径

```
target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope
```

约 **72 MB**（stripped）。

---

## 四、产物验证（本机执行，建议每次都做）

```bash
file target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope
```

必须包含：

```
ELF 64-bit LSB pie executable, x86-64, ..., for GNU/Linux 2.0.0, stripped
```

```bash
strings target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope \
  | grep -E '^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$' \
  | sort -V -u \
  | tail -3
```

必须只显示 **≤ 2.17** 的版本（典型最高就是 `GLIBC_2.17`）。如果出现 `GLIBC_2.18+` 就说明编译环境出问题，服务器跑不了。

```bash
strings target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope \
  | grep -E '^GLIBCXX_' | head -1
```

**应该为空**——表示 libstdc++ 已经静态链接进二进制，对服务器系统库无依赖。

---

## 五、部署到服务器

### 1. scp 二进制

```bash
scp target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope \
  maintain@alibjh-op-neo4j1-vm:~/wangliang/flowscope-main/
```

### 2. 服务器准备目录 + 启动

```bash
ssh maintain@alibjh-op-neo4j1-vm

cd ~/wangliang/flowscope-main
chmod +x flowscope

./flowscope --version

mkdir -p data /tmp/sql
```

### 3. tmux 后台启动（推荐）

```bash
tmux new -s flowscope

./flowscope --serve \
  --watch /tmp/sql \
  --host 0.0.0.0 \
  --port 7681 \
  --audit-log data/audit.db
```

按 `Ctrl+b` 然后按 `d` 跳出（进程继续后台跑）。

回到会话：

```bash
tmux attach -t flowscope
```

### 4. 验证 API

```bash
curl http://localhost:7681/api/health
```

### 5. 停服

```bash
tmux attach -t flowscope
# Ctrl+C
exit

# 或一行
tmux kill-session -t flowscope
```

---

## 六、启动参数清单

| 参数 | 必填 | 说明 |
|---|---|---|
| `--serve` | ✅ | 进入 HTTP 服务模式 |
| `--port 7681` | ✅ | 监听端口 |
| `--host 0.0.0.0` | 建议 | 允许内网其它机器访问；本机自测可省略 |
| `--audit-log data/audit.db` | **MANDATORY** | 审计日志路径。**不带会导致审计功能不可用**（见 `CLAUDE.md`） |
| `--watch /tmp/sql` | 可选 | 监听目录变更自动重分析 SQL；不需要可省 |

---

## 七、常见问题排查

### Q1：服务器报 `GLIBC_2.18 not found`

回到第四章重新验证产物。一般是没用 `cargo zigbuild`、误用了 `cargo build` 或 `cross build` 导致。

### Q2：服务器报 `embedded-app` 缺失

**这是编译阶段的错误，不会在服务器上出现**。如果出现说明二进制本身就是坏的，本机重新编。

本机编译前必须确认存在：

```bash
ls crates/flowscope-cli/embedded-app/index.html
```

如果不存在：

```bash
just sync-cli-serve-assets
```

### Q3：本机 zig 编译报 `cc1plus: error: unknown C++ flag`

zig 版本太老（< 0.11）。`brew upgrade zig` 升到 0.13+。

### Q4：编出的二进制体积突然变大很多

检查是否误带了 debug 符号。重跑时确认 `--release` 在命令里。

### Q5：服务器内网访问不到 7681

```bash
ss -tlnp | grep 7681
```

确认启动时带了 `--host 0.0.0.0`（不是默认的 `127.0.0.1`）。还要看公司内网防火墙是否放行了这个端口。

---

## 八、一键脚本（可选）

把下面这段保存到 `scripts/build-for-neo4j.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo ">>> [1/4] 确保 embedded-app 就绪"
if [ ! -f crates/flowscope-cli/embedded-app/index.html ]; then
  just sync-cli-serve-assets
fi

echo ">>> [2/4] cargo zigbuild (glibc 2.17, release)"
cargo zigbuild \
  --target x86_64-unknown-linux-gnu.2.17 \
  --target-dir target-zigbuild \
  -p flowscope-cli \
  --features serve \
  --release

BIN="target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope"

echo ">>> [3/4] 验证产物"
file "$BIN"
echo "GLIBC 符号最高版本："
strings "$BIN" | grep -E '^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V -u | tail -1

echo ">>> [4/4] 完成。产物: $BIN ($(du -h "$BIN" | cut -f1))"
echo ">>> 拷贝命令: scp $BIN maintain@alibjh-op-neo4j1-vm:~/wangliang/flowscope-main/"
```

赋权后直接执行：

```bash
chmod +x scripts/build-for-neo4j.sh
./scripts/build-for-neo4j.sh
```

---

## 九、版本变更记录

| 日期 | 变更 | 触发原因 |
|---|---|---|
| 2026-05-19 | 初版，确立 cargo-zigbuild 方案 | cross 默认镜像基底太新（Ubuntu 22.04），编出二进制要求 glibc ≥ 2.30，CentOS 7（2.17）跑不了 |

---

## 十、相关文档

- 本仓库 `AGENTS.md` § Build Commands —— 本机开发构建命令
- 本仓库 `CLAUDE.md` § 审计服务关键约定 —— `--audit-log` 必须携带的原因
- 本仓库 `crates/flowscope-cli/build.rs` —— `embedded-app` 检查逻辑
- 本仓库 `justfile` § `sync-cli-serve-assets` —— 前端资产同步流程
