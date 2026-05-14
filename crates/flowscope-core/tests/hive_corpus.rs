//! Corpus-driven regression test for the Hive preprocessing pipeline.
//!
//! Set `FLOWSCOPE_HIVE_CORPUS_DIR` to a directory of real Hive `.sql` files
//! (e.g. an internal warehouse) and run:
//!
//! ```bash
//! FLOWSCOPE_HIVE_CORPUS_DIR=/path/to/warehouse cargo test \
//!     -p flowscope-core --test hive_corpus -- --nocapture
//! ```
//!
//! Without the env var the test no-ops, so CI stays green for contributors
//! who don't have the corpus locally.
//!
//! Acceptance: the test asserts a per-corpus pass-rate threshold (default
//! 99.9%) and prints the first 20 failing files for triage.

use flowscope_core::{analyze, AnalyzeRequest, Dialect};
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

#[test]
fn warehouse_corpus_passes_hive_pipeline() {
    let Some(dir) = std::env::var_os("FLOWSCOPE_HIVE_CORPUS_DIR") else {
        eprintln!(
            "skipping hive corpus test: FLOWSCOPE_HIVE_CORPUS_DIR not set\n\
             (export to a directory of .sql files to enable)"
        );
        return;
    };
    let root = PathBuf::from(dir);
    assert!(root.is_dir(), "FLOWSCOPE_HIVE_CORPUS_DIR is not a directory: {}", root.display());

    let mut files = Vec::new();
    collect_sql_files(&root, &mut files);
    files.sort();
    assert!(!files.is_empty(), "no .sql files under {}", root.display());

    let threshold: f64 = std::env::var("FLOWSCOPE_HIVE_CORPUS_PASS_THRESHOLD")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.999);

    let total = files.len();
    let mut succeeded = 0usize;
    let mut skipped = 0usize;
    let mut failures: Vec<(PathBuf, String)> = Vec::new();

    for f in &files {
        let content = match fs::read_to_string(f) {
            Ok(c) => c,
            Err(e) => {
                failures.push((f.clone(), format!("read error: {e}")));
                continue;
            }
        };
        let request = AnalyzeRequest {
            sql: content,
            files: None,
            dialect: Dialect::Hive,
            source_name: f.file_name().and_then(OsStr::to_str).map(str::to_string),
            options: None,
            schema: None,
            #[cfg(feature = "templating")]
            template_config: None,
        };
        let result = analyze(&request);
        let has_errors = result.summary.has_errors;
        let stmts = result.statements.len();

        if !has_errors && stmts > 0 {
            succeeded += 1;
        } else if !has_errors && stmts == 0 {
            // Preprocessing legitimately stripped the whole file (DDL-only).
            skipped += 1;
        } else {
            let msg = result
                .issues
                .iter()
                .find(|i| matches!(i.severity, flowscope_core::Severity::Error))
                .map(|i| i.message.clone())
                .unwrap_or_else(|| "<unknown>".to_string());
            failures.push((f.clone(), msg));
        }
    }

    let pass_rate = (succeeded + skipped) as f64 / total as f64;
    eprintln!(
        "hive corpus: total={} success={} skipped={} failed={} pass={:.3}%",
        total,
        succeeded,
        skipped,
        failures.len(),
        pass_rate * 100.0,
    );

    if !failures.is_empty() {
        eprintln!("first {} failures:", failures.len().min(20));
        for (path, msg) in failures.iter().take(20) {
            let rel = path.strip_prefix(&root).unwrap_or(path);
            let m = if msg.len() > 120 { &msg[..120] } else { msg.as_str() };
            eprintln!("  {} :: {}", rel.display(), m);
        }
    }

    assert!(
        pass_rate >= threshold,
        "hive corpus pass rate {:.3}% < threshold {:.3}%",
        pass_rate * 100.0,
        threshold * 100.0,
    );
}

fn collect_sql_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(read) = fs::read_dir(dir) else { return };
    for entry in read.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_sql_files(&path, out);
        } else if path.extension().and_then(OsStr::to_str) == Some("sql") {
            out.push(path);
        }
    }
}
