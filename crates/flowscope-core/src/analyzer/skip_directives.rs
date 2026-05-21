//! Whitelist of SQL directives that carry no lineage value and must be skipped.
//!
//! ## Why
//!
//! Hive/Spark batch scripts often start with session/admin directives
//! (`SET`, `REFRESH TABLE`, `USE`, `MSCK REPAIR`, `ANALYZE TABLE`). These have no
//! impact on data lineage and either:
//!   - parse fine but pollute the `statements` array with no useful info, or
//!   - are not recognized by `sqlparser-rs` and produce `PARSE_ERROR` issues.
//!
//! Both outcomes are noise. This module is the **single source of truth** for
//! which directive keywords are dropped before/after parsing.
//!
//! ## Two enforcement points (share this same keyword list)
//!
//! - **Text layer** (`is_skippable_directive`) — used in
//!   [`crate::analyzer::input::parse_statement_ranges_best_effort`]. Skips
//!   statement slices whose first keyword is in the whitelist *before* handing
//!   them to `sqlparser`. This is the only way to filter directives that
//!   `sqlparser` cannot parse (e.g. `REFRESH`, `MSCK`).
//! - **AST layer** (`is_skippable_statement`) — used in
//!   [`crate::analyzer::Analyzer::analyze`]. Skips parsed statements whose AST
//!   variant maps to a whitelisted keyword. This handles directives that
//!   `sqlparser` *does* parse (notably `SET`, `USE`, `ANALYZE`) when the full
//!   buffer parse succeeds and we never enter the best-effort path.
//!
//! ## Adding a new directive
//!
//! Append the uppercase keyword to [`default_skip_keywords`] for the relevant
//! dialect, then make sure [`is_skippable_statement`] maps the corresponding
//! `Statement` variant (if `sqlparser` recognizes it). The text layer needs
//! no further change — it works off the keyword list alone.

use crate::types::Dialect;
use sqlparser::ast::Statement;

/// Returns the directive keywords to skip for a given dialect.
///
/// Keywords are uppercase ASCII and compared case-insensitively.
///
/// **Hive / Spark** scripts commonly contain all five; other dialects only
/// emit `SET` (and even that is rare in OLTP).
pub(crate) fn default_skip_keywords(dialect: Dialect) -> &'static [&'static str] {
    match dialect {
        Dialect::Hive => &["SET", "REFRESH", "USE", "MSCK", "ANALYZE"],
        _ => &["SET"],
    }
}

/// Returns `true` when the *text slice* of one statement is a skippable
/// directive — meaning its first non-whitespace/non-comment keyword is in the
/// dialect's whitelist.
///
/// Used by the best-effort parsing path *before* sending the slice to
/// `sqlparser`. This is critical for directives `sqlparser` cannot parse
/// (e.g. `REFRESH TABLE foo.bar`) — without this filter they would surface as
/// `PARSE_ERROR` issues.
pub(crate) fn is_skippable_directive(snippet: &str, dialect: Dialect) -> bool {
    let Some(first_keyword) = first_keyword(snippet) else {
        return false;
    };
    let upper = first_keyword.to_ascii_uppercase();
    default_skip_keywords(dialect)
        .iter()
        .any(|kw| *kw == upper)
}

/// Returns `true` when a parsed AST statement matches a skippable directive
/// for the given dialect.
///
/// Used after the full-buffer parse succeeds (`Analyzer::analyze`). Two
/// strategies in order:
///   1. **Fast path** — explicit `match` for the well-known variants we
///      care about (`SET`, `USE`, `ANALYZE`). O(1), no allocation.
///   2. **Fallback** — re-render the AST node back to SQL via `Display` and
///      reuse the text-layer keyword scanner. Catches dialect-specific
///      variants like `Statement::Msck { .. }` whose enum identity is
///      unstable across `sqlparser-rs` versions but whose `Display` output
///      reliably starts with the directive keyword. The render cost is
///      negligible because directive statements are tiny (one line).
pub(crate) fn is_skippable_statement(stmt: &Statement, dialect: Dialect) -> bool {
    let keywords = default_skip_keywords(dialect);
    let fast_label: Option<&str> = match stmt {
        Statement::Set(_) => Some("SET"),
        Statement::Use(_) => Some("USE"),
        Statement::Analyze { .. } => Some("ANALYZE"),
        _ => None,
    };
    if let Some(label) = fast_label {
        return keywords.contains(&label);
    }

    let rendered = stmt.to_string();
    is_skippable_directive(&rendered, dialect)
}

/// Extracts the first SQL keyword from `snippet`, skipping leading whitespace,
/// line comments (`-- …`) and block comments (`/* … */`).
///
/// Returns `None` if the snippet contains no identifier-like token (empty
/// statement, only comments, etc.).
fn first_keyword(snippet: &str) -> Option<&str> {
    let bytes = snippet.as_bytes();
    let mut i = 0usize;
    let len = bytes.len();

    while i < len {
        let b = bytes[i];
        if b.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if b == b'-' && i + 1 < len && bytes[i + 1] == b'-' {
            i += 2;
            while i < len && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if b == b'/' && i + 1 < len && bytes[i + 1] == b'*' {
            i += 2;
            while i + 1 < len && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                i += 1;
            }
            // Skip the closing "*/" if found; otherwise unterminated block
            // comment, treat as no keyword present.
            if i + 1 < len {
                i += 2;
            } else {
                return None;
            }
            continue;
        }
        break;
    }

    if i >= len {
        return None;
    }

    let start = i;
    while i < len {
        let b = bytes[i];
        let is_word = b.is_ascii_alphanumeric() || b == b'_';
        if !is_word {
            break;
        }
        i += 1;
    }

    if i == start {
        return None;
    }
    Some(&snippet[start..i])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_keyword_handles_plain() {
        assert_eq!(first_keyword("SELECT 1"), Some("SELECT"));
        assert_eq!(first_keyword("  refresh table x"), Some("refresh"));
    }

    #[test]
    fn first_keyword_skips_line_comment() {
        assert_eq!(
            first_keyword("-- leading comment\nREFRESH TABLE x"),
            Some("REFRESH")
        );
    }

    #[test]
    fn first_keyword_skips_block_comment() {
        assert_eq!(
            first_keyword("/* note */ SET x = 1"),
            Some("SET")
        );
        assert_eq!(
            first_keyword("/* a */ /* b */\n  USE my_db"),
            Some("USE")
        );
    }

    #[test]
    fn first_keyword_handles_empty_and_comment_only() {
        assert_eq!(first_keyword(""), None);
        assert_eq!(first_keyword("   "), None);
        assert_eq!(first_keyword("-- only comment"), None);
        assert_eq!(first_keyword("/* unterminated"), None);
    }

    #[test]
    fn skippable_directive_recognizes_hive_keywords() {
        for kw in ["SET", "REFRESH", "USE", "MSCK", "ANALYZE"] {
            let snippet = format!("{kw} TABLE foo");
            assert!(
                is_skippable_directive(&snippet, Dialect::Hive),
                "Hive should skip `{kw}`"
            );
        }
    }

    #[test]
    fn skippable_directive_is_case_insensitive() {
        assert!(is_skippable_directive("refresh table foo", Dialect::Hive));
        assert!(is_skippable_directive("Refresh Table foo", Dialect::Hive));
        assert!(is_skippable_directive("REFRESH TABLE foo", Dialect::Hive));
    }

    #[test]
    fn skippable_directive_respects_dialect() {
        assert!(is_skippable_directive("SET a=1", Dialect::Generic));
        assert!(!is_skippable_directive("REFRESH TABLE x", Dialect::Generic));
        assert!(!is_skippable_directive("USE my_db", Dialect::Ansi));
    }

    #[test]
    fn skippable_directive_ignores_select_and_dml() {
        assert!(!is_skippable_directive("SELECT 1", Dialect::Hive));
        assert!(!is_skippable_directive(
            "INSERT OVERWRITE TABLE x SELECT 1",
            Dialect::Hive
        ));
        assert!(!is_skippable_directive(
            "WITH cte AS (SELECT 1) SELECT * FROM cte",
            Dialect::Hive
        ));
    }
}
