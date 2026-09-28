# Implementation and verification

1. Create a `codex/` branch and set the task's base branch to `master`.
2. Create or reuse the `yuanli/flowscope` issue for audit 443044.
3. Add the Hive trait override and a parser-level test.
4. Add a public `analyze()` regression for a compact literal row source.
5. Run focused core tests, all core library tests, and SQL regression.
6. Run the unchanged audit 443044 SQL through the rebuilt Hive CLI; verify
   errors, target table, source tables, statements, and graph edges.
7. Build the frontend, sync CLI embedded assets, and cross-compile the Linux
   serve binary with `cargo zigbuild` for glibc 2.17. Verify embed equality,
   target format, required GLIBC ceiling, and SHA-256.
8. Update the issue with actual results and package identity; leave it open
   for deployment and post-deployment audit readback.

## Risk and rollback

The new dialect option also affects other Hive SQL containing `FROM VALUES`.
Watch for incorrect physical source classification and graph edges. Revert the
single trait override if regression evidence shows broader parser ambiguity;
do not edit the audited source SQL to make tests pass.
