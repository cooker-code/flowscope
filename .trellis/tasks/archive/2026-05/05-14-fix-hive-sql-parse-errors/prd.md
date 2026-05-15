# PRD: 修复 Hive SQL 批量解析错误

## 目标

批量解析 `/warehouse/conan` 目录 931 个 Hive SQL 文件，消除因方言配置和非 SQL 指令导致的 77 条 `success=false` 审计记录。

## 背景 / 已知事实

- flowscope 服务器以 `--dialect generic`（默认）运行，但 conan SQL 是 Hive 方言
- 审计库 `/tmp/flowscope-audit.db`，当前 success=0 共 77 条
- 分析出 5 类根因：

| 类别 | 数量 | 根因 |
|------|------|------|
| A | 69 条 | Hive SET 引擎配置指令（`set spark.xxx=...`）非 SQL |
| B | 11 条 | Hive ADD FILE/JAR 命令（`add file xxx.py`）非 SQL |
| C | 2 条  | DDL 内嵌 `COMMENT` 关键字，需 Hive 方言 |
| G | 6 条  | Generic 方言不支持 GROUP BY/HAVING 引用别名 |
| E/F/H | 剩余 | SELECT * 无 schema（可接受），列歧义（SQL 质量问题），类型推断差异 |

## 修复方案

### Fix 1：重启服务器为 Hive 方言
- 杀掉当前 Generic 方言进程（pid 55940）
- 以 `--dialect hive` 重启

### Fix 2：批量解析脚本预处理 SET/ADD 行
- 发送 SQL 前，过滤掉以 `set ` / `add file` / `add jar` / `add archive` 开头的行（大小写不敏感）
- 保留注释和空行，不影响行号语义

### 不修复项
- E（SELECT * 无 schema）：分析结果已有，属告警级别可接受
- F（列名歧义）：SQL 代码质量问题，需业务侧加表前缀
- H（类型推断差异）：不影响血缘提取

## 验收标准

1. 清空审计日志后，重新解析 931 个文件
2. `success=0` 记录数 ≤ 20（仅剩 E/F/H 类无法消除的）
3. `success=1` 且 `sql_type IS NOT NULL` 比例 ≥ 95%
