# Fix Location Thinking Guide

> **Purpose**: Before fixing a bug or adding a "compatibility layer", decide
> which layer of the codebase the fix belongs in. Putting the right code in
> the wrong place is one of the most common causes of "we fixed it but
> production still breaks".

---

## The Test Question

Before writing a single line of fix code, ask:

> **If a real user takes the *original* input and runs the *production code path*,
> do they hit the fix?**

If the answer is "no" or "only sometimes" — you are about to fix the wrong layer.

---

## Concrete Case: Hive SQL Preprocessing (May 2026)

### What went wrong

Task `05-14-fix-hive-sql-parse-errors` asked for fixing Hive SQL parse failures.
We built a 13-step preprocessing pipeline in
`scripts/batch-parse-warehouse.py` and ran a batch test that hit
**5105 / 5105 = 100%** pass rate.

We marked the task done.

But the **production code path** for any real user looks like this:

```
[ user / VS Code / web UI ] → POST /api/analyze → flowscope_core::analyze()
```

There is **no Python in that path**. The "fix" only existed in our local
batch test harness. Real Hive SQL through `/api/analyze` still failed ~30%
of the time.

### How we caught it

The user asked a one-liner:

> 为什么要有这个 python 脚本呢？通过 api 过来的 sql 解析过这个 python 脚本么？

That question is the **Test Question** above, applied directly. Answer: no,
real API traffic never sees the Python script. The fix was in the wrong layer.

### What we did instead

Moved all 13 steps to `crates/flowscope-core/src/hive_preprocess.rs`,
hooked into `flowscope_core::analyze()` when `dialect == Hive`. Deleted the
Python script. Wrote an integration test (`tests/hive_corpus.rs`) that calls
`analyze()` directly — same 5105 files, 100% pass rate, **for real this time**.

---

## Layer-Selection Decision Tree

When you discover a bug or compatibility gap, walk this tree:

```text
1. Who hits this code path?
   ├── Only batch / test harness  → fix can live in the harness
   ├── Any client of the public API → fix MUST be in shared library / API layer
   └── Specific transport (e.g. HTTP / wasm) only → fix in that transport layer

2. Is the fix re-introducing missing functionality of an SDK / parser / library?
   ├── YES, library has a bug we can't change → wrapper or preprocess in OUR core
   ├── YES, library has the option we missed → just configure it
   └── NO, fix is consumer-specific → fix in consumer layer

3. Will the fix change input data?
   ├── YES → document the side effects (span offset, lost literals, etc.)
   │         and decide who owns reversing them
   └── NO → safe to apply at the lowest reasonable layer

4. Does the fix have a "natural home" already?
   ├── YES → put it next to similar fixes (e.g. dialect_ext, preprocessing)
   └── NO → create the new home, give it a name that says what it does
```

---

## Red Flags You're Fixing the Wrong Layer

- The fix only runs in tests, scripts, or CI tooling
- You're writing a "wrapper that calls the real thing after some transformation"
  but the real thing is also exposed directly to users
- Pass rate / test metrics improved but production users report the same bug
- You can answer "who calls this fix path?" with "the test that proves the fix works"
- The fix lives in a different language / runtime than the library being fixed
  (e.g. Python preprocessing for a Rust parser)

---

## Green Flags You're Fixing the Right Layer

- All existing consumers (API, SDK, wasm, CLI, IDE plugin, …) get the fix for free
- The fix has unit tests in the **same crate / module** as the thing being fixed
- The integration / corpus test calls the **public entry point** of the library,
  not some private/internal helper that bypasses production code
- Removing the fix breaks the production code path (proves it's actually wired in)

---

## Anti-Pattern: "Test Harness Compatibility Layer"

```text
[ test harness ] --preprocess--> [ public API ] --> [ library ]
[ real users  ] ----------(direct)----------------> [ public API ] --> [ library ]
                                                       ^
                                                       |
                                                  not preprocessed!
```

If the preprocessing belongs anywhere, it belongs **inside** the library or
in the API layer — anywhere the real user traffic flows through. A
preprocessing step that lives *outside* the user's request path is, at best,
self-deception. At worst, it ships green metrics with red production.

---

## Acceptance Methodology

When you claim "I fixed it":

1. Identify the **public entry point** that real users actually call
2. Build a test that goes through **that exact entry point** with **unmodified
   inputs** (no harness-side cleanup, no helper preprocessing)
3. Make that test fail without your fix
4. Apply your fix
5. Make that test pass with your fix
6. Bonus: delete any local-only "test cleanup" scripts that were masking the
   real failure mode — if your fix is in the right place, you don't need them

If step 2 requires preprocessing **outside** the library — go back to the
layer decision tree.
