# SQL 解析错误归因报告
- **CSV 文件**: `20789063-1.csv`
- **SQL 总数**: 38
- **错误总数**: 39

## 汇总

| 排名 | 错误类型 | 数量 | 占比 | 修复方法 |
|------|----------|-----:|-----:|----------|
| 1 | FROM/JOIN 子句尾部多余逗号 | 17 | 44% | 删除 SELECT 列表、FROM 子句或 JOIN 列表末尾的多余逗号 |
| 2 | 三段式表名 catalog.database.table | 9 | 23% | 将三段式 `catalog.db.table` 改为两段式 `db.table`，或注册 catalog 别名 |
| 3 | Jinja2 双花括号模板变量 {{...}} | 5 | 13% | 执行前先用正则替换 `{{...}}` 占位符，或将模板变量改为 `${variable}` HiveQL 原生语法，或将 `template_mode` 改为支持 Jinja2 的模式 |
| 4 | 子查询缺少别名 / 嵌套子查询 AS 解析失败 | 5 | 13% | 确保每个子查询都有别名，检查嵌套层数是否过深；复杂 CTE 可拆分为多个 WITH 块或独立临时视图 |
| 5 | FROM 子句位置出现 CASE WHEN | 2 | 5% | 检查 CASE WHEN 前方是否缺少 FROM 关键字，或将 CASE WHEN 移到 SELECT 列表而非 FROM 子句 |
| 6 | 数组下标访问语法 array[n] | 1 | 3% | 改用 `array_element(split(col,'-'), 1)` 函数，或先用 LATERAL VIEW POSEXPLODE 展开数组再过滤位置 |

## 详细说明

### 1. FROM/JOIN 子句尾部多余逗号（17 个，占 44%）

**根因**：SELECT 列表或 FROM/JOIN 子句末尾存在多余逗号，如 `SELECT a, b,
FROM ...` 或 `JOIN t1, t2,
WHERE ...`

**修复**：删除 SELECT 列表、FROM 子句或 JOIN 列表末尾的多余逗号

**受影响任务示例**：百科多种预约方式统计, 系统课指定期次甩班次数, 体验课转化明细

### 2. 三段式表名 catalog.database.table（9 个，占 23%）

**根因**：使用了 Spark/Trino 风格的三段式命名 `catalog.db.table`，HiveQL 解析器只支持两段 `db.table`

**修复**：将三段式 `catalog.db.table` 改为两段式 `db.table`，或注册 catalog 别名

**受影响任务示例**：英语中价课用户退款与沟通覆盖, 英语quiz三星-明细, 阶段总结各U和累计覆盖情况

### 3. Jinja2 双花括号模板变量 {{...}}（5 个，占 13%）

**根因**：SQL 包含 `{{variable}}` 或 `{{expr as alias}}` Jinja2 风格模板占位符，解析器遇到 `{` 时无法识别为合法 SQL 表达式

**修复**：执行前先用正则替换 `{{...}}` 占位符，或将模板变量改为 `${variable}` HiveQL 原生语法，或将 `template_mode` 改为支持 Jinja2 的模式

**受影响任务示例**：banner数据, 体验课用户转化后主动咨询体验课老师数据, 落地页数据

### 4. 子查询缺少别名 / 嵌套子查询 AS 解析失败（5 个，占 13%）

**根因**：子查询后接 AS 时解析器认为此处应是 joined table，常见于深度嵌套子查询、复杂 CTE，或子查询之间缺少逗号分隔

**修复**：确保每个子查询都有别名，检查嵌套层数是否过深；复杂 CTE 可拆分为多个 WITH 块或独立临时视图

**受影响任务示例**：腾讯渠道投放各组后转数据, 售卖页素材迭代-abtest, 阶段测指标（运营汇报用）

### 5. FROM 子句位置出现 CASE WHEN（2 个，占 5%）

**根因**：CASE WHEN 表达式出现在解析器期望表名的位置，通常是子查询内部缺少 FROM 关键字，或外层逗号分隔导致 CASE 被误识别为 joined table

**修复**：检查 CASE WHEN 前方是否缺少 FROM 关键字，或将 CASE WHEN 移到 SELECT 列表而非 FROM 子句

**受影响任务示例**：资源位曝光量, 体验课用户标签收集数据

### 6. 数组下标访问语法 array[n]（1 个，占 3%）

**根因**：使用了 `split(col,'-')[1]` 等内联数组下标访问，HiveQL 解析器在函数调用括号内不支持 `[index]` 语法

**修复**：改用 `array_element(split(col,'-'), 1)` 函数，或先用 LATERAL VIEW POSEXPLODE 展开数组再过滤位置

**受影响任务示例**：国内周报P1

