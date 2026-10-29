# 实施与验证

- parser作者 /root/implement_window_parser 完成初始实现与debug CLI、原545/25473无Schema回放。
- 独立checker /root/check_window_parser 接手源码，补同列三角色、命名窗口/复杂order、Dali、VSCode穷举及原生Hive schema读取。
- 构建：CARGO_TARGET_DIR=/Users/blank/.codex/evidence/runtime/flowscope-c5-target；重新编译最终CLI并保留sha与source diff。
- 核心/export/CLI/schema/TS相关检查，原prepared窗口任务全量实际回放，与Neo4j17691控制图/独立SQL AST联合验收。
- 真实图通过后独立提交本仓C5，保护原master WIP，合本地master；不推送、不发布。
