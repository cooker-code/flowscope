# Hive 兼容预处理（dialect=hive 时自动启用）

> 适用于：`crates/flowscope-core/src/hive_preprocess.rs`
> 入口：`flowscope_core::analyze()`，当 `request.dialect == Dialect::Hive` 时
> 自动对 `request.sql` 及所有 `files[].content` 应用本管道。
>
> 这是 `flowscope-core` 内部行为。任何调 `analyze()` 的客户端
> （`/api/analyze`、wasm、`flowscope-cli`、`flowscope-react`、VS Code 扩展、
> 任何 Rust 二级消费者）在 `dialect=hive` 时全部自动受益。

### Schema DDL loading is a separate input contract

`flowscope-cli::schema::load_schema_from_ddl(path, Dialect::Hive)` parses schema
files directly with native `HiveDialect`, outside the workload preprocessing
pipeline. Do not feed schema DDL through `analyze()`'s CREATE-removal step or
switch it to Generic merely to retain the statements.

- Preserve declared ordinary columns, then append partition columns in declared
  order, without duplicate names. Source-table partition fields must remain
  available for validation. INSERT mapping excludes static partitions separately.
- sqlparser 0.61's external-table branch lacks table-level COMMENT parsing.
  Only after native parsing fails, remove one syntactically complete table-level
  `COMMENT '...'` following the external table's column list, then retry Hive.
  All partition/storage/location/properties clauses still go through the parser.
- Malformed comments or unsupported suffixes remain errors. Do not truncate the
  entire DDL after the column list. Column comments and quoted properties must
  not be mistaken for structural delimiters.
- Schema tests cover ordinary/external tables, quoted names, column order,
  partition columns, multiple tables, no trailing semicolon and invalid suffixes.
  Real SQL acceptance must use original schema input and verify output mappings,
  not just absence of parse errors.

---

## 为什么需要预处理？

`sqlparser-rs` 的 `HiveDialect`（被 `FlowscopeHiveDialect` 包装）
是一个**严格 parser**，无法直接接收真实生产 Hive SQL 中常见的：

- 非 SQL 的引擎指令（`SET hive.exec.parallel=true`、`ADD FILE foo.py`）
- 模板占位符（`${date}`、`{{var}}`、`{{{var}}}`）
- Hive 方言特殊语法（双引号字符串、`arr[n]`、`! IN`、`TRANSFORM USING`、`GROUPING SETS`）
- 生产中容忍的 typo（`END AS\nFROM`、CTE 漏 AS、IN list 多行漏逗号）

直接 parse 会失败率 ~30%。本管道把这些"hive-isms"在 parse 之前归一化掉，
parse 通过率提升到 **99.96%+**（warehouse corpus 5105 文件实测 100% — 见
`crates/flowscope-core/tests/hive_corpus.rs`）。

---

## 历史教训：不要再用 Python 兜底

**反模式**（已删除）：曾把同样的 13 步预处理写在
`scripts/batch-parse-warehouse.py` 里，让批处理脚本跑出 100% 通过率，
但 `/api/analyze` 调用方根本走不到这套预处理。

> 教训：**任何应当被所有客户端受益的"修复"，必须放在 core/cli 的代码路径里，
> 而不是某个外部工具脚本里。** 否则就是把测试指标修好看了、生产体验没改。

---

## 管道（13 步，按序执行）

### Step 1 — 模板占位符替换

`${var}` / `{{var}}` / `{{{var}}}` → `'__ph__'`。

**关键顺序**：三重 → 双重 → 单 `$`。反过来会让 `{{{x}}}` 变成 `'__ph__'}`，多漏一个 `}` 破坏后续 SQL。

**实现要求：单次字符级扫描器统一处理三种上下文**（与 Step 6 / Step 12.5 同形）：

- 行注释 `-- ... \n` / 块注释 `/* ... */`：整段保留，**不替换**注释里的占位符
- 字符串字面量 `'...'` / `"..."`：body 含 `{{{` / `{{` / `${` 任一 marker 即整段替换为
  `'__ph__'`；否则保留原文
- 其余 code 段：累积到 pending buffer，进入注释/字符串前 + 扫描结束时通过三个 bare-regex
  （triple → double → dollar 顺序）一次性替换

**为什么不能用纯 regex 链**：regex 无法区分字符串边界（`[^']*` 不知道哪个 `'` 是闭合
引号），多次"修复"会形如 `'%{{{x}}}%'` → `'%'__ph__'%'`，破坏字符串边界让 parser
错位到任意位置。完整 v1（6 个 embedded regex 跨字符串吞噬）+ v2（字符级 + bare regex
两阶段，Phase 2 不感知注释）失败记录见
`.trellis/tasks/archive/2026-05/05-22-fix-hive-string-embedded-placeholder/design.md`。

### Step 2 — 行级 Hive 指令过滤

匹配并清空（保持行号）：

| 模式 | 例子 |
|------|------|
| `set <key>=<val>` | `set hive.exec.parallel=true;` |
| `add file/jar/archive <path>` | `add file script.py;` |

### Step 3 — 语句级 DDL 过滤

按 `;` 切语句，整段丢弃以下（跳过 leading `-- 注释`）：

- `CREATE [EXTERNAL|TEMPORARY] TABLE ...`
- `ALTER TABLE ...`
- `DROP TABLE ...`
- `CREATE TEMPORARY MACRO ...`
- 多行 SET（`set\n  key=val;`，被行级过滤漏掉的）

### Step 4 — TRANSFORM USING 'script' [AS (cols)] 整体移除

Hive `TRANSFORM(...) USING 'python s.py' AS (x, y)` 是脚本调用，parser 无法理解。
正则一并匹配 `USING 'string'` 加可选的 `AS (col_list)`，整段删除。

### Step 4.5 — 内联多列 AS 解构改写

Hive UDTF 内联形态 `<func>(<args>) AS (c1, c2, ...)`（如
`POSEXPLODE(split(s, ',')) AS (pos, val)`、`JSON_TUPLE(j, 'a', 'b') AS (a, b)`、
任意自定义 UDTF）parser 不支持。改写为 `NULL AS c1, NULL AS c2, ...` 占位，**保留每个
列别名**（下游 `t.<col>` 引用仍可解析）。

**识别规则：按语法形态识别，不依赖函数名白名单**。任意 `\b<IDENT>\s*\(<args>\)\s+AS\s*\(<col_list>\)`
形态都改写。关键边界是 `AS` 紧跟 `(` —— 这是 Hive 表函数内联多列别名的唯一无歧义标记，
普通 UDF 单别名（`f(x) as y`）/ `cast(x AS bigint) as y` / `LATERAL VIEW posexplode(x) t as a, b`
形态都不会落入此模式。

**arg 列表支持 1 级嵌套**（足够 `split('__ph__', ',')`）。更深嵌套（极少见）走 fallthrough；
未来如出现真实 corpus hit，采用上下文感知的字符级括号计数。

### Step 5 — 数组/Map 下标去除

`arr[0]` / `split(x, '-')[1]` / `map['k']` / `map["k"]` → 保留左侧表达式，去掉 `[...]`。

血缘提取不依赖具体下标，安全去除。

### Step 6 — 双引号字符串字面量 → 单引号

Hive 把 `"..."` 当作字符串字面量，但 `sqlparser-rs` 默认把双引号当作标识符引用。

**实现要求：上下文感知字符级扫描**，必须跳过：

- 单引号字符串里的 `"`（如 `'^(.*?)"'` 这种正则模式里偶现的双引号）
- 行注释 `--` 里的 `"`
- 块注释 `/* */` 里的 `"`

否则会把单引号字符串内偶现的 `"` 误认为双引号串起点，吞掉大段代码。
内部出现 `'` 替换成 `_` 以避免与外层单引号冲突。

### Step 7 — 单引号字符串内反斜杠转义剥离

Hive 字符串里 `\X` 是 C 风格转义，`sqlparser-rs` 把 `\'` 当转义、不当字符串结尾，
触发假 `Unterminated string literal`。把 `\X` 还原为 `X`，`\'` / `\"` 替换为 `_`。

### Step 8 — IN list 多行字符串字面量补逗号

Hive 容错 `IN ('a'\n  'b'\n  'c')`（漏写逗号 → 隐式字符串拼接）。
parser 直接报 `Expected: )`。在相邻字符串字面量之间插入 `,`。
循环到收敛，覆盖三个以上字面量的场景。

### Step 9 — CTE 漏写 `AS` 自动补

Hive 容忍 `WITH a AS (...), b\n(select ...)`（第二个 CTE 漏 AS）。
正则匹配 `,\s*\w+\s*\n\s*\(\s*select` 时插入 `AS`。

注：第一个 CTE 漏 AS 不在覆盖范围（生产里没见过这种写法）。

### Step 10 — 折叠 `;;;;` 和前导分号

Step 3 把 DDL 替换为空字符串后用 `;` 重新拼接，会产生 `;;;`。
本步把连续多个 `;` 折叠为一个 `;\n`，并去掉文件最前面的分号噪音。

### Step 11 — 顶层 SELECT/INSERT/WITH 漏分号自动补

启发式：当 `paren_depth == 0` 且行首是 `select|insert|with` 时（**排除
`WITH CUBE` / `WITH ROLLUP` / `WITH TOTALS`** — 它们是 GROUP BY 扩展不是 CTE 头），
往前找最近的非空非注释行，如果它**明显结束**（`LIMIT n`、`ORDER BY ...`、
`... ASC/DESC`、`HAVING ...`、`GROUP BY ...`）且**不是连接残段**（`,` / `(` /
`AS` / `JOIN` / `UNION` / `ON` / `AND` / `OR` / `CASE` 等），就在它末尾补 `;`。

**关键防误伤**：

- `WITH ... INSERT ...` 多行语句不切（`)` 结尾不算明显结束）
- `GROUP BY a WITH CUBE` 不切（`WITH CUBE` 不算新语句头）

### Step 12 — `! IN (...)` → `NOT IN (...)`

Hive 接受 `expr ! IN (a, b)` 作为 NOT IN 的别写。

### Step 12.5 — 孤立 `AS` 后无别名 → 删 AS

原作者 typo：`case ... end as\nfrom (...)`（AS 后没有别名，下一个 token
直接是子句关键字）。Hive 在某些版本容忍，parser 不容忍。

**实现要求**：上下文感知扫描，跳过注释和字符串中的 `as`，**只**在以下子句
关键字（FROM/WHERE/GROUP/ORDER/HAVING/LIMIT/UNION/JOIN/LEFT/RIGHT/INNER/
CROSS/ON/WHEN/ELSE/END/AND/OR/THEN）之前删除 AS。删除时只删 AS 两字节，
保留前后空白以最小化 line/column 偏移。

**回归用例**：

- `-- ,count(*) as \nfrom t` → **保留**（注释里的 AS）
- `select sum(x) as sum from t` → **保留**（`sum` 不是子句关键字）
- `case when ... end as\nfrom (...)` → 删 AS ✓

### 原 Step 13 已移除：高级分组必须保留正式结构

禁止将 `GROUP BY GROUPING SETS (...)` 改成 `GROUP BY 1`。旧实现既删除了
分组键和小计空集，也只吞掉第一个集合，破坏后续并列集合。`FlowscopeHiveDialect`
启用 `supports_group_by_expr()`，由上游构造 `GroupingSets` / `Cube` / `Rollup` AST。

- 并列集合保持多个节点，空集保持空数组；不展开笛卡尔积，不删除重复集合。
- 分组字段用于聚合粒度分析，不得混入 `SUM(amount)` 等指标的值来源。
- 高级分组在结果关系节点的 `metadata.groupBy` 有序数组中保留结构；各项包含
  `kind: expressions`、有序 `expressions`、`modifiers`。集合表达式为
  `{kind: groupingSets|cube|rollup, sets: [[表达式文本], []]}`。
- 同一关系的 UNION 分支不能互相覆盖分组结构；周/日分支须同时保留。
- 普通 SELECT、普通 GROUP BY 不附加该元数据。

### 现有 Hive 入口的 Spark 语法兼容

不新增服务、HTTP 请求字段或 Spark 方言枚举。兼容位于正式 Core 的 Hive 入口，
`sql` 和 `files[].content` 均应受益，不能要求调用方修改原 SQL。

- `supports_values_as_table_factor()` 接收裸 `FROM VALUES`，使用正式派生表 AST。
  具名列由关系别名的列清单提供；每列逐行保留原表达式文本到该虚拟列的
  `metadata.columnValues`，包括重复值和类型化 NULL。常量列没有 Physical 来源。
  行宽或别名宽度不一致必须显式拒绝，不能填 NULL、截断或只用首行。
- 数组 `exists(array, x -> predicate)` 与子查询 `EXISTS` 在方言前缀解析处分支。
  `NOT exists(...)` 也保留正式 `UnaryOp(Not)` + 函数/Lambda AST；不能改写私有
  函数名或替换成子查询。正常 `EXISTS/NOT EXISTS (SELECT/WITH/VALUES/嵌套查询)`
  保持原有子查询解析。Lambda 局部变量及成员不建物理来源，集合和外部捕获列保留。
- NULL 表达式保持原样，分析器不执行 Spark 求值，也不假定会话兼容参数。

回归 `hive_compat_original_sql.rs` 固定原审计 SQL 558128/557486/556525/
557826/557557/557500/557728，原文不在测试端清洗。断言 8 个 VALUES 的全行列、
别名和类型化 NULL；周/日分支各 368×2×2 分组；物理值根；真实目标 DDL 下的
INSERT 位置和动态分区后缀。DDL 于 2026-10-30 从 hive_f04 点查冻结，schema.json
从独立 DDL AST 提取，不从工作负载的 SELECT 别名猜目标列。
HTTP `serve_api` 用相同 7 份原文且不传 dialect，比较完整结果与共享 Core 一致。
这些是解析/血缘表示验收，不代替实际 Spark 的业务数据结果核对。

无 Schema 的 `SELECT *` 反向推导必须在本轮修改任何节点前，快照全部 target
已有列，并以稳定顺序遍历；不能把本轮刚猜出的列反馈给另一 target。作用域中的
关系实例也须稳定排序。`PendingWildcard` 创建时记录精确 `target_node_id`，
顶层快照、递归查找和循环检测均使用真实节点 ID（循环键含 source 实例 ID）；
不能按同名 derived alias 反查、更不能按哈希最小值任选或合并自连接实例。
`wildcard_determinism.rs` 覆盖重复推导稳定性与显式多层星号链不断裂。

本轮 HTTP 原文回归启用临时审计。接口完整响应与审计存储是不同边界：现有
审计 `result_json` 上限仍为 1 MiB，超限保留 `result_truncated=true`；557486 的
完整结果约 2.9 MB，不能把其截断审计当完整可回放图。截断必须退回 UTF-8 字符
边界，不能因中文常量跨字节边界使请求 panic；不改变既有审计容量或请求合同。


---

## 已知设计权衡

### Span 偏移

预处理会改变 SQL 长度，`statements[].span.start/end` 指向**预处理后**的
坐标系，不等于原始用户输入的字节位置。错误消息的 line/column 可能跟原文
偏移几个字符到几行。

- 当前阶段**接受这个偏移**
- 后续 backlog：offset map 反向映射
- **偏移的接受不能推导为所有表达式或字段血缘无损，必须按原 SQL 回归验证**

### 字符串字面值失真

Step 6（双引号→单引号）、Step 7（反斜杠剥离）改变了字符串内容。AST 里的
literal value 不再等于原文。但血缘 / table / column / JOIN 关系正确。

---

## 接入位置

```rust
// crates/flowscope-core/src/analyzer.rs
pub fn analyze(request: &AnalyzeRequest) -> AnalyzeResult {
    if request.dialect == Dialect::Hive {
        let preprocessed = preprocess_hive_request(request);
        if hive_request_is_empty(&preprocessed) {
            // 整个文件全是 SET/ADD/DDL，预处理后为空 → 空成功结果
            return AnalyzeResult::default();
        }
        return Analyzer::new(&preprocessed).analyze();
    }
    Analyzer::new(request).analyze()
}
```

---

## 测试

### 单元测试

`crates/flowscope-core/src/hive_preprocess.rs` 的 `#[cfg(test)] mod tests`
覆盖了每个 step 的正例 + 关键防误伤负例：

- placeholders_triple_before_double / placeholder_triple_embedded_in_single_quoted /
  placeholder_in_line_comment_not_replaced / placeholder_in_block_comment_not_replaced
- ddl_stmt_filter_handles_leading_comments / multiline_set
- double_quote_skips_inside_single_quoted_string / line_comment
- inline_multi_col_as_posexplode_two_col / inline_multi_col_as_custom_udtf_no_whitelist /
  inline_multi_col_as_cast_with_inner_as_not_touched /
  inline_multi_col_as_lateral_view_form_not_touched
- auto_split_does_not_break_with_insert / with_cube
- orphan_as_preserves_legitimate_alias / skips_inside_comment
- 高级分组原文保留、空集/并列集合、数组 exists/NOT exists 和正常子查询分支
- full_pipeline_smoke

`cargo test -p flowscope-core --lib hive_preprocess::tests`

### Corpus 回归测试

`crates/flowscope-core/tests/hive_corpus.rs`：环境变量
`FLOWSCOPE_HIVE_CORPUS_DIR` 驱动，遍历目录下所有 `.sql` 文件，**直接调
`flowscope_core::analyze`**（不经任何外部工具），按通过率阈值断言。

```bash
FLOWSCOPE_HIVE_CORPUS_DIR=/path/to/warehouse \
    cargo test -p flowscope-core --test hive_corpus -- --nocapture
```

未设置环境变量时 no-op，CI 友好。

阈值默认 99.9%，可通过 `FLOWSCOPE_HIVE_CORPUS_PASS_THRESHOLD` 调整。

### Acceptance Methodology（验收方式）

1. 全 corpus 跑通过率 → 必须 ≥99.9%
2. 失败列表按 `issues[0].message` 桶聚类
3. 每个桶选 1 个样本最小复现：
   - **预处理漏洞** → 加 step 单测 + 实现
   - **parser 限制但可改写** → 加 step（如本管道 6-13）
   - **真 SQL 书写错误** → 列入"不修"清单并如实暴露
4. 加新 step 后全量重跑，确认无回归（已通过的不能掉）
5. 每条新 step 至少一组正例 + 一组防误伤负例
