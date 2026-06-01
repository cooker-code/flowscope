# PRD: fix placeholder scanner cuts pending buffer on quote inside {{ }}

## Background

`hive_preprocess.rs::substitute_placeholders` uses a character-level scanner that detects
single-quote / double-quote to enter string-literal mode. When a `'` appears **inside**
a `{{ }}` or `{{{ }}}` placeholder, the scanner prematurely flushes the `pending` buffer
mid-placeholder, then treats the content after `'` as a string literal. The partial
`{{...['` left in `pending` is not matched by the bare-form regex
(`\{\{[^}]*\}\}` requires a complete `{{...}}`), so the placeholder survives intact into
the parser and causes a parse error.

### Affected patterns (all from `test-sql/`)

| File | Offending placeholder |
|------|----------------------|
| `24025.sql` | `{{other['taskid'] as taskid}}` |
| `28729.sql` | `{{from_unixtime(int(startclasstime / 1000), 'yyyy-MM-dd') AS start_class_dt}}` |
| `27167.sql` | `{{regexp_replace(split(period_type, '-') [1], '\\/', '\\-') AS start_class_dt}}` |
| `28181.sql` | same as 27167 |

### Current behaviour

```
substitute_placeholders("AND {{other['taskid'] as taskid}}")
```
Steps:
1. Scan `AND ` → pending = `"AND "`
2. Scan `{{other[` → pending = `"AND {{other["`
3. Scan `'` → **flush** pending (`AND {{other[` — no regex match), enter string mode
4. Scan `taskid` → string body has no placeholder marker → emit `'taskid'` verbatim
5. Resume → pending = `" as taskid}}"`
6. End → flush → no regex match → `" as taskid}}"` emitted verbatim

Result: `AND {{other['taskid'] as taskid}}` → still in SQL → parse error.

### Expected behaviour

`AND {{other['taskid'] as taskid}}` → `AND '__ph__'`

## Requirements

1. When the scanner is **inside** a `{{...}}` or `{{{...}}}` bracket, encountering a
   `'` or `"` must **not** trigger string-literal mode. The scanner should continue
   accumulating into `pending` until the matching `}}` / `}}}` is closed.
2. The fix must handle nested single-quotes, double-quotes, and backslash-escape
   sequences inside the placeholder body (e.g., `'yyyy-MM-dd'`, `'\\/'`).
3. All previously passing placeholder tests must continue to pass.
4. The four affected files in `test-sql/` must no longer produce parse errors.

## Acceptance Criteria

- [ ] `substitute_placeholders("AND {{other['taskid'] as taskid}}")` returns `"AND '__ph__'"`.
- [ ] `substitute_placeholders("AND {{from_unixtime(int(t/1000), 'yyyy-MM-dd') AS dt}}")` returns `"AND '__ph__'"`.
- [ ] `substitute_placeholders("AND {{regexp_replace(col, '\\\\/', '\\\\-') AS dt}}")` returns `"AND '__ph__'"`.
- [ ] All existing `hive_preprocess` unit tests pass.
- [ ] Hive corpus test on `test-sql/` directory: `24025.sql`, `27167.sql`, `28181.sql`, `28729.sql` no longer appear in the failure list.
- [ ] `FLOWSCOPE_HIVE_CORPUS_DIR=<test-sql abs path> cargo test -p flowscope-core --test hive_corpus` passes (or leaves only non-placeholder failures).

## Constraints

- Fix must remain in `hive_preprocess.rs::substitute_placeholders` — do not change the
  public API or the preprocess pipeline step order.
- No new dependencies.
- Minimal change surface: only the scanner's string-quote detection branch needs guarding.
