# 技术设计 — Bug 2 inline 多列 AS 解构语法

## 核心原则

**按语法形态识别，不按函数名白名单。**

`<IDENT>(<args>) AS (<col_list>)` 中的关键语法特征是 **AS 后紧跟 `(`**。
任何函数（已知 UDTF / 用户自定义 UDTF / 任意标识符）出现这种语法，就是 Hive
inline 多列别名解构语法的合法形态。函数名是什么不影响识别。

## 推荐方案：新增 Step 4.5

在现有 Step 4 (`rewrite_transform_using`) 与 Step 5 (`rewrite_array_index`)
之间插入新 step：

### 函数名 & 接入点

```rust
// crates/flowscope-core/src/hive_preprocess.rs::preprocess
fn preprocess(input: &str) -> String {
    ...
    let s = rewrite_transform_using(&s);           // Step 4
    let s = rewrite_inline_multi_col_as(&s);       // ← Step 4.5（新增）
    let s = rewrite_array_index(&s);               // Step 5
    ...
}
```

### 识别正则

```rust
fn inline_multi_col_as_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*\((?:[^()]|\([^()]*\))*\)\s+AS\s*\(\s*([\w][\w\s,]*?)\s*\)"
        ).unwrap()
    })
}
```

| 段 | 模式 | 含义 |
|----|------|-----|
| `\b([A-Za-z_][A-Za-z0-9_]*)` | 函数名（捕获 group 1，可用于调试日志，**不用于过滤**） |
| `\s*\(` | 函数调用 open paren |
| `(?:[^()]|\([^()]*\))*` | 函数参数体（允许 1 级括号嵌套，覆盖 `SPLIT('__ph__', ',')` 这种） |
| `\)` | 函数调用 close paren |
| `\s+AS\s*` | `AS` 关键字（前后必须有空白，确保是关键字而非标识符片段） |
| `\(\s*([\w][\w\s,]*?)\s*\)` | `(col_list)`：以 `(` 开始，捕获 col_list（group 2），以 `)` 结束 |

> 函数参数嵌套深度限制为 1 级。`POSEXPLODE(SPLIT('__ph__', ','))` 是 1 级；
> 如果未来 corpus 出现 `POSEXPLODE(SPLIT(CONCAT(...), ','))` 这种 2 级嵌套
> 同样会失败 — 届时按 Bug 1 类似手段升级为字符级括号计数。本任务不预判。

### 改写规则

正则命中后，用 `replace_all` + closure 拆 `col_list`，输出：

```rust
fn rewrite_inline_multi_col_as(input: &str) -> String {
    inline_multi_col_as_re().replace_all(input, |caps: &regex::Captures| {
        let col_list = &caps[2];
        col_list
            .split(',')
            .map(|c| format!("NULL AS {}", c.trim()))
            .collect::<Vec<_>>()
            .join(", ")
    }).into_owned()
}
```

### 改写示例

| 输入 | 输出 |
|------|------|
| `POSEXPLODE(SPLIT('__ph__', ',')) AS (pos, hw_val)` | `NULL AS pos, NULL AS hw_val` |
| `EXPLODE(arr) AS (val)` | `NULL AS val` |
| `my_custom_udtf(a, b) AS (x, y, z)` | `NULL AS x, NULL AS y, NULL AS z` |
| `my_udf(x) AS y`（防误伤 — 不命中正则） | 原样 `my_udf(x) AS y` |
| `cast(x AS bigint) AS y`（防误伤） | 原样 `cast(x AS bigint) AS y` |

### 误伤边界分析

| 表达式 | 是否命中 | 原因 |
|--------|--------|-----|
| `my_udf(x) AS y` | ✗ | `AS y` 后无 `(` |
| `cast(x AS bigint) AS y` | ✗ | 外层 `AS y` 后是标识符，不是 `(` |
| `cast(x AS bigint) AS (y)` | ✓（误伤）→ 改写为 `NULL AS y` | 这种写法是非法 Hive，正常不会出现；如生产 corpus 出现按"语法异常 SQL"处理 |
| `LATERAL VIEW POSEXPLODE(x) t AS pos, val` | ✗ | 中间有标识符 `t`，正则要求 `)` 与 `AS` 之间只有 `\s+`（空白），不允许其它标识符 |
| `LATERAL VIEW POSEXPLODE(x) AS (pos, val)` | ✓（少见，非标 Hive） → 改写为 `NULL AS pos, NULL AS val` | 等于剥掉 LATERAL VIEW 的别名子句，结构上仍可解析；这种写法 sqlparser 也不支持，本任务的改写让它能 parse |
| `from (select 1) t(c)` | ✗ | 子查询前是 `)` 不是函数标识符；正则 `\b([A-Za-z_]...)` 要求字母/下划线开头 |
| 字符串内 `'POSEXPLODE(x) AS (a)'` | ✗（应不命中） | regex 不感知字符串边界 — 但 Step 1 之后字符串内不该再出现真实 UDTF 调用文本；如果生产 SQL 真的在字符串内放这种文本，会被错误改写 |

**字符串内误伤**这一项是已知风险。缓解措施：

- 实际 corpus 中字符串内放 SQL 文本极罕见
- 若发现，把正则升级为字符级扫描（同 Bug 1 思路），但成本较高 → 本任务**暂不处理**
- 在 spec / design 中明确列出限制

### 函数名捕获 group 的用途

`caps[1]` 是函数名（如 `POSEXPLODE` / `my_custom_udtf`）。本任务**不**用它做
任何过滤判断（避免回到白名单思路），但保留捕获便于：

- 未来 debug：日志中打印"改写了哪个函数"
- 未来在 spec 文档中可以统计 corpus 命中的 UDTF 分布

可选 implement 决策：是否在 closure 内 push 一条 `tracing::debug!` 日志记录
命中的函数名。**默认不加**，避免噪音；如 implement 阶段感到需要再加。

## 备选方案

### 备选 A：UDTF 白名单（原方案，已否决）

- **缺点**：维护负担（每个新 UDTF 都要改代码）；覆盖不到用户自定义 UDTF；
  违反"按语法识别"原则
- **否决理由**：已被用户反馈明确否决

### 备选 B：改写为 LATERAL VIEW

`SELECT POSEXPLODE(x) AS (a, b) FROM t` → `SELECT a, b FROM t LATERAL VIEW POSEXPLODE(x) v AS a, b`

- **优点**：语义保真
- **缺点**：要识别整个 SELECT 子句的边界（FROM 在哪？子查询？UNION？），
  实现复杂度爆炸；本质上是把 SQL parser 工作做了一遍
- **否决理由**：复杂度收益不成比例，`NULL AS col` 已经足够保留下游列引用解析能力

### 备选 C：只剥 `AS (col_list)` 外括号取最后一个别名

`POSEXPLODE(x) AS (pos, val)` → `POSEXPLODE(x) AS val`

- **缺点**：丢弃 `pos` 别名，下游 `t.pos` 引用报"unknown column"，破坏血缘骨架
- **否决理由**：违反"保留所有别名"的硬性要求

## 风险

| 风险 | 严重度 | 缓解 |
|------|-------|-----|
| 字符串内出现 UDTF 字面文本被误改写 | 低 | 已在 design 中标注；spec 注明"已知限制"；未来按需升级字符级 |
| col_list 内含空白 / 复杂 trim 边界（如 `(  a  ,  b  )`） | 低 | closure 内 `c.trim()` 保证；写测试覆盖空白边界 |
| 函数参数嵌套深度 > 1 命中失败 | 中 | 与 Bug 1 同类问题；本任务保持 1 级，后续按需升级 |
| 与 Step 5 (`rewrite_array_index`) 协同：被改写为 `NULL AS hw_val` 后下游 `hw.hw_val[0]` 之类的引用 | 低 | Step 5 在 Step 4.5 之后跑，正常剥 `[0]`；最终形态 `NULL AS hw_val` + `hw.hw_val` 引用合法 |

## 兼容性 & rollback

- 纯 additive 新增 Step 4.5
- 单文件单 commit，git revert 一步回退（删 step + 删 helper + 删测试 = 1 个 revert）
- 不影响 `analyze()` 接口
- 不影响其他 step 的输入/输出契约

## 文档同步（由父任务收口）

`hive-compat-preprocess.md` 在 Step 4 段后插入 Step 4.5 段：

- 标题：**Step 4.5 — Inline 多列 AS 解构语法改写**
- 触发条件：`<IDENT>(<args>) AS (<col_list>)`，按 **语法** 不按白名单
- 改写规则：`NULL AS <c1>, NULL AS <c2>, ...`
- 不变性：scalar UDF / 内嵌 AS（cast）/ LATERAL VIEW / 子查询别名都不受影响
- 已知限制：字符串内含 UDTF 字面文本会被误改写（罕见，暂不处理）

`hive_preprocess.rs` 模块顶部 `//! ## Pipeline (in order)` 注释新增：

```
//! - Step 4.5: Inline multi-col AS destructuring (`<func>(...) AS (c1, c2, ...)` → `NULL AS c1, NULL AS c2, ...`)
```
