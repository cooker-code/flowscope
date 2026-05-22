# 执行计划 — Bug 3 字符串内嵌占位符

> **修订（v3）**：v1 6 个 embedded regex 被反证（跨字符串吞噬），v2 两阶段
> 字符级 + bare regex 也被反证（Phase 2 bare regex 不感知注释，注释体被误替换）。
> v3 改用单次字符级扫描，三种上下文统一处理；bare regex 也搬进扫描器内部
> （只在 code 段上跑），实现闭环。详见 design.md。

## 实施步骤

### Step 1 — 基线快照

```bash
just regression-sql-fast 2>&1 | rg "30907"
cargo test -p flowscope-core --lib hive_preprocess::tests -- --nocapture
```

### Step 2 — 删除已废弃的 regex helpers（如尚未删）

文件：`crates/flowscope-core/src/hive_preprocess.rs`

确认以下已删除（v2 已完成，此处确认）：

- v1 加的 6 个 `ph_re_*_embedded` helpers
- 原有 6 个 quoted `ph_re_*_sq` / `ph_re_*_dq` helpers

**保留**三个 bare regex helper（无修改）：

- `ph_re_triple_bare`
- `ph_re_double_bare`
- `ph_re_dollar_bare`

### Step 3 — 删除 v2 的 `rewrite_string_literals_with_placeholders`

如果 v2 实现里有 `rewrite_string_literals_with_placeholders` 这个独立函数，
**删除它**。v3 把它的逻辑直接合入 `substitute_placeholders` 主循环。

### Step 4 — 新增 `flush_pending_with_bare_regex` helper

```rust
/// Apply the three bare-form placeholder regexes to a pending **code-only**
/// buffer accumulated by `substitute_placeholders`, then append to `out` and
/// clear the buffer. Triple must run before double (`{{{x}}}` would otherwise
/// be misread as `{{x}}` plus stray `{`/`}`).
fn flush_pending_with_bare_regex(out: &mut String, pending: &mut String) {
    if pending.is_empty() {
        return;
    }
    let s = ph_re_triple_bare().replace_all(pending, "'__ph__'");
    let s = ph_re_double_bare().replace_all(&s, "'__ph__'");
    let s = ph_re_dollar_bare().replace_all(&s, "'__ph__'");
    out.push_str(&s);
    pending.clear();
}
```

### Step 5 — 改写 `substitute_placeholders` 为单次扫描器

完整覆盖 design.md 中的总流程代码：

```rust
/// `{{{var}}}` / `{{var}}` / `${var}` → `'__ph__'`.
///
/// Single-pass character-level scan over three contexts:
///   - line comments (`-- ... \n`)            → kept verbatim
///   - block comments (`/* ... */`)           → kept verbatim
///   - string literals (`'...'` / `"..."`)    → if body contains any placeholder marker,
///                                              the entire literal (quotes included) →
///                                              `'__ph__'`; otherwise kept verbatim
///   - code text (everything else)            → accumulated into a pending buffer,
///                                              flushed with the three bare-form regexes
///                                              when entering a comment/string segment
///                                              or when the scan finishes
///
/// Design rationale and prior failed approaches (v1 regex-only, v2 two-phase) are
/// recorded in `.trellis/tasks/05-22-fix-hive-string-embedded-placeholder/design.md`.
fn substitute_placeholders(input: &str) -> String {
    let bytes = input.as_bytes();
    let n = bytes.len();
    let mut out = String::with_capacity(n);
    let mut pending = String::new();
    let mut i = 0;
    while i < n {
        let ch = bytes[i];

        // line comment
        if ch == b'-' && i + 1 < n && bytes[i + 1] == b'-' {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            let end = input[i..].find('\n').map(|p| i + p).unwrap_or(n);
            out.push_str(&input[i..end]);
            i = end;
            continue;
        }

        // block comment
        if ch == b'/' && i + 1 < n && bytes[i + 1] == b'*' {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            let end = input[i + 2..].find("*/").map(|p| i + 2 + p + 2).unwrap_or(n);
            out.push_str(&input[i..end]);
            i = end;
            continue;
        }

        // string literal
        if ch == b'\'' || ch == b'"' {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            let quote = ch;
            let start = i;
            let mut j = i + 1;
            while j < n {
                if bytes[j] == b'\\' && j + 1 < n {
                    j += 2;
                    continue;
                }
                if bytes[j] == quote {
                    break;
                }
                j += 1;
            }
            if j < n {
                let body = &input[start + 1..j];
                if body.contains("{{{") || body.contains("{{") || body.contains("${") {
                    out.push_str("'__ph__'");
                } else {
                    out.push_str(&input[start..=j]);
                }
                i = j + 1;
            } else {
                out.push_str(&input[start..]);
                break;
            }
            continue;
        }

        // code text
        pending.push(ch as char);
        i += 1;
    }
    flush_pending_with_bare_regex(&mut out, &mut pending);
    out
}
```

### Step 6 — 单测（v2 保留 + 1 个 v3 新增）

保留 v2 已加的 8 个 placeholder 测试（断言不变）。在末尾追加 1 个 v3 专项
负例（注释体内含字符串字面量也应保留）：

```rust
#[test]
fn placeholder_in_block_comment_not_replaced() {
    // 块注释体内的占位符 string-literal 同样被跳过
    let input = "select 1 /* '${a}' inside block */ from t";
    let out = substitute_placeholders(input);
    assert_eq!(out, input);
}
```

### Step 7 — 校验

```bash
cargo test -p flowscope-core --lib hive_preprocess::tests::placeholder
cargo test -p flowscope-core --lib hive_preprocess          # 全部单测含 placeholders_all_forms
just regression-sql-fast 2>&1 | rg "30907"
just fmt-rust && just lint-rust
```

**Gate**（v3 最终验收）：
- 8 个 v2 测试 + 1 个 v3 测试 = 9 个新增测试全绿
- 已有 `placeholders_all_forms`（count=6）不回归
- 已有 `placeholders_triple_before_double` 不回归
- 关键 v2 失败 case `placeholder_in_line_comment_not_replaced` 现在 PASS
- `30907.sql` `errors=0`
- 零 clippy 警告
- `cargo test -p flowscope-core --lib hive_preprocess` 全绿（无 failed）

## Risky Files

| 文件 | rollback 单位 |
|------|--------------|
| `crates/flowscope-core/src/hive_preprocess.rs` | 单 commit，git revert 一步回退 |

## Pre-`task.py start` Checklist

- [x] PRD 验收标准可量化
- [x] design v3 已经过两轮反证 → 闭环（单次扫描器内统一处理三种上下文）
- [x] v1 + v2 失败原因已沉淀到 design.md
- [x] 用户已签字进入 in_progress
