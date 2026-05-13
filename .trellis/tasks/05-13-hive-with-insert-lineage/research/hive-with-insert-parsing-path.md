# Research: Hive WITH...INSERT OVERWRITE Parsing Path

- **Query**: 定位 flowscope-core 引擎中 Hive 方言 `WITH ... INSERT OVERWRITE` 语句的解析路径，找出目标表变成孤立节点的原因
- **Scope**: internal
- **Date**: 2026-05-13

## Findings

### Files Found

| File Path | Description |
|---|---|
| `crates/flowscope-core/src/analyzer/statements.rs` | DML 语句分析入口，含 `analyze_statement` 和 `analyze_insert` |
| `crates/flowscope-core/src/analyzer/visitor.rs` | `LineageVisitor::visit_query` 和 `visit_set_expr`，处理 CTEs + SetExpr::Insert |
| `crates/flowscope-core/src/analyzer/helpers/query.rs` | `classify_query_type` 函数，返回 "WITH" |
| `crates/flowscope-core/src/analyzer/query.rs` | `analyze_query` 入口，委托给 `LineageVisitor::visit_query` |
| `crates/flowscope-core/src/analyzer/input.rs` | SQL 文本拆分为 `StatementInput`，无特殊 Hive 处理 |
| `~/.cargo/registry/src/.../sqlparser-0.61.0/src/ast/dml.rs` | `Insert` struct，含 `overwrite: bool` 和 `source: Option<Box<Query>>` 字段 |
| `~/.cargo/registry/src/.../sqlparser-0.61.0/src/parser/mod.rs` | sqlparser 解析器，`parse_query` 和 `parse_insert` |
| `crates/flowscope-core/tests/lineage_engine.rs` | 所有 lineage 测试，无 Hive INSERT OVERWRITE 测试 |

### Code Patterns

#### 1. sqlparser 如何解析 `WITH ... INSERT OVERWRITE`

在 `sqlparser-0.61.0/src/parser/mod.rs:622`，顶层 `WITH` 关键字被路由到 `parse_query()`：

```rust
Keyword::SELECT | Keyword::WITH | Keyword::VALUES | Keyword::FROM => {
    self.prev_token();
    self.parse_query().map(Into::into)
}
```

`parse_query()` 在 `mod.rs:13280` 先解析 WITH 子句，然后检测 INSERT：

```rust
pub fn parse_query(&mut self) -> Result<Box<Query>, ParserError> {
    let with = if self.parse_keyword(Keyword::WITH) {
        Some(With { cte_tables: ... })
    } else { None };

    if self.parse_keyword(Keyword::INSERT) {
        Ok(Query {
            with,                                          // CTE 在这里
            body: self.parse_insert_setexpr_boxed(...)?,  // INSERT 在 body 里
            ...
        }.into())
    }
```

生成的 AST 是：
```
Statement::Query(Query {
    with: Some(With { cte_tables: [new_device, ...] }),
    body: SetExpr::Insert(Statement::Insert {
        overwrite: true,
        table: "dw_conan_dwd.dwd_conan_user_order_da",
        source: Some(Query { body: SetExpr::Select(...) }),
        partitioned: Some(...),  // PARTITION(dt=...)
        has_table_keyword: true, // TABLE 关键字
        ...
    }),
})
```

**关键点**：`WITH ... INSERT OVERWRITE` 生成 `Statement::Query`，**不是** `Statement::Insert`。

#### 2. analyze_statement 的分支路由

在 `statements.rs:97`，`Statement::Query` 走进 `analyze_query` 路径：

```rust
Statement::Query(query) => {
    // dbt 模式下设置 model name；否则 sink_target_id = None
    let sink_target_id: Option<Arc<str>> = if let Some(ref name) = normalized_model_name {
        ...
    } else {
        ctx.ensure_output_node_with_model(None);  // 创建 OUTPUT 节点，不是 Table 节点
        None
    };

    self.analyze_query(&mut ctx, query, sink_target_id.as_deref());
    classify_query_type(query)  // 返回 "WITH"
}

Statement::Insert(insert) => {
    self.analyze_insert(&mut ctx, insert);
    "INSERT".to_string()
}
```

非 dbt 模式下，`Statement::Query` 的 `sink_target_id = None`，所以传入 `analyze_query` 的 `target_node = None`。

#### 3. visit_set_expr 如何处理 SetExpr::Insert（根本原因）

在 `visitor.rs:601`，当 `visit_query` 处理 `query.body = SetExpr::Insert` 时：

```rust
SetExpr::Insert(insert_stmt) => {
    let Statement::Insert(insert) = insert_stmt else {
        return;
    };
    let target_name = insert.table.to_string();
    self.add_source_table(&target_name);  // ← 把目标表当SOURCE来添加！
}
```

**这是根本原因**：`SetExpr::Insert` 分支调用的是 `add_source_table`（把表当作数据来源），而不是像 `analyze_insert` 那样创建目标节点并建立边。

#### 4. analyze_insert 的正确路径（仅用于 Statement::Insert）

在 `statements.rs:492`，只有直接解析为 `Statement::Insert` 时才走此路径：

```rust
pub(super) fn analyze_insert(&mut self, ctx: &mut StatementContext, insert: &ast::Insert) {
    let target_name = insert.table.to_string();
    let canonical = self.normalize_table_name(&target_name);

    // 创建目标 Table 节点
    let target_id = ctx.add_node(Node {
        node_type: NodeType::Table,
        ...
    });

    self.tracker.record_produced(&canonical, ctx.statement_index);

    // 分析 source（WITH cte 在 source 里时才能正确识别 CTE）
    if let Some(ref source_body) = insert.source {
        self.analyze_query(ctx, source_body, Some(&target_id));
    }
}
```

注释明确说明：`analyze_query`（非 `analyze_query_body`）使 `INSERT … WITH cte AS (…) SELECT …` 的 CTE 能被正确识别。

但是 `WITH ... INSERT OVERWRITE` 生成的 AST 不是 `Statement::Insert`，所以永远不会走到这里。

#### 5. CTE 的处理路径

在 `visitor.rs:520`，`visit_query` 正确处理 `WITH` 子句中的 CTE：

```rust
fn visit_query(&mut self, query: &Query) {
    if let Some(with) = &query.with {
        for cte in &with.cte_tables {
            // 创建 CTE 节点，注册到 ctx.cte_definitions
            ...
        }
        // 分析每个 CTE 的 query body
        for (cte, (_, cte_id)) in with.cte_tables.iter().zip(cte_ids.iter()) {
            cte_visitor.visit_query(&cte.query);
        }
    }
    self.visit_set_expr(&query.body);  // body = SetExpr::Insert → 走错误分支
}
```

CTE 节点本身会被正确创建，但 `visit_set_expr` 处理 `SetExpr::Insert` 时用 `add_source_table` 而不是正确的 insert 分析逻辑。

#### 6. statement_type 字段

`classify_query_type` 对有 `with` 的查询返回 `"WITH"`，无论 body 是什么：

```rust
pub fn classify_query_type(query: &Query) -> String {
    if query.with.is_some() {
        "WITH".to_string()
    } else { ... }
}
```

所以最终结果：
- `statementType = "WITH"`（不是 "INSERT"）
- `nodes` 包含：CTE 节点 + 目标表节点（作为 source 创建，无入边）
- `edges` 为 0（因为 add_source_table 需要 target_node，但 target_node = None）

#### 7. Hive 方言的特殊 SET 语句

测试文件里的 `SET mapreduce.reduce.memory.mb=4096;` 等语句会被解析为 `Statement::Set`，在 `statements.rs:228` 返回 `"SET"` 类型，不影响后续的 WITH...INSERT 解析。

### Fixture 检查

- `tests/fixtures/` 目录下无 `hive` 子目录
- 现有方言目录：`bigquery`, `generic`, `mysql`, `oracle`, `postgres`, `redshift`, `schemas`, `snowflake`, `templated`
- **没有任何 Hive INSERT OVERWRITE 的 fixture SQL**

### 现有 INSERT+CTE 测试覆盖

`lineage_engine.rs:3408` 的 `insert_with_cte_source` 测试使用 `WITH ... INSERT INTO`（无 OVERWRITE），走的是 Oracle 兼容路径（`Statement::Query` body = `SetExpr::Insert`）。

查看 Oracle 相关测试（`lineage_engine.rs:11257`）：oracle 的 `INSERT ... WITH cte AS (...) SELECT` fixture 通过了，但这些是 `INSERT` 在前、`WITH` 在后，生成 `Statement::Insert { source: Query { with: Some(With{...}) } }` 的 AST，走的是 `analyze_insert` + `insert.source` 里包含 CTE 的正确路径。

**关键区别**：
- Oracle: `INSERT INTO t WITH cte AS (...) SELECT ...` → `Statement::Insert`，source 里有 WITH
- Hive: `WITH cte AS (...) INSERT OVERWRITE TABLE t` → `Statement::Query`，body 是 `SetExpr::Insert`

## Caveats / Not Found

1. 未验证 Hive 方言（`HiveDialect`）和 `GenericDialect` 在 sqlparser 里的具体差异——`overwrite` 字段同时支持两者，但解析路径相同
2. 测试文件里 `insert_with_cte_source`（`lineage_engine.rs:3408`）使用 `Dialect::Generic`，但实际上 `WITH...INSERT INTO` 也走 `Statement::Query` 路径，这个测试能过是因为 `add_source_table` 最终把 `users` 注册进去了——但 users 在此情况下 edges=0，测试只检查 tables 是否存在，未检查边
3. `visitor.rs:601` 的 `SetExpr::Insert` 分支是已知的 "简化" 处理（只 add_source_table），这对 `FROM (INSERT ...)` 子查询有意义，但对顶层 `WITH...INSERT` 是错误的
