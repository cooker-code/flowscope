# 651353 重试修复与入图优化验证

日期：2026-11-27（Asia/Taipei）。基线 f994d2f6，候选分支 codex/fix-lineage-retry-throughput。实施和自动检查已完成，线上索引已应用，批量二进制尚未部署。

## 线上修复结果

- 09:41 读取 651353：queued，attempts=639，解析成功。其 104 次是 11 月 26 日的早期快照。
- Neo4j 5.27.0 Community，LINEAGE_FACT 共 94,555 条；edge_key 查询无匹配索引，PROFILE 使用 NodeByLabelScan，扫描 94,555 行。
- 已用 CREATE RANGE INDEX IF NOT EXISTS 增加 flowscope_fact_edge、flowscope_fact_scope_active、flowscope_scope_target；三个索引均 ONLINE。首个索引准备约 21.34 秒，说明不能将索引初始化简单塞入原先 8 秒连接预算。
- 原事件 df6114e6-6cae-4404-a502-a315ec4748d3 自动提交，Neo4j committed_at 为 2026-11-27 09:49:43.889+08:00；09:50 事件和审计接口均 committed，attempts=644，reason=null。
- 没有重新受理 SQL、手改 SQLite 状态、删除事件、清空或重建生产图，也没有替换线上二进制。
- 修复后的读取计划为 NodeIndexSeek。前后查询快照和返回行数不同，不用该单次 wall time 做严格提速比。

## 单次图事务前后耗时

同一台 Mac，debug 构建，任务独占 Neo4j 5.26 Community，固定 94,555 条合成背景事实。使用 651353 的完整 SQL 和保存分析，来源改为隔离测试身份。解析图 330 节点/493 边，经 normalize 后为 494 实体/657 事实。每组 3 轮，每轮清理本轮业务图但保留相同背景事实，再依次首次发布和替换版本。

计时为 LineageStore::apply 调用至提交返回，包括规范化，不包括连接初始化、SQLite 排队或 HTTP。

| 场景 | 旧版无事实查询索引 | 旧版仅补索引 | 批量候选及索引 |
| --- | ---: | ---: | ---: |
| 首次发布中位数 | 20.072 秒 | 2.751 秒 | 0.235 秒 |
| 版本替换中位数 | 32.747 秒 | 3.950 秒 | 0.305 秒 |

| 构建/场景 | 最小值 | 最大值 |
| --- | ---: | ---: |
| before / first_publish | 19.902 秒 | 20.697 秒 |
| before / replace_revision | 32.581 秒 | 38.192 秒 |
| index-only / first_publish | 2.540 秒 | 3.313 秒 |
| index-only / replace_revision | 3.560 秒 | 4.499 秒 |
| after / first_publish | 0.206 秒 | 0.591 秒 |
| after / replace_revision | 0.281 秒 | 0.378 秒 |

## HTTP 端到端与短队列

旧版未补索引：首次约 19.38 秒完成；版本替换在 30.09 秒后保持 queued，attempts=1、reason=neo4j_temporarily_unavailable，复现 worker 30 秒限制。

旧版补索引和批量版各测 3 轮，每轮连续提交同一任务的版本 1、2、3，等待全部 committed。每次重置相同测试图；包含完整 HTTP 解析、SQLite 受理、排队、图写入和轮询确认，包含启动后首次使用的初始化成本。轮询间隔约 20ms。

| 指标（各 3 轮中位数） | 旧版仅补索引 | 批量候选及索引 |
| --- | ---: | ---: |
| 第 1 条请求到确认提交 | 3.188 秒 | 0.425 秒 |
| 第 3 条请求到确认提交 | 11.327 秒 | 1.037 秒 |
| 连续 3 条全部完成 | 11.486 秒 | 1.208 秒 |
| 短队列折算处理速度 | 15.671 条/分钟 | 149.003 条/分钟 |

这些是小样本、本地 loopback、debug 与合成背景事实结果。包含首次计划编译和缓存波动，不能推断生产长期容量或尾延迟；线上只应用了索引，尚未测批量候选在生产的耗时。审计页面 ms 只反映解析/受理阶段，不能用于声称入图提速。

## 正确性与质量检查

| 检查 | 已核实结果 |
| --- | --- |
| CLI serve 单元测试 | 202 passed，包含重试阶段持久化、退避、完成后原因清除和原始消息不泄漏 |
| storage lineage | 4 passed，含 3 项纯测试和实际 Neo4j 综合契约 |
| Neo4j 综合契约 | 首次发布、替换、同事件重放、同版本不同内容冲突、旧版本、共享来源、撤回、并发版本、后期约束失败后回滚均通过 |
| 宽表分批 | 130 列，实体及事实跨越 256 条边界；两版发布、精确端点计数、重放和撤回通过 |
| CLI HTTP 黑盒 | 2 passed，包含调度/个人、停用与撤销、服务重启、回执先于授权复查和待处理事件恢复 |
| 原始解析快照 | old/index-only/batched 均提交 657 条当前事实，回执可读；每轮核对事实数 |
| 个人表引用 | 已有 M_TABLE、未注册目标和无完整限定名引用均通过；不增加正式物理表或替换正式关系 |
| Clippy | storage + CLI serve，全 targets，-D warnings 通过 |
| 格式及补丁 | cargo fmt --all -- --check；git diff --check 通过 |

执行命令口径：cargo test -p flowscope-storage -p flowscope-cli --features serve --lib；显式启用 tests/lineage.rs、tests/throughput.rs 的隔离测试以及 CLI tests/lineage_http.rs。所有测试从当前任务工作区构建。该阶段未改变解析器、前端组件或公共 AnalyzeResult，后续页面及发布检查记录见下文。

## 个人使用统计核对

已在线上只读执行“昨天（2026-11-26，Asia/Taipei）谁提交了引用哪些表的 SQL”查询，当前个人 QUERY_ACTOR=0，结果为空；这不代表没有人在数据库查询，只表明尚无这类个人事件。相同查询在隔离图返回 person-1 对已注册 hive.dw.a 和未知表的两组记录，各 1 次，重试没有重复计数。详见 personal-usage-query.json 和正式指南。

## 资源清理

- 有效 HTTP 压测启动的 7 个服务进程全部正常退出（exitCode=0）并 wait 回收。HTTP 集成测试的服务进程也由 Drop/stop 回收。
- 两个任务容器、四个匿名数据/日志卷已删除；17687、17688、17474、17475 端口均已释放；进程表没有本轮遗留服务。
- 浏览器会话已解绑，保留用户原标签页；没有创建或结束用户的服务器登录会话。
- 临时二进制和一次性构建/修复脚本已删除；复现脚本、真实输入及测量 JSON 保留在 task/research。

## 验证限制与交付状态

- 历史每次重试的具体异常未保存，不能逐次还原。已通过实际扫描计划、真实规模超时复现及相同事件加索引后自动成功确认本轮根因。
- 右侧终端可读取，Computer Use 不允许控制 Codex app；没有绕过此限制。未读取服务器日志或执行部署/重启。
- 批量代码已实现并隔离验证；生产已生效的改动为三个索引。未执行 Linux 打包上传、生产二进制替换、push 或 MR。
- 用户已确认将入图优化、审计页修改一起提交和打包上传，提交后继续执行发布；生产部署另行处理。

## 证据文件

- research/neo4j-readonly.json、neo4j-projection-before.json、neo4j-index-repair.json
- research/production-recovered-api.txt
- research/throughput-before.json、throughput-index-only.json、throughput-after.json、throughput-summary.json
- research/http-throughput.json、http-summary.json、http-benchmark.py
- research/personal-usage-query.json、resource-cleanup.json
- bug-analysis.md（根因及已落实的预防机制）

## 审计页调整及发布检查（2026-11-27 补充）

- 已移除“调用方 / 原因”表头及对应数据单元格，空状态 colspan=14。
- app TypeScript 检查、AuditPage 11 项现有测试、ESLint、Prettier 检查通过。
- yarn build 与重新嵌入页面的 CLI serve 构建通过；已用真实本地服务和浏览器验证表头/数据行各 14 列、空状态跨 14 列、入图原因弹窗仍可用。
- 页面测试服务、标签页及临时数据库均已清理。
- 本次发布补跑核心库单元测试：1750 passed、0 failed。
- 用当前源码的本机 CLI 运行主仓库现有 test-sql：18 passed、0 failed；9 个样本有既有警告。
- 发布源为本工作区 codex/fix-lineage-retry-throughput，沿用已验证的入图、HTTP 恢复及安全边界测试结果。
