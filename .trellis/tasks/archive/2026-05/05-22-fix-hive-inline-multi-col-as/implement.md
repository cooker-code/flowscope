# 执行计划 — Bug 2 inline 多列 AS 解构语法

## 实施步骤

### Step 1 — 基线快照

```bash
just regression-sql-fast 2>&1 | rg "29209"
cargo test -p flowscope-core --lib hive_preprocess::tests -- --nocapture
```

### Step 2 — 新增 Step 4.5 实现

文件：`crates/flowscope-core/src/hive_preprocess.rs`

在 Step 4 (`rewrite_transform_using`) 之后、Step 5 (`rewrite_array_index`)
之前，新增段落：

```rust
// ─── Step 4.5: Inline multi-col AS destructuring ──────────────────────────────

/// Identify `<func>(<args>) AS (<col_list>)` and rewrite as `NULL AS <c1>, NULL AS <c2>, ...`.
///
/// Recognizes by **syntax shape only** — any `<IDENT>(...) AS (...)` triggers
/// the rewrite, regardless of the function name. This covers POSEXPLODE,
/// EXPLODE, INLINE, STACK, JSON_TUPLE, PARSE_URL_TUPLE and any user-defined
/// UDTF without maintaining a name allowlist.
///
/// Function arg list supports 1 level of nested parens (sufficient for
/// `SPLIT('__ph__', ',')` and similar). Deeper nesting falls through and
/// will fail downstream parsing — that's a known limitation, see Bug-1's
/// char-counting solution for the upgrade path.
fn inline_multi_col_as_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*\((?:[^()]|\([^()]*\))*\)\s+AS\s*\(\s*([\w][\w\s,]*?)\s*\)"
        ).unwrap()
    })
}

fn rewrite_inline_multi_col_as(input: &str) -> String {
    inline_multi_col_as_re()
        .replace_all(input, |caps: &regex::Captures| {
            let col_list = &caps[2];
            col_list
                .split(',')
                .map(|c| format!("NULL AS {}", c.trim()))
                .collect::<Vec<_>>()
                .join(", ")
        })
        .into_owned()
}
```

接入到 `preprocess()`：

```rust
let s = rewrite_transform_using(&s);
let s = rewrite_inline_multi_col_as(&s);    // ← 新增
let s = rewrite_array_index(&s);
```

### Step 3 — 更新模块顶部 `//! ## Pipeline (in order)` 注释

在 Step 4 行后插入 Step 4.5 行：

```rust
//! - Step 4:   `TRANSFORM USING 'script' [AS (cols)]` removal
//! - Step 4.5: Inline multi-col AS destructuring (`<func>(...) AS (c1, c2, ...)` → `NULL AS c1, NULL AS c2, ...`)
//! - Step 5:   Array/map index `arr[n]` / `func()[n]` / `map['k']` → drop subscript
```

### Step 4 — 单测

`mod tests` 追加：

```rust
// ── Step 4.5 ───────────────────────────────────────────────────────────────
#[test]
fn inline_multi_col_as_posexplode_two_col() {
    let s = "select POSEXPLODE(split('__ph__', ',')) as (pos, hw_val) from t";
    let out = rewrite_inline_multi_col_as(s);
    assert!(out.to_uppercase().contains("NULL AS POS"));
    assert!(out.to_uppercase().contains("NULL AS HW_VAL"));
    assert!(!out.to_lowercase().contains("posexplode"));
}

#[test]
fn inline_multi_col_as_explode_single_col_in_parens() {
    let s = "select EXPLODE(arr) as (val) from t";
    let out = rewrite_inline_multi_col_as(s);
    assert!(out.to_uppercase().contains("NULL AS VAL"));
}

#[test]
fn inline_multi_col_as_custom_udtf_no_whitelist() {
    // 关键测试：证明不依赖 UDTF 白名单，任意函数名都触发改写
    let s = "select my_custom_udtf(a, b) as (x, y, z) from t";
    let out = rewrite_inline_multi_col_as(s);
    assert!(out.to_uppercase().contains("NULL AS X"));
    assert!(out.to_uppercase().contains("NULL AS Y"));
    assert!(out.to_uppercase().contains("NULL AS Z"));
    assert!(!out.contains("my_custom_udtf"));
}

#[test]
fn inline_multi_col_as_scalar_function_with_single_alias_not_touched() {
    // 防误伤：普通 UDF AS y（AS 后非 `(`）不能被改写
    let s = "select my_udf(x) as y from t";
    let out = rewrite_inline_multi_col_as(s);
    assert_eq!(out, s);
}

#[test]
fn inline_multi_col_as_cast_with_inner_as_not_touched() {
    // 防误伤：cast 内嵌 AS，外层 AS 后是标识符不是 `(`
    let s = "select cast(x as bigint) as y from t";
    let out = rewrite_inline_multi_col_as(s);
    assert_eq!(out, s);
}

#[test]
fn inline_multi_col_as_lateral_view_form_not_touched() {
    // 防误伤：LATERAL VIEW 形态（`)` 与 `AS` 之间有 table_alias）
    let s = "lateral view posexplode(x) t as pos, val";
    let out = rewrite_inline_multi_col_as(s);
    assert_eq!(out, s);
}

#[test]
fn inline_multi_col_as_subquery_alias_not_touched() {
    // 防误伤：子查询别名 (select 1) t(c) — 函数标识符前是 `)` 不是字母
    let s = "from (select 1) t(c)";
    let out = rewrite_inline_multi_col_as(s);
    assert_eq!(out, s);
}

#[test]
fn inline_multi_col_as_handles_whitespace_in_col_list() {
    // col_list 内含多余空白也应正确 trim
    let s = "select foo(x) as (  a  ,  b  ,  c  ) from t";
    let out = rewrite_inline_multi_col_as(s);
    assert!(out.contains("NULL AS a"));
    assert!(out.contains("NULL AS b"));
    assert!(out.contains("NULL AS c"));
}
```

### Step 5 — 校验

```bash
cargo test -p flowscope-core --lib hive_preprocess::tests::inline_multi_col_as
cargo test -p flowscope-core --lib hive_preprocess     # 全部 step 单测
just regression-sql-fast 2>&1 | rg "29209"             # 必须 errors=0
just fmt-rust && just lint-rust
```

**Gate**：
- 29209 误报消失
- `transform_using_removed` / `array_index_dropped` / `full_pipeline_smoke` 不回退
- 零 clippy 警告

### Step 6 — corpus 抽检（可选）

如果本地有 hive corpus 目录：

```bash
FLOWSCOPE_HIVE_CORPUS_DIR=test-sql cargo test -p flowscope-core --test hive_corpus -- --nocapture
```

观察通过率是否上升（应至少不下降）。**非强制**，无 corpus 时跳过。

## Risky Files

| 文件 | rollback 单位 |
|------|--------------|
| `crates/flowscope-core/src/hive_preprocess.rs` | 单 commit，git revert 一步回退 |

## Pre-`task.py start` Checklist

- [ ] PRD 验收标准可量化
- [ ] design 已确认采用「按语法不按白名单」原则，不引入函数名列表
- [ ] 误伤边界分析已经过设计评审（特别是 LATERAL VIEW / cast / 子查询别名）
- [ ] 用户已签字进入 in_progress
