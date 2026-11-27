# 实施与验证计划

## 启动条件

- [x] 用户同意建任务和规划；独立工作区已建立。
- [x] 已取得真实记录及只读 HTTP 性能基线。
- [x] prd.md、design.md、implement.md 已完成。
- [x] 用户审查并同意实施，已执行 task.py start。

## 实施顺序

1. 主会话加载 trellis-before-dev 和 CLI/APP 相关规范，直接实施、检查，不派发子 Agent。
2. 提取真实 652177 SQL 作为回归，复用最终类型分类，覆盖 WITH 的 SELECT 和两种 INSERT。
3. 建立可重复的大数据查询样本，记录原 SQL 查询计划与耗时。
4. 实现单例保留设置、管理员 API、校验、持久化及新旧数据库测试。
5. 实现监听后后台分批清理、保存触发、周期执行、写锁退让和停止；协调类型校正。
6. 按查询计划落实复合索引与批量元数据读取，保持筛选、精确计数及一致快照。
7. 在 PolicyPage 指定位置添加表单，处理独立草稿、保存、错误及窄屏布局。
8. 运行针对性测试、前端构建、CLI 嵌入及临时服务集成，修复失败。
9. trellis-check 自查；修复后按 trellis-break-loop 分析，trellis-update-spec 沉淀审计契约。线上发布不与本地完成混淆。

## 验证矩阵

| 检查 | 要发现的失败 | 后续行动 |
| --- | --- | --- |
| 真实 WITH、INSERT 和配置前缀 | 按首关键词误分类 | 修共享审计映射 |
| 默认、重开、非法输入、鉴权 | 默认遗漏、失效、越权 | 修迁移或 API |
| cutoff 前/等于/后、queued、无事件表 | 错删有效日志或任务证据 | 修条件与事务 |
| 写锁、大量历史、停止信号 | 启动阻塞、占锁、退出残留 | 完善批次和停止 |
| 计数/分页/状态/所有权组合 | 结果错位或跨调用方泄露 | 统一读快照与状态规则 |
| 大数据计划与耗时对比 | 索引无效、全量排序、N+1 | 按证据优化查询 |
| 表单保存/重载/失败/窄屏 | 假成功、草稿互扰、溢出 | 修状态与布局 |
| 构建、嵌入、启动 | 服务旧 bundle 或阻塞 | 按构建依赖修复 |
| 进程/浏览器/临时目录 | 验证资源残留 | 仅清理本轮资源 |

## 验证命令与环境

- cargo test -p flowscope-cli --features serve，先按审计/保留/lineage 模块过滤。
- cargo fmt --all -- --check。
- cargo clippy -p flowscope-cli --features serve -- -D warnings。
- yarn workspace @pondpilot/flowscope-app test，覆盖相关 PolicyPage/AuditPage。
- yarn workspace @pondpilot/flowscope-app typecheck。
- yarn workspace @pondpilot/flowscope-app build。
- 按项目要求同步嵌入资产，再 cargo build -p flowscope-cli --features serve。
- 用本轮独立临时数据库与端口启动服务，验证 API、清理和页面，结束后核实进程退出。

若生成 Playwright 脚本，启动浏览器后的上下文、操作和断言放入 try/finally；嵌套 finally 确保 context.close 失败仍等待 browser.close。之后核实进程退出；系统 Chrome 还比较本轮临时克隆。复用用户浏览器只释放连接，不关闭用户窗口。

## 证据

- research/audit-652177.json：真实记录、SQL 和解析分类，不含访问 token。
- research/online-query-baseline.json：只读查询耗时、总数和 7 天 cutoff。

## 风险文件

- audit.rs / mod.rs：维护协调、启动顺序、索引构建成本。
- lineage_policy.rs / lineage.rs：鉴权与状态，不能改变正式入图和幂等语义。
- PolicyPage.tsx：全局设置不能误提交调用方草稿。

远端部署、历史数据实际删除和本地验证结果分别记录。

## 实际结果

实现和针对性验证已完成，耗时、范围、跳过项与资源清理见 verification.md。线上未部署。
