# PRD: 修复 6 个 Hive SQL 复杂语法解析失败

## 目标

定位并修复 `auditId ∈ {2479, 2482, 2497, 2550, 2568, 2571}` 共 6 条 SQL 解析失败的根因，分门别类提交 PR。

## 最终归类（已全部最小复现验证）

用户决定：只修 flowscope 引擎、按根因分组（每个根因 1 个 PR）。SQL 写错类（id=2550 CTE 缺 as）略过。

### 3 个根因 → 3 个 PR

| PR# | 根因 | 影响 auditId | 最小复现 | 修复方案 |
|-----|------|--------------|----------|----------|
| PR1 | **STRUCT 命名字段 AS**：`STRUCT(a AS w, b AS l)` Spark/Hive 语法 | 2479, 2482, 2571 | `SELECT STRUCT(a AS w) FROM t` → FAIL | 新增 `sanitize_hive_struct_named_fields()`：剥离 `AS xxx`，保留位置 |
| PR2 | **DIV 整除运算符**：sqlparser MySQL 方言支持但 Hive 方言不支持 | 2568 | `SELECT x DIV 1000 FROM t` → FAIL | 新增 `sanitize_hive_div_operator()`：`a DIV b` → `CAST(a/b AS BIGINT)` |
| PR3 | **INSERT 带外层括号的 SELECT**：`INSERT ... PARTITION (...) (SELECT ...)` | 2497 | `INSERT ... PARTITION(dt='x') (SELECT ...)` → FAIL | 新增 `sanitize_hive_parenthesized_insert_select()`：去掉 SELECT 外层括号 |

### 略过项

| auditId | 原因 |
|---------|------|
| 2550 | 用户 SQL bug：CTE `account_info_tencent (SELECT...)` 缺 `as` 关键字，是 SQL 真错误，引擎层不应纵容 |

## 实现规范

- 修改文件：`crates/flowscope-core/src/parser/mod.rs`
- 注册触发条件：`dialect == Dialect::Hive` 且关键字预检测命中
- 接入位置：`parse_sql_with_dialect_output()` 的 fallback 链路
- 每个 PR 必须包含：
  - 单元测试（覆盖正例 + 反例）
  - 最小失败 SQL 加入 `tests/fixtures/` 作回归保护
  - PR 描述：含失败 SQL 最小复现 + 修复前后对比

## 验收标准

1. 每个 PR 独立通过 `just test-core`
2. 合并 3 个 PR 后，对 6 条失败 SQL 重跑 `flowscope-cli` 至少 5 条变 `success=1`
3. 不引入对 931 个文件中其它 SQL 的回归（重跑 `batch_parse_sql_final.py` 失败数 ≤ 1）
