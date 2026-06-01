# Implement: fix placeholder scanner quote-inside-braces

## Ordered Checklist

- [ ] 1. Edit `hive_preprocess.rs::substitute_placeholders` — add `brace_depth` counter,
         guard string-quote branch and comment branches on `brace_depth == 0`
- [ ] 2. Add unit tests in `hive_preprocess.rs` for:
         - `{{other['taskid'] as taskid}}`
         - `{{from_unixtime(int(t/1000), 'yyyy-MM-dd') AS dt}}`
         - `{{regexp_replace(col, '\\/', '\\-') AS dt}}`
         - mixed: normal string before placeholder `WHERE name='foo' AND {{dt}}`
- [ ] 3. Run `cargo test -p flowscope-core --lib` — all tests pass
- [ ] 4. Run `FLOWSCOPE_HIVE_CORPUS_DIR=<abs-path>/test-sql cargo test -p flowscope-core --test hive_corpus -- --nocapture`
         — confirm 24025/27167/28181/28729 no longer in failure list

## Validation Commands

```bash
cargo test -p flowscope-core --lib                          # unit tests
FLOWSCOPE_HIVE_CORPUS_DIR=/Users/blank/wangliang/gitcode/flowscope/test-sql \
  cargo test -p flowscope-core --test hive_corpus -- --nocapture
```

## Rollback

Revert the single function edit in `hive_preprocess.rs`.
