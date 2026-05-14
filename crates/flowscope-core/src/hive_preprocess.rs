//! Hive SQL compatibility preprocessing pipeline.
//!
//! When `Dialect::Hive` is selected, the analyzer first normalizes raw Hive
//! SQL into a form that the underlying parser (sqlparser-rs with our
//! `FlowscopeHiveDialect`) can ingest. This module is the **single place**
//! where that normalization lives — previously the same 13-step pipeline lived
//! in an external Python batch script which meant real API callers got no
//! benefit. The script was deleted; see task PRD
//! `.trellis/tasks/05-14-port-hive-preprocess-to-core/prd.md` and spec
//! `.trellis/spec/flowscope-core/backend/hive-compat-preprocess.md` for the
//! full contract and rationale.
//!
//! ## Pipeline (in order)
//!
//! - Step 1:  Placeholder substitution: `${var}`, `{{var}}`, `{{{var}}}` → `'__ph__'`
//! - Step 2:  Line-level filter: `SET key=val`, `ADD FILE/JAR/ARCHIVE`
//! - Step 3:  Statement-level DDL filter: `CREATE/ALTER/DROP TABLE`, `CREATE TEMPORARY MACRO`, multi-line `SET`
//! - Step 4:  `TRANSFORM USING 'script' [AS (cols)]` removal
//! - Step 5:  Array/map index `arr[n]` / `func()[n]` / `map['k']` → drop subscript
//! - Step 6:  Double-quoted string literal `"..."` → `'...'` (context-aware)
//! - Step 7:  Backslash escape strip inside single-quoted strings
//! - Step 8:  Insert missing comma between adjacent string literals in `IN (...)`
//! - Step 9:  CTE missing `AS` auto-insert
//! - Step 10: Collapse `;;;;` and leading semicolons
//! - Step 11: Auto-insert `;` between adjacent top-level `SELECT`/`INSERT`/`WITH`
//! - Step 12: `expr ! IN (...)` → `expr NOT IN (...)`
//! - Step 12.5: Orphan `AS` followed by clause keyword (e.g. `END AS\nFROM`) → drop `AS`
//! - Step 13: `GROUP BY GROUPING SETS/CUBE/ROLLUP(...)` → `GROUP BY 1`
//!
//! ## Known limitations
//!
//! - Preprocessing changes the SQL length, so `statements[].span` is in the
//!   **preprocessed** coordinate system and may not match the original input
//!   byte-for-byte. Lineage skeleton (tables, columns, JOIN) is unaffected.
//! - Some string literal contents are rewritten (backslash escapes, double
//!   quotes); the structural lineage is still correct but exact literal
//!   values may differ from the source.

use regex::Regex;
use std::sync::OnceLock;

/// Run the full Hive-compatibility preprocessing pipeline.
///
/// Idempotent in the sense that running it twice on the same input is safe
/// (each step is itself idempotent or converges in a single pass).
#[must_use]
pub fn preprocess(input: &str) -> String {
    let s = substitute_placeholders(input);
    let s = filter_lines(&s);
    let s = filter_ddl_statements(&s);
    let s = rewrite_transform_using(&s);
    let s = rewrite_array_index(&s);
    let s = rewrite_double_quote_strings(&s);
    let s = strip_backslash_in_strings(&s);
    let s = add_missing_comma_between_strings(&s);
    let s = fix_cte_missing_as(&s);
    let s = collapse_semicolons(&s);
    let s = auto_split_statements(&s);
    let s = rewrite_hive_not_in(&s);
    let s = fix_orphan_as(&s);
    rewrite_grouping_sets(&s)
}

// ─── Step 1: Placeholder substitution ─────────────────────────────────────────

fn ph_re_triple_sq() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"'\{\{\{[^}]*\}\}\}'").unwrap())
}
fn ph_re_triple_dq() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r#""\{\{\{[^}]*\}\}\}""#).unwrap())
}
fn ph_re_triple_bare() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\{\{\{[^}]*\}\}\}").unwrap())
}
fn ph_re_double_sq() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"'\{\{[^}]*\}\}'").unwrap())
}
fn ph_re_double_dq() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r#""\{\{[^}]*\}\}""#).unwrap())
}
fn ph_re_double_bare() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\{\{[^}]*\}\}").unwrap())
}
fn ph_re_dollar_sq() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"'\$\{[^}]*\}'").unwrap())
}
fn ph_re_dollar_dq() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r#""\$\{[^}]*\}""#).unwrap())
}
fn ph_re_dollar_bare() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\$\{[^}]*\}").unwrap())
}

/// `{{{var}}}` / `{{var}}` / `${var}` → `'__ph__'`.
///
/// Triple-brace must be processed before double-brace, otherwise `{{{var}}}`
/// becomes `'__ph__'}` (a stray `}` leaks out and breaks downstream SQL).
fn substitute_placeholders(input: &str) -> String {
    let s = ph_re_triple_sq().replace_all(input, "'__ph__'");
    let s = ph_re_triple_dq().replace_all(&s, "'__ph__'");
    let s = ph_re_triple_bare().replace_all(&s, "'__ph__'");
    let s = ph_re_double_sq().replace_all(&s, "'__ph__'");
    let s = ph_re_double_dq().replace_all(&s, "'__ph__'");
    let s = ph_re_double_bare().replace_all(&s, "'__ph__'");
    let s = ph_re_dollar_sq().replace_all(&s, "'__ph__'");
    let s = ph_re_dollar_dq().replace_all(&s, "'__ph__'");
    let s = ph_re_dollar_bare().replace_all(&s, "'__ph__'");
    s.into_owned()
}

// ─── Step 2: Line-level filter ────────────────────────────────────────────────

fn skip_line_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?i)^\s*(set\s+[\w.]+\s*=|add\s+(file|jar|archive)\s+)").unwrap()
    })
}

/// Drop Hive engine directives (one-line `SET key=val`, `ADD FILE/JAR/ARCHIVE`).
/// Replaces matched lines with empty lines to preserve line numbering.
fn filter_lines(input: &str) -> String {
    let re = skip_line_re();
    let mut out = String::with_capacity(input.len());
    let mut first = true;
    for line in input.split('\n') {
        if !first {
            out.push('\n');
        }
        first = false;
        if !re.is_match(line) {
            out.push_str(line);
        }
    }
    out
}

// ─── Step 3: Statement-level DDL filter ───────────────────────────────────────

fn ddl_stmt_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        // `set\s` catches multi-line SET (`set\n  key=val;`) missed by line filter.
        Regex::new(concat!(
            r"(?i)^\s*(",
            r"CREATE\s+(EXTERNAL\s+|TEMPORARY\s+)?TABLE",
            r"|ALTER\s+TABLE",
            r"|DROP\s+TABLE",
            r"|CREATE\s+TEMPORARY\s+MACRO",
            r"|set\s",
            r")",
        ))
        .unwrap()
    })
}

fn skip_leading_comments(stmt: &str) -> &str {
    for (idx, line) in stmt.split_inclusive('\n').enumerate() {
        let stripped = line.trim();
        if !stripped.is_empty() && !stripped.starts_with("--") {
            let mut offset = 0;
            for (i, ln) in stmt.split_inclusive('\n').enumerate() {
                if i == idx {
                    break;
                }
                offset += ln.len();
            }
            return &stmt[offset..];
        }
    }
    ""
}

/// Split by `;`, drop DDL/MACRO/multi-line SET statements (replaced with empty).
fn filter_ddl_statements(input: &str) -> String {
    let re = ddl_stmt_re();
    let mut out = String::with_capacity(input.len());
    let mut first = true;
    for stmt in input.split(';') {
        if !first {
            out.push(';');
        }
        first = false;
        let effective = skip_leading_comments(stmt).trim_start();
        if re.is_match(effective) {
            // drop (insert empty)
        } else {
            out.push_str(stmt);
        }
    }
    out
}

// ─── Step 4: TRANSFORM USING 'script' [AS (cols)] removal ─────────────────────

fn transform_using_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?is)USING\s+'[^']*'(\s*AS\s*\(\s*[\w,\s]+\s*\))?").unwrap()
    })
}

fn rewrite_transform_using(input: &str) -> String {
    transform_using_re().replace_all(input, "").into_owned()
}

// ─── Step 5: Array/map index removal ──────────────────────────────────────────

fn array_index_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    // `identifier[n]` or `)[n]` or `[ 'key' ]` / `[ "key" ]`
    R.get_or_init(|| Regex::new(r#"(\w+|\))\[(\d+|'[^']*'|"[^"]*")\]"#).unwrap())
}

fn rewrite_array_index(input: &str) -> String {
    array_index_re().replace_all(input, "$1").into_owned()
}

// ─── Step 6: Double-quoted string literals → single-quoted ────────────────────

/// Context-aware rewrite of Hive's `"..."` string literals to `'...'`.
///
/// **Must** skip single-quoted strings and comments — a naive global regex
/// will mis-interpret a `"` *inside* a single-quoted regex (e.g. `'^(.*?)"'`)
/// as the start of a double-quoted string and swallow large chunks of code.
fn rewrite_double_quote_strings(input: &str) -> String {
    let bytes = input.as_bytes();
    let n = bytes.len();
    let mut out = String::with_capacity(n);
    let mut i = 0;
    while i < n {
        let ch = bytes[i];
        // line comment --
        if ch == b'-' && i + 1 < n && bytes[i + 1] == b'-' {
            if let Some(j) = find_byte(&bytes[i..], b'\n') {
                out.push_str(&input[i..i + j]);
                i += j;
            } else {
                out.push_str(&input[i..]);
                return out;
            }
            continue;
        }
        // block comment /* ... */
        if ch == b'/' && i + 1 < n && bytes[i + 1] == b'*' {
            if let Some(j) = find_substr(&bytes[i + 2..], b"*/") {
                let end = i + 2 + j + 2;
                out.push_str(&input[i..end]);
                i = end;
            } else {
                out.push_str(&input[i..]);
                return out;
            }
            continue;
        }
        // single-quoted string: copy through, respecting `\X` escapes
        if ch == b'\'' {
            out.push('\'');
            i += 1;
            while i < n {
                let c2 = bytes[i];
                if c2 == b'\\' && i + 1 < n {
                    out.push_str(&input[i..i + 2]);
                    i += 2;
                    continue;
                }
                out.push(c2 as char);
                i += 1;
                if c2 == b'\'' {
                    break;
                }
            }
            continue;
        }
        // top-level double-quoted string → rewrite
        if ch == b'"' {
            let mut j = i + 1;
            let mut inner = String::new();
            let mut closed = false;
            while j < n {
                let c2 = bytes[j];
                if c2 == b'\\' && j + 1 < n {
                    inner.push(bytes[j + 1] as char);
                    j += 2;
                    continue;
                }
                if c2 == b'"' {
                    closed = true;
                    break;
                }
                inner.push(c2 as char);
                j += 1;
            }
            if !closed {
                out.push_str(&input[i..]);
                return out;
            }
            let safe: String = inner.chars().map(|c| if c == '\'' { '_' } else { c }).collect();
            out.push('\'');
            out.push_str(&safe);
            out.push('\'');
            i = j + 1;
            continue;
        }
        out.push(ch as char);
        i += 1;
    }
    out
}

fn find_byte(haystack: &[u8], needle: u8) -> Option<usize> {
    haystack.iter().position(|&b| b == needle)
}

fn find_substr(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

// ─── Step 7: Backslash escape strip inside single-quoted strings ──────────────

fn single_quote_str_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"'(?:[^'\\]|\\.)*'").unwrap())
}

fn backslash_escape_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\\(.)").unwrap())
}

fn strip_backslash_in_strings(input: &str) -> String {
    single_quote_str_re()
        .replace_all(input, |caps: &regex::Captures<'_>| {
            let matched = &caps[0];
            let inner = &matched[1..matched.len() - 1];
            let rewritten =
                backslash_escape_re().replace_all(inner, |c: &regex::Captures<'_>| {
                    let ch = &c[1];
                    if ch == "'" || ch == "\"" {
                        "_".to_string()
                    } else {
                        ch.to_string()
                    }
                });
            format!("'{}'", rewritten)
        })
        .into_owned()
}

// ─── Step 8: Missing comma between adjacent string literals in IN list ────────

fn missing_comma_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(')(\s*\n\s*)(')").unwrap())
}

fn add_missing_comma_between_strings(input: &str) -> String {
    let mut prev = String::new();
    let mut cur = input.to_string();
    while prev != cur {
        prev = cur.clone();
        cur = missing_comma_re().replace_all(&cur, "$1,$2$3").into_owned();
    }
    cur
}

// ─── Step 9: CTE missing AS auto-insert ───────────────────────────────────────

fn cte_missing_as_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?i)(,\s*)(\w+)(\s*\n\s*)(\(\s*select)").unwrap()
    })
}

fn fix_cte_missing_as(input: &str) -> String {
    cte_missing_as_re()
        .replace_all(input, "$1$2 AS$3$4")
        .into_owned()
}

// ─── Step 10: Collapse `;;;;` and leading semicolons ──────────────────────────

fn multi_semi_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(\s*;\s*){2,}").unwrap())
}

fn collapse_semicolons(input: &str) -> String {
    let s = multi_semi_re().replace_all(input, ";\n").into_owned();
    s.trim_start_matches(|c: char| c == ';' || c.is_whitespace())
        .to_string()
}

// ─── Step 11: Auto-insert `;` between adjacent top-level statements ───────────

fn new_stmt_head_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    // Match SELECT/INSERT/WITH at line start. WITH is filtered separately below
    // because `regex` crate doesn't support negative look-ahead — we need to
    // exclude `WITH CUBE/ROLLUP/TOTALS` which are GROUP BY extensions.
    R.get_or_init(|| Regex::new(r"(?i)^\s*(select|insert|with)\b").unwrap())
}

fn with_extension_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?i)^\s*with\s+(cube|rollup|totals)\b").unwrap())
}

fn line_comment_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"--.*$").unwrap())
}

fn stmt_end_tail_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"(?i)\b(?:asc|desc|having)\s*$|\blimit\s+\d+\s*$|\border\s+by\s+[\w.,\s]+\s*$|\bgroup\s+by\s+[\w.,\s]+\s*$",
        )
        .unwrap()
    })
}

fn never_end_tail_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"(?i)(,|\(|=|\bas\b|\bjoin\b|\bunion(\s+all)?\b|\bon\b|\band\b|\bor\b|\bnot\b|\bin\b|\bcase\b|\bwhen\b|\bthen\b|\belse\b|\binsert\b|\bwith\b|partition\s*\([^)]*\))\s*$",
        )
        .unwrap()
    })
}

fn string_literal_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"'(?:[^'\\]|\\.)*'").unwrap())
}

/// Heuristic: when paren_depth==0 and a line begins with `SELECT|INSERT|WITH`,
/// look backwards for the previous non-empty non-comment line; if it ends in a
/// clear statement-terminating clause (`LIMIT n`, `ORDER BY ...`, `... DESC`),
/// inject a trailing `;`.
fn auto_split_statements(input: &str) -> String {
    let mut lines: Vec<String> = input.split('\n').map(str::to_string).collect();
    let mut paren_depth: i32 = 0;

    for idx in 0..lines.len() {
        let line = lines[idx].clone();
        let starts_new = paren_depth == 0
            && new_stmt_head_re().is_match(&line)
            && !with_extension_re().is_match(&line);
        if starts_new {
            for j in (0..idx).rev() {
                let prev = lines[j].trim_end().to_string();
                let stripped = prev.trim();
                if stripped.is_empty() || stripped.starts_with("--") {
                    continue;
                }
                if stripped.ends_with(';') {
                    break;
                }
                let no_comment = line_comment_re().replace(&prev, "").trim_end().to_string();
                if stmt_end_tail_re().is_match(&no_comment)
                    && !never_end_tail_re().is_match(&no_comment)
                {
                    lines[j] = format!("{};", prev);
                }
                break;
            }
        }
        // update paren_depth (ignoring string literals and line comments)
        let scrubbed = string_literal_re().replace_all(&line, "");
        let scrubbed = line_comment_re().replace_all(&scrubbed, "").into_owned();
        let opens = scrubbed.matches('(').count() as i32;
        let closes = scrubbed.matches(')').count() as i32;
        paren_depth += opens - closes;
        if paren_depth < 0 {
            paren_depth = 0;
        }
        if scrubbed.trim().ends_with(';') {
            paren_depth = 0;
        }
    }

    lines.join("\n")
}

// ─── Step 12: `! IN (...)` → `NOT IN (...)` ───────────────────────────────────

fn bang_in_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?i)!\s*IN\s*\(").unwrap())
}

fn rewrite_hive_not_in(input: &str) -> String {
    bang_in_re().replace_all(input, "NOT IN (").into_owned()
}

// ─── Step 12.5: Orphan `AS` followed by clause keyword → drop AS ──────────────

const AS_CLAUSE_KEYWORDS: &[&str] = &[
    "from", "where", "group", "order", "having", "limit", "union", "join",
    "left", "right", "inner", "cross", "on", "when", "else", "end", "and",
    "or", "then",
];

/// Hive sometimes tolerates `case ... end as\nfrom ...` (AS with no alias).
/// Strip such an `AS` when the next non-blank token is a SQL clause keyword.
/// **Must** skip comments and strings to avoid touching commented-out `as`.
fn fix_orphan_as(input: &str) -> String {
    let bytes = input.as_bytes();
    let n = bytes.len();
    let mut out = String::with_capacity(n);
    let mut i = 0;
    while i < n {
        if bytes[i] == b'-' && i + 1 < n && bytes[i + 1] == b'-' {
            if let Some(j) = find_byte(&bytes[i..], b'\n') {
                out.push_str(&input[i..i + j]);
                i += j;
            } else {
                out.push_str(&input[i..]);
                return out;
            }
            continue;
        }
        if bytes[i] == b'/' && i + 1 < n && bytes[i + 1] == b'*' {
            if let Some(j) = find_substr(&bytes[i + 2..], b"*/") {
                let end = i + 2 + j + 2;
                out.push_str(&input[i..end]);
                i = end;
            } else {
                out.push_str(&input[i..]);
                return out;
            }
            continue;
        }
        if bytes[i] == b'\'' {
            out.push('\'');
            i += 1;
            while i < n {
                let c = bytes[i];
                if c == b'\\' && i + 1 < n {
                    out.push_str(&input[i..i + 2]);
                    i += 2;
                    continue;
                }
                out.push(c as char);
                i += 1;
                if c == b'\'' {
                    break;
                }
            }
            continue;
        }
        // detect \bAS\b
        let is_as = (bytes[i] == b'A' || bytes[i] == b'a')
            && i + 1 < n
            && (bytes[i + 1] == b'S' || bytes[i + 1] == b's')
            && (i == 0
                || !(bytes[i - 1].is_ascii_alphanumeric() || bytes[i - 1] == b'_'))
            && (i + 2 >= n
                || !(bytes[i + 2].is_ascii_alphanumeric() || bytes[i + 2] == b'_'));
        if is_as {
            let mut j = i + 2;
            while j < n && matches!(bytes[j], b' ' | b'\t' | b'\r' | b'\n') {
                j += 1;
            }
            let mut k = j;
            while k < n && (bytes[k].is_ascii_alphanumeric() || bytes[k] == b'_') {
                k += 1;
            }
            let next_word = input[j..k].to_ascii_lowercase();
            if AS_CLAUSE_KEYWORDS.contains(&next_word.as_str()) {
                // Drop only the `AS` token; preserve the whitespace before the
                // clause keyword so line/column drift is minimised.
                i += 2;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

// ─── Step 13: GROUP BY GROUPING SETS/CUBE/ROLLUP → GROUP BY 1 ─────────────────

fn grouping_sets_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?is)group\s+by\s+grouping\s+sets\s*\((?:[^()]|\([^()]*\))*\)").unwrap()
    })
}

fn rewrite_grouping_sets(input: &str) -> String {
    grouping_sets_re()
        .replace_all(input, "GROUP BY 1")
        .into_owned()
}

// ─── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // Step 1
    #[test]
    fn placeholders_all_forms() {
        let s = "select '${a}', '{{b}}', '{{{c}}}', ${d}, {{e}}, {{{f}}} from t";
        let out = substitute_placeholders(s);
        assert!(!out.contains("${"), "got: {out}");
        assert!(!out.contains("{{"), "got: {out}");
        assert!(!out.contains("}}"), "got: {out}");
        assert_eq!(out.matches("'__ph__'").count(), 6);
    }

    #[test]
    fn placeholders_triple_before_double() {
        // {{{var}}} must not leave stray `}` behind
        let out = substitute_placeholders("{{{a}}}");
        assert_eq!(out, "'__ph__'");
    }

    // Step 2
    #[test]
    fn line_filter_set_and_add() {
        let s = "set hive.exec.parallel=true;\nadd file foo.py;\nselect 1";
        let out = filter_lines(s);
        assert_eq!(out, "\n\nselect 1");
    }

    // Step 3
    #[test]
    fn ddl_stmt_filter() {
        let s = "create table t (a int) stored as orc; select 1; drop table t; insert into u select 1";
        let out = filter_ddl_statements(s);
        // CREATE TABLE and DROP TABLE dropped
        assert!(!out.to_lowercase().contains("create table"));
        assert!(!out.to_lowercase().contains("drop table"));
        assert!(out.contains("select 1"));
        assert!(out.contains("insert into u"));
    }

    #[test]
    fn ddl_stmt_filter_handles_leading_comments() {
        let s = "-- header\ncreate table t (a int); select 1";
        let out = filter_ddl_statements(s);
        assert!(!out.to_lowercase().contains("create table"));
        assert!(out.contains("select 1"));
    }

    #[test]
    fn ddl_stmt_filter_handles_multiline_set() {
        let s = "set\n  mapreduce.reduce.memory.mb=8096; select 1";
        let out = filter_ddl_statements(s);
        assert!(!out.to_lowercase().contains("mapreduce"));
        assert!(out.contains("select 1"));
    }

    // Step 4
    #[test]
    fn transform_using_removed() {
        let s = "select transform(a, b) using 'python s.py' as (x string, y int) from t";
        let out = rewrite_transform_using(s);
        assert!(!out.to_lowercase().contains("using"));
        assert!(!out.contains("as ("));
    }

    // Step 5
    #[test]
    fn array_index_dropped() {
        assert_eq!(rewrite_array_index("split(x, '-')[1]"), "split(x, '-')");
        assert_eq!(rewrite_array_index("arr[0]"), "arr");
        assert_eq!(rewrite_array_index("map['k']"), "map");
    }

    // Step 6
    #[test]
    fn double_quote_to_single() {
        let out = rewrite_double_quote_strings(r#"select "abc" from t"#);
        assert_eq!(out, "select 'abc' from t");
    }

    #[test]
    fn double_quote_skips_inside_single_quoted_string() {
        // `'^(.*?)"'` — the `"` is inside a single-quoted regex pattern, must not touch
        let input = r#"select regexp_extract(x, '^(.*?)"') from t"#;
        let out = rewrite_double_quote_strings(input);
        assert_eq!(out, input);
    }

    #[test]
    fn double_quote_skips_in_line_comment() {
        let input = "-- value is \"X\"\nselect 1";
        let out = rewrite_double_quote_strings(input);
        assert_eq!(out, input);
    }

    // Step 7
    #[test]
    fn backslash_escape_stripped() {
        // `'\\|'` → `'|'`
        let out = strip_backslash_in_strings(r"'\|'");
        assert_eq!(out, "'|'");
    }

    #[test]
    fn backslash_quote_neutralized() {
        // `'\''` → `'_'` (single quote inside replaced with `_` to avoid string-end ambiguity)
        let out = strip_backslash_in_strings(r"'\''");
        assert_eq!(out, "'_'");
    }

    // Step 8
    #[test]
    fn missing_comma_in_in_list() {
        let input = "where a in ('a'\n  'b'\n  'c')";
        let out = add_missing_comma_between_strings(input);
        assert!(out.contains("'a',"));
        assert!(out.contains("'b',"));
    }

    // Step 9
    #[test]
    fn cte_missing_as_inserted() {
        let input = ", my_cte\n(select 1 from t)";
        let out = fix_cte_missing_as(input);
        assert!(out.contains("my_cte AS"));
    }

    // Step 10
    #[test]
    fn collapse_consecutive_semicolons() {
        assert_eq!(collapse_semicolons(";;;\nselect 1"), "select 1");
        assert_eq!(collapse_semicolons("a;;b"), "a;\nb");
    }

    // Step 11
    #[test]
    fn auto_split_two_selects() {
        let input = "select a from t limit 10\nselect b from u";
        let out = auto_split_statements(input);
        assert!(out.contains("limit 10;"));
    }

    #[test]
    fn auto_split_does_not_break_with_insert() {
        let input = "with cte as (select 1 a)\ninsert into t select 1\nselect 2 from u limit 5";
        let out = auto_split_statements(input);
        // `WITH ... INSERT` must NOT get a `;` injected between WITH and INSERT
        // (the `with cte as (...)` line ends with `)`, which is not in stmt_end_tail set)
        assert!(!out.contains("a)\n;insert"));
    }

    #[test]
    fn auto_split_does_not_break_with_cube() {
        let input = "select a from t group by a with cube\nselect 1 from u";
        let out = auto_split_statements(input);
        // `WITH CUBE` is GROUP BY extension, not a CTE head
        assert!(out.contains("with cube"));
    }

    // Step 12
    #[test]
    fn bang_in_to_not_in() {
        assert_eq!(rewrite_hive_not_in("where a ! in ('x')"), "where a NOT IN ('x')");
        assert_eq!(rewrite_hive_not_in("where a !IN ('x')"), "where a NOT IN ('x')");
    }

    // Step 12.5
    #[test]
    fn orphan_as_dropped_before_from() {
        // `end as\n` → `end \n` (drop AS, preserve the whitespace around it)
        let input = "select case when a > 0 then 'X' end as\nfrom (select 1 a from t) tt";
        let out = fix_orphan_as(input);
        assert!(!out.contains("as\n"), "got: {out}");
        // After dropping AS the line is `... end \n` (with a trailing space).
        assert!(out.contains("end \nfrom"), "got: {out}");
    }

    #[test]
    fn orphan_as_preserves_legitimate_alias() {
        let input = "select a as col1, sum(x) as sum from t";
        let out = fix_orphan_as(input);
        assert_eq!(out, input);
    }

    #[test]
    fn orphan_as_skips_inside_comment() {
        let input = "-- ,count(*) as \n\nfrom t";
        let out = fix_orphan_as(input);
        assert!(out.contains("-- ,count(*) as"));
    }

    // Step 13
    #[test]
    fn grouping_sets_rewritten() {
        let input = "select a from t group by grouping sets((a), (b))";
        let out = rewrite_grouping_sets(input);
        assert!(out.to_lowercase().contains("group by 1"));
        assert!(!out.to_lowercase().contains("grouping sets"));
    }

    // Full pipeline smoke
    #[test]
    fn full_pipeline_smoke() {
        // Covers Step 2 (SET filter), Step 3 (DDL filter), Step 6 (double quote),
        // Step 9 (CTE missing AS — only for *non-first* CTE following a comma),
        // Step 12 (! IN), Step 12.5 (orphan AS), Step 13 (GROUPING SETS).
        let input = r#"-- batch
set hive.exec.parallel=true;
create table t (a int) stored as orc;
with first_cte as (select 1 a from src)
, second_cte
(select 2 b from src)
select case when a > 0 then "POS" end as
from first_cte
where a ! in (1, 2)
group by grouping sets((a))"#;
        let out = preprocess(input);
        let lower = out.to_lowercase();
        assert!(!lower.contains("set hive"), "got: {out}");
        assert!(!lower.contains("create table"), "got: {out}");
        assert!(lower.contains("'pos'"), "got: {out}");
        // orphan AS dropped (the `as\n` from `end as\nfrom` becomes ` \nfrom`)
        assert!(!out.contains("end as\n"), "got: {out}");
        assert!(lower.contains("not in"), "got: {out}");
        assert!(lower.contains("group by 1"), "got: {out}");
        // Step 9: second_cte gets AS inserted because the regex requires a leading comma.
        assert!(lower.contains("second_cte as"), "got: {out}");
    }
}
