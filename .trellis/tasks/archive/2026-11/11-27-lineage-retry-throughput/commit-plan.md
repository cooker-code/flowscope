# 本地提交计划

用户已明确授权两项修改一起提交并打包上传，不再重复请求确认。按 Git 规范将当前任务的代码、文档和验收放在同一工作提交。

## fix(lineage-retry-throughput): 批量入图并精简审计列表

- CHANGELOG.md
- app/src/pages/AuditPage.tsx
- crates/flowscope-cli/src/server/lineage.rs
- crates/flowscope-cli/src/server/lineage_policy.rs
- crates/flowscope-storage/src/lib.rs
- crates/flowscope-storage/src/neo4j.rs
- crates/flowscope-storage/tests/lineage.rs
- crates/flowscope-storage/tests/throughput.rs
- .trellis/spec/flowscope-cli/backend/lineage-policy.md
- .trellis/spec/flowscope-storage/backend/index.md
- .trellis/spec/flowscope-storage/backend/ingestion-performance.md
- docs/README.md
- docs/guides/lineage-ingestion-personal-usage.zh-CN.md
- .trellis/tasks/11-27-lineage-retry-throughput/bug-analysis.md
- .trellis/tasks/11-27-lineage-retry-throughput/commit-plan.md
- .trellis/tasks/11-27-lineage-retry-throughput/design.md
- .trellis/tasks/11-27-lineage-retry-throughput/implement.md
- .trellis/tasks/11-27-lineage-retry-throughput/prd.md
- .trellis/tasks/11-27-lineage-retry-throughput/research/audit-651353.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/http-benchmark.py
- .trellis/tasks/11-27-lineage-retry-throughput/research/http-summary.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/http-throughput.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/neo4j-index-repair.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/neo4j-projection-before.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/neo4j-readonly.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/personal-usage-query.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/production-recovered-api.txt
- .trellis/tasks/11-27-lineage-retry-throughput/research/resource-cleanup.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/throughput-after.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/throughput-before.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/throughput-index-only.json
- .trellis/tasks/11-27-lineage-retry-throughput/research/throughput-summary.json
- .trellis/tasks/11-27-lineage-retry-throughput/task.json
- .trellis/tasks/11-27-lineage-retry-throughput/verification.md

临时 packages/core/node_modules 和 packages/react/node_modules 链接不纳入提交；构建后清理。前一审计任务工作区的未提交文档保留原状。后续将打包上传证据追加记录，不部署或推送。

## 执行结果

工作提交 `ec001c6f650c36f795a32c19d0cd32ec5227f529` 已完成。打包上传证据随后补记，下载地址和 SHA256 见 research/cli-release.json。
