# 策略精简与调用方管理验证

2026-11-25，按用户在本地策略页面的反馈实施。代码位于独立工作树 `codex/realtime-lineage-storage-plan`，未提交、未部署生产。

## 当前行为

- 鉴权链路为 token → 调用方 → 是否启用及默认动作。调用方策略只包含 `id/name/kind/enabled/action/revision`。
- 删除页面和后端中的允许环境、允许来源、禁止来源和允许表范围。旧字段原本用于在同一 token 下再限制任务或表，当前需求无需配置。
- 调度请求仍带 `lineage.sourceSystem/sourceId/sourceVersion`，用于识别任务及其版本。同一个调度 token 提交不同任务时，血缘贡献分开管理。请求 environment 仍须匹配服务部署环境；没有调用方环境白名单。
- 列表展示“是否启用”。取消“启用此调用方”并保存后，原 token 的新请求返回 403；重新启用后原 token 恢复使用。写图前复核当前启用状态与动作。
- `DELETE /api/lineage/policies/{id}` 接收 `{revision}`，仅管理员可调用。SQLite 单个事务物理删除调用方及其全部 token 行，记录操作历史；旧 token 新请求返回 401。过期版本返回 409，找不到调用方返回 404。
- 删除保留历史审计、事件和已提交图数据。删除后的 ID 不允许重新创建，避免新身份继承原身份的历史访问权限。替代调用方使用新 ID。
- bootstrap 为部署管理的初始管理员，页面只读，管理 API 不允许编辑或删除。普通管理员可通过页面管理。
- 停用或删除不会撤销已经提交的图事务；已通过写入前权限检查的在途事务仍可完成。尚未写入且无提交回执的事件按当前策略阻止。

## 旧数据迁移

启动时在一个事务中删除旧策略 JSON 的四组范围字段，受影响策略 revision 只增加一次，token 不变。重启后再次核对 revision 未重复增加。迁移前通过 SQLite backup API 备份本地演示数据库，保存于演示目录的 `backups/`。本机 hsql 启动器缺少解释器，未修全局工具安装；没有通过直接修改运行数据库来模拟调用方业务操作。

## 自动验证

| 验证 | 结果及覆盖 |
| --- | --- |
| Rust server 单元/审计迁移 | 12 通过；物理行删除、历史保留、旧 token 失效、删除后不能发 token/复用 ID、个人不能删除、bootstrap 保护、revision 冲突、启用切换、队列复核、旧字段单次迁移 |
| 既有 serve API / 集成 | 92 + 11 通过 |
| 真实 Rust HTTP + 独立 Neo4j | 2 个综合测试通过；无范围字段的调度发布、个人隔离、崩溃回执恢复、断连重启及策略复核 |
| Cargo clippy | CLI serve 全 targets、warnings as errors 通过 |
| 前端 transport | 3 通过；凭据发送边界、DELETE method/revision、删除 ID 重用提示 |
| 前端 lint / typecheck / build | 通过；保留已有 ONNX eval 与大 bundle 构建提示 |
| 最终嵌入页面 | 浏览器真实操作 12 组检查通过，前端 dist、CLI 嵌入及实际 HTTP index 完全一致 |
| 页面布局 | 桌面、1076×986 用户窗口、平板、手机、深色主题检查；用户窗口删除按钮无需横向滚动即可看到 |

页面检查包括新建保存、生效版本、移除字段、token 发放/隐藏/撤销、停用/重新启用、并发保存 409、删除取消与确认、删除行消失及旧 token 401、个人管理页 403、审计独立状态和个人详情。截图中的 `ui_alice_*`、`ui_person_*` 是测试身份，检查完成后均已物理删除。

## 本地演示结果

- 调度事件 `184efb318ec0c9e79ce4891da9b8a2cc0aeb556d569fc2edc5090527dd883512`：正式图 source_a → target_t。
- 调度事件 `5576392d277729ea92ad43eb457423cd2ac09a0dae357c919bbefc7c7395f955`：新版本替换为 source_b → target_t。
- 个人事件 `f630fd6a822939fd31a2b0ffba18f06278f7087d99d9ec7a2cfc489112c98c51`：`parseStatus=succeeded`、`usageStatus=committed`、`lineageStatus=not_requested`。读取 personal_debug，声明写入 target_t；正式图仍为 source_b → target_t，版本不变。
- personal_debug 只形成 TABLE_REFERENCE，未新建正式 M_TABLE。`execution_status=not_observed`，仅证明提交解析。
- 四个演示调用方 bootstrap、demo_admin、demo_person、demo_scheduler 及原有 token 保留。没有将原始凭据写入本任务文档或截图。

## 清理与保留

验证脚本进程已退出，创建的浏览器进程和临时 profile 均无残留；见 `ui-token-policy/browser-cleanup.json`。单独的回归 Neo4j 容器与两个匿名卷已移除，HTTP 测试启动的 Rust 进程已退出。保留用户验收用的 FlowScope 3099、Neo4j 7474/7687 与原有 PostgreSQL。

结果索引：`token-policy-validation.json`、`ui-token-policy/ui-checks.json`。原有基线 lint_cli 五项失败及首批验证边界仍见 `../implementation-result.md`，未把本次针对性检查称为全仓全绿。用户验收由用户继续进行。
