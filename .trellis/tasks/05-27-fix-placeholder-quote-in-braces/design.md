# Design: fix placeholder scanner quote-inside-braces

## Fix

Add a `brace_depth` counter to `substitute_placeholders`. Before checking for string
quotes, check whether we are currently inside a `{{...}}` placeholder. If yes, skip
the quote check and continue accumulating into `pending`.

```rust
fn substitute_placeholders(input: &str) -> String {
    let bytes = input.as_bytes();
    let n = bytes.len();
    let mut out = String::with_capacity(n);
    let mut pending = String::new();
    let mut i = 0;
    let mut brace_depth: u32 = 0;  // ← new: tracks {{ / {{{ nesting

    while i < n {
        let ch = bytes[i];

        // ── line comment ──────────────────────────────────────────────────────
        if ch == b'-' && i + 1 < n && bytes[i + 1] == b'-' && brace_depth == 0 {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            let end = input[i..].find('\n').map(|p| i + p).unwrap_or(n);
            out.push_str(&input[i..end]);
            i = end;
            continue;
        }

        // ── block comment ─────────────────────────────────────────────────────
        if ch == b'/' && i + 1 < n && bytes[i + 1] == b'*' && brace_depth == 0 {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            let end = input[i + 2..].find("*/").map(|p| i + 2 + p + 2).unwrap_or(n);
            out.push_str(&input[i..end]);
            i = end;
            continue;
        }

        // ── update brace depth ────────────────────────────────────────────────
        if ch == b'{' {
            // entering a {{ or {{{ — just track, accumulate into pending
            brace_depth += 1;
        } else if ch == b'}' && brace_depth > 0 {
            brace_depth -= 1;
        }

        // ── string literal — only when NOT inside {{ }} ───────────────────────
        if (ch == b'\'' || ch == b'"') && brace_depth == 0 {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            // ... existing string-handling logic unchanged ...
        }

        pending.push(ch as char);
        i += 1;
    }
    flush_pending_with_bare_regex(&mut out, &mut pending);
    out
}
```

**Why `brace_depth` works:**
- `{{other['taskid'] as taskid}}`: when scanner hits `'`, `brace_depth == 2` → skip
  string mode → keep accumulating → full `{{other['taskid'] as taskid}}` lands in
  `pending` → regex replaces it.
- Normal SQL string `WHERE name = 'foo'`: `brace_depth == 0` → existing logic unchanged.
- Line/block comments: guard `brace_depth == 0` prevents treating `--` / `/*` inside
  a placeholder as a comment (edge case, unlikely in practice but correct).

## Scope of Change

| File | Change |
|------|--------|
| `crates/flowscope-core/src/hive_preprocess.rs` | Add `brace_depth` counter; guard string-quote branch on `brace_depth == 0`; guard comment branches similarly |
| same | Add unit tests for quote-inside-braces patterns |

## Risk

Low — purely additive state in a well-tested function. Existing tests cover the normal
string-literal path; new tests cover the new guard.
