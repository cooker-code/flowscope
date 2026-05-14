# PRD: 把 Hive 预处理从 Python 脚本移植到 flowscope-core

## 背景：前一任务的方向跑偏

前置任务 `05-14-fix-hive-sql-parse-errors` 把 13 步预处理写在了
`scripts/batch-parse-warehouse.py`，让批处理脚本调 API 时跑出
**5105/5105 = 100%** 的"通过率"。

但这只是 **Python 脚本侧的伪通过**：

```
[ 真实用户 / VS Code / Web UI ]            [ Python 批处理脚本 ]
            │                                       │
            ▼ 原始 SQL                              ▼ 原始 SQL
   POST /api/analyze                       Python 13 步预处理
            │                                       │
            ▼                                       ▼ 已被改写的 SQL
   flowscope_core::analyze()              POST /api/analyze
                                                    │
                                                    ▼
                                          flowscope_core::analyze()
```

真实用户调 API 时**完全走不到 Python 预处理**。Hive SQL 通过率仍然差，
而 spec 文件路径 `.trellis/spec/flowscope-cli/backend/hive-sql-preprocessing.md`
名实不符——它不在 cli backend 里，它在 Python 脚本里。

## 本任务目标

**把 13 步预处理全部从 Python 移植到 `flowscope-core`**，作为
`Dialect::Hive` 路径的内置预处理 pipeline。让任何 API / wasm /
任何下游调 `flowscope_core::analyze` 的客户端自动受益。

完工后：

- ❌ `scripts/batch-parse-warehouse.py` 删除（不留任何 SQL 改写逻辑）
- ✅ Rust corpus 集成测试遍历 warehouse，**直接调 `analyze()` 跑通**
- ✅ spec 文件迁移到 `.trellis/spec/flowscope-core/backend/hive-compat-preprocess.md`，名实相符

## 范围划分

所有 13 步全部在 core，dialect=hive 时启用、其他 dialect 不动。
不在 cli 层做（cli 层零改动）。

| Step | 内容 | 类型 |
|------|------|------|
| 1 | 占位符 `${}` / `{{}}` / `{{{}}}` → `'__ph__'` | 通用模板（hive only） |
| 2 | 行级过滤 `SET key=val` / `ADD FILE/JAR/ARCHIVE` | 非 SQL 指令 |
| 3 | 语句级 DDL 过滤（CREATE/ALTER/DROP TABLE, MACRO, 多行 SET） | 非 SQL 指令 |
| 4 | `TRANSFORM USING 'script' [AS (cols)]` 整体移除 | 方言语法 |
| 5 | `arr[n]` / `func()[n]` / `map['k']` 下标去除 | 方言语法 |
| 6 | 双引号字符串 `"..."` → `'...'`（上下文感知扫描） | 方言语法 |
| 7 | 单引号字符串内 `\X` 转义剥离 | 方言语法 |
| 8 | IN list 多行字符串字面量补逗号 | 方言宽松语法 |
| 9 | CTE 漏写 `AS` 自动补 | 方言宽松语法 |
| 10 | 折叠 `;;;;` 和前导分号 | 后处理清理 |
| 11 | 顶层 SELECT/INSERT/WITH 之间漏分号补 | 方言宽松语法 |
| 12 | `! IN (...)` → `NOT IN (...)` | 方言语法 |
| 12.5 | 孤立 `AS` 后无别名（`END AS\nFROM`）删 AS | 方言/生产兼容 |
| 13 | `GROUP BY GROUPING SETS/CUBE/ROLLUP` → `GROUP BY 1` | 方言扩展 |

## 已知设计权衡

- **Span 偏移**：预处理会改变 SQL 长度，`statements[].span.start/end`
  指向"预处理后 SQL"的坐标系，**不等于原始用户输入的字节位置**。
  错误消息的 line/column 可能跟原文偏移几个字符。
  - 当前阶段**接受这个偏移**，后续 backlog 上做 offset map 反向映射。
  - 血缘骨架（表/列/JOIN 关系）不受影响。
- **字符串字面值失真**：双引号→单引号、反斜杠剥离改变了字符串内部内容。
  AST 里的字符串字面值不等于原文。**血缘骨架不受影响**。

## 验收标准

1. `scripts/batch-parse-warehouse.py` 文件不存在
2. `crates/flowscope-core/src/hive_preprocess.rs` 存在，13 步全部移植
3. 每个 step 至少 1 个 Rust 单元测试（含正例 + 负例/防误伤）
4. `crates/flowscope-core/tests/hive_corpus.rs` 集成测试存在：
   - 通过环境变量 `FLOWSCOPE_HIVE_CORPUS_DIR` 指向 warehouse 目录
   - 未设置时跳过（不影响 CI）
   - 直接调 `flowscope_core::analyze` 不经 API
   - 遍历目录，断言通过率 ≥99.9%
5. spec 文件迁移到 `.trellis/spec/flowscope-core/backend/hive-compat-preprocess.md`
6. 旧 spec `.trellis/spec/flowscope-cli/backend/hive-sql-preprocessing.md` 删除
7. `just test-core` 全绿
8. `just lint-rust` 全绿
9. 走 `/trellis-break-loop` 把"Python 兜底反模式"沉淀到 spec
