# 执行计划 — Bug 1 GROUPING SETS 多级嵌套

## 实施步骤

### Step 1 — 基线快照

```bash
just regression-sql-fast 2>&1 | rg "29463"
cargo test -p flowscope-core --lib hive_preprocess::tests::grouping_sets -- --nocapture
```

### Step 2 — 决定字符串/注释跳过 helper 复用策略

阅读 `rewrite_double_quote_strings`（Step 6）与 `fix_orphan_as`（Step 12.5）的字符
扫描代码：

- 如果已有可复用的私有函数（如 `find_substr`、`find_byte`），直接复用
- 否则在 Step 13 段内私有定义 `skip_single_quoted_string` / `skip_line_comment` /
  `skip_block_comment` 三个小 helper（不抽公共模块，避免增大维护表面）

> 取舍标准：如果 Step 13 字符跳过总代码 ≤ 30 行，私有定义即可；
> 超过则考虑抽到 `hive_preprocess.rs` 文件级私有 helper（不导出）。

### Step 3 — 重写 `rewrite_grouping_sets`

文件：`crates/flowscope-core/src/hive_preprocess.rs`

- 删除现 `grouping_sets_re()` 内的复杂括号匹配模式
- 新增 `grouping_sets_head_re()`：只匹配头部 `group\s+by\s+grouping\s+sets\s*\(`
- 新增 `find_matching_paren(bytes: &[u8], open_idx: usize) -> Option<usize>`
- 重写 `rewrite_grouping_sets` 主循环（按 design 中的伪代码）
- 保留函数签名 `fn rewrite_grouping_sets(input: &str) -> String`，对外行为兼容

### Step 4 — 单测

`mod tests` 追加：

```rust
#[test]
fn grouping_sets_two_level_nested() {
    // 内含函数调用，构成 2 级嵌套
    let s = "select a from t group by grouping sets ((date_sub(x,1), b), (b), (date_sub(x,1)))";
    let out = rewrite_grouping_sets(s);
    assert!(!out.to_lowercase().contains("grouping sets"));
    assert!(out.contains("GROUP BY 1"));
}

#[test]
fn grouping_sets_three_level_nested() {
    let s = "select a from t group by grouping sets ((coalesce(f(g(x)), 1), b))";
    let out = rewrite_grouping_sets(s);
    assert!(!out.to_lowercase().contains("grouping sets"));
    assert!(out.contains("GROUP BY 1"));
}

#[test]
fn grouping_sets_simple_one_level_still_works() {
    // 防回归
    let s = "select a from t group by grouping sets ((a, b), (a))";
    let out = rewrite_grouping_sets(s);
    assert!(out.contains("GROUP BY 1"));
}

#[test]
fn grouping_sets_inside_string_literal_not_touched() {
    // 防误伤：字符串里出现 grouping sets 字面值
    let s = "select 'group by grouping sets (a)' from t";
    let out = rewrite_grouping_sets(s);
    assert_eq!(out, s);
}

#[test]
fn grouping_sets_multiple_occurrences_in_one_sql() {
    let s = "select 1 from t group by grouping sets ((a,(b))) ; \
             select 2 from u group by grouping sets ((c,(d)))";
    let out = rewrite_grouping_sets(s);
    assert_eq!(out.matches("GROUP BY 1").count(), 2);
    assert!(!out.to_lowercase().contains("grouping sets"));
}

#[test]
fn grouping_sets_inside_line_comment_not_touched() {
    let s = "select 1 -- group by grouping sets (a)\nfrom t";
    let out = rewrite_grouping_sets(s);
    assert_eq!(out, s);
}

#[test]
fn grouping_sets_unbalanced_paren_keeps_input() {
    // 保守降级：括号不平衡 → 不替换
    let s = "select 1 from t group by grouping sets ((a, b)";   // 缺一个 `)`
    let out = rewrite_grouping_sets(s);
    assert!(out.to_lowercase().contains("grouping sets"));   // 原文保留
}
```

### Step 5 — 校验

```bash
cargo test -p flowscope-core --lib hive_preprocess::tests::grouping_sets
cargo test -p flowscope-core --lib hive_preprocess
just regression-sql-fast 2>&1 | rg "29463"   # 必须 errors=0
just fmt-rust && just lint-rust
```

**Gate**：29463 误报消失；现有 `grouping_sets_*` 与 `full_pipeline_smoke` 单测全绿；零 clippy 警告。

## Risky Files

| 文件 | rollback 单位 |
|------|--------------|
| `crates/flowscope-core/src/hive_preprocess.rs` | 单 commit，git revert 一步回退 |

## Pre-`task.py start` Checklist

- [ ] PRD 验收标准可量化
- [ ] design 选型已确认（字符级计数为主，2 级 regex 仅作降级备选）
- [ ] 字符串/注释跳过 helper 的复用 vs 新增决定已经过 Step 2 评估
- [ ] 用户已签字进入 in_progress
