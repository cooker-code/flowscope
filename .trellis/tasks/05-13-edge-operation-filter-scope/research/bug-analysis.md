# Research: Bug Analysis — Edge Operation Type & Filter Scope

- **Query**: Two bugs in `dwd_conan_user_order_da.sql` parsing: (1) main table edge gets JOIN operation type; (2) `a1` node carries wrong scope's filters
- **Scope**: internal
- **Date**: 2026-05-13

---

## Bug 1: 主表边被打上 JOIN operation 类型

### 根本原因

`ctx.last_operation` 是一个全局（statement 级别）的可变字段，没有在主表处理完之后清零。

**精确触发路径**：

#### 1. `visitor.rs` `visit_table_with_joins`（第 642-663 行）

```rust
fn visit_table_with_joins(&mut self, table_with_joins: &TableWithJoins) {
    self.visit_table_factor(&table_with_joins.relation);  // ← 主表，此时 last_operation = None
    for join in &table_with_joins.joins {
        let (join_type, join_condition) = Analyzer::convert_join_operator(&join.join_operator);
        self.ctx.current_join_info.join_type = join_type;         // ← 设置 JOIN info
        self.ctx.current_join_info.join_condition = join_condition;
        self.ctx.last_operation = Analyzer::join_type_to_operation(join_type); // ← 第 648 行，设置 last_operation
        self.visit_table_factor(&join.relation);                  // ← 处理 JOIN 表
        // 处理完成后清零
        self.ctx.current_join_info.join_type = None;   // ← 第 660 行
        self.ctx.current_join_info.join_condition = None; // ← 第 661 行
        // ❌ 但 last_operation 没有被清零！
    }
}
```

**第 660-661 行只清零了 `current_join_info`，没有清零 `ctx.last_operation`。**

#### 2. `query.rs` `create_source_edge`（第 417-447 行）

```rust
pub(super) fn create_source_edge(
    &mut self,
    ctx: &mut StatementContext,
    source_id: &Arc<str>,
    target_node: Option<&str>,
) {
    // ...
    ctx.add_edge(Edge {
        // ...
        operation: ctx.last_operation.as_deref().map(Into::into),  // ← 第 436 行，直接读 last_operation
        join_type: ctx.current_join_info.join_type,
        join_condition: ctx.current_join_info.join_condition.as_deref().map(Into::into),
        // ...
    });
}
```

#### 3. 为何主表（FROM 第一个）也有 operation

以 `dwd_conan_user_order_da.sql` 为例：

```
FROM new_device           ← 主表，visit_table_factor 调用时 last_operation = None，边正确
LEFT JOIN ...             ← 设置 last_operation = "LEFT_JOIN"，current_join_info.join_type = Left
...                       ← join 处理完，清零 current_join_info，但 last_operation = "LEFT_JOIN" 残留
```

当下一个 `TableWithJoins`（不同的 FROM 子句项）出现时，其主表 `visit_table_factor` 读到的 `last_operation` 已经是上一个 JOIN 留下的值。

或者，在**派生表**（Derived）分支（visitor.rs 第 736-738 行）：

```rust
if let Some(outer_target) = self.target_node.as_deref() {
    self.analyzer
        .create_source_edge(self.ctx, &node_id, Some(outer_target));
}
```

派生表 `a1` 在处理完内部 JOIN 之后直接调用 `create_source_edge`，此时 `ctx.last_operation` 还持有内部 JOIN 留下的值（如 `"LEFT_JOIN"`）。这就是为什么 `a1` 的边也显示 `operation: "LEFT_JOIN"`。

### 关键函数和行号汇总

| 文件 | 行号 | 关键点 |
|------|------|--------|
| `visitor.rs` | 642-663 | `visit_table_with_joins` — 设置 `last_operation` 但未清零 |
| `visitor.rs` | 648 | `self.ctx.last_operation = join_type_to_operation(join_type)` |
| `visitor.rs` | 660-661 | 只清零 `current_join_info`，漏清 `last_operation` |
| `visitor.rs` | 736-738 | 派生表在 subquery 分析后直接调用 `create_source_edge`，继承了残留 `last_operation` |
| `query.rs` | 417-447 | `create_source_edge` — 第 436 行无条件读 `ctx.last_operation` |

### 修复方向

1. **最小修复**：在 `visit_table_with_joins` 的 JOIN 循环结束时，同步清零 `ctx.last_operation`（在第 661 行后加 `self.ctx.last_operation = None;`）。
2. **更彻底**：`create_source_edge` 的调用方应区分"FROM 主表"和"JOIN 表"，主表调用时明确传 `operation = None`，而不是依赖全局状态。当前的 `add_source_table` → `create_source_edge` 调用链没有任何方式表达"这是主表不要 operation"的语义。
3. **派生表边**：`visitor.rs` 第 736-738 行的 `create_source_edge` 调用发生在 `derived_visitor.visit_query(subquery)` 之后，subquery 内部的 JOIN 可能已经污染了 `last_operation`。应在调用 `create_source_edge` 前先保存并临时清零 `last_operation`，调用后恢复。

---

## Bug 2：`a1` 节点携带错误 scope 的 FILTERS

### 根本原因

`pending_filters` 以**canonical name（字符串）**为键，而非 node ID。两个 `a1` 派生表节点的 `qualified_name` 都是 `"a1"`（见 visitor.rs 第 707 行），所以它们在 `canonical_index` 里共用同一个键，导致 `apply_pending_filters` 把所有 `a1` 的 filter 写入到每一个名为 `a1` 的节点。

### 精确触发路径

#### 1. 派生表节点的 `qualified_name` 设置（visitor.rs 第 698-711 行）

```rust
let derived_node_id = alias_name.as_ref().map(|name| {
    let scoped_name = format!(
        "statement_{}::scope_{}::{}",
        self.ctx.statement_index, derived_scope_id, name
    );
    self.ctx.add_node(Node {
        id: generate_node_id("derived", &scoped_name),  // ← ID 包含 scope，是唯一的
        node_type: NodeType::Cte,
        label: name.clone().into(),
        qualified_name: Some(name.clone().into()),       // ← 第 707 行：qualified_name = "a1"（无 scope）
        // ...
    })
});
```

节点 ID 是 scope 隔离的（`generate_node_id("derived", "statement_0::scope_1::a1")`），但 **`qualified_name` 只是裸名 `"a1"`**，没有任何 scope 信息。

#### 2. `add_filter_for_table` 用 canonical name 做键（context.rs 第 336-349 行）

```rust
pub(crate) fn add_filter_for_table(
    &mut self,
    canonical: &str,         // ← 这里传入的是解析结果，对于派生表是 "a1"
    expression: String,
    clause_type: FilterClauseType,
) {
    self.pending_filters
        .entry(canonical.to_string())
        .or_default()
        .push(FilterPredicate { expression, clause_type });
}
```

#### 3. `apply_pending_filters` 用 `qualified_name` 匹配（query.rs 第 1341-1375 行）

```rust
// 构建 canonical_index：key = node.qualified_name
for (i, node) in ctx.nodes.iter().enumerate() {
    id_index.insert(node.id.clone(), i);
    if let Some(ref qn) = node.qualified_name {
        canonical_index.entry(qn.clone()).or_default().push(i);  // ← "a1" → [idx_cte_a1, idx_insert_a1]
    }
}

// Apply canonical-keyed filters：把 "a1" 的所有 filters 写入所有 qualified_name == "a1" 的节点
for (table_canonical, filters) in canonical_pending {
    if let Some(indices) = canonical_index.get(table_canonical.as_str()) {
        for &idx in indices {
            ctx.nodes[idx].filters.extend(filters.clone());  // ← 两个 a1 节点都收到了全部 filter
        }
    }
}
```

由于 `canonical_index` 把两个 `a1` 节点（CTE 内的和 INSERT 部分的）都收录在 `"a1"` 这个键下，两个节点都会收到本属于另一个作用域的 filter。

#### 4. 为何 filter 能被正确分流到 `a1` 的 canonical name

filter 的路由（expression.rs 第 562-594 行）：

- 对于带限定符的列引用（如 `a1.rk = 1`），`resolve_instance_node_id` 能找到正确的实例 node_id，走 `pending_instance_filters`（scope 隔离，正确）
- 对于不带限定符的列引用（如 `rk = 1`），fallback 到 `resolve_filter_column_table`，返回 canonical name `"a1"`，走 `pending_filters`（不隔离，bug）

因此 **当 WHERE 条件列没有用 `a1.` 前缀限定时，filter 被路由到 `pending_filters["a1"]`，`apply_pending_filters` 把它广播给所有 qualified_name = "a1" 的节点**。

### 关键函数和行号汇总

| 文件 | 行号 | 关键点 |
|------|------|--------|
| `visitor.rs` | 707 | 派生表节点的 `qualified_name` 设置为裸 alias 名（无 scope） |
| `visitor.rs` | 698-704 | 节点 ID 含 scope，但 qualified_name 不含 |
| `context.rs` | 336-349 | `add_filter_for_table` — key 是 canonical name（字符串） |
| `query.rs` | 1341-1350 | `apply_pending_filters` 用 `qualified_name` 建 canonical_index |
| `query.rs` | 1369-1375 | 同一 canonical name 的所有节点都收到相同的 filter |
| `expression.rs` | 562-594 | 无限定符的列引用路由到 canonical pending_filters（非 instance） |

### 修复方向

1. **修改派生表节点的 `qualified_name`**（visitor.rs 第 707 行）：将 `qualified_name` 改为包含 scope 信息的唯一串，如 `format!("statement_{}::scope_{}::{}", stmt_idx, scope_id, name)`，与 node ID 中使用的 `scoped_name` 保持一致。同时 `add_filter_for_table` 的调用方需传相同的 scoped name 作为 canonical。
2. **让 filter 路由优先走实例路径**：在 `capture_filter_predicates`（expression.rs）中，对于只有一个作用域内的 `a1` 的情况，通过 `resolve_alias_instance` 拿到具体 node_id，直接调用 `add_filter_for_instance`，绕开 canonical fallback。
3. **根本修复**：`pending_filters` 的 key 应该是 node_id（`Arc<str>`），而非 canonical name string，与 `pending_instance_filters` 统一成同一个 map。两者现在的区别是"self-join 广播 vs 精确路由"，但对于派生表来说 canonical name 本来就不能唯一识别节点。

---

## 两个 Bug 的关系

两个 bug **相互独立**，触发路径完全不同：

- Bug 1 触发点：`visit_table_with_joins` 的 `last_operation` 未清零，影响 `create_source_edge` 的 `operation` 字段。
- Bug 2 触发点：`apply_pending_filters` 用 `qualified_name` 做 canonical 匹配，派生表节点的 `qualified_name` 不含 scope 导致跨 scope 广播。

可以分开独立修复，互不影响。

---

## 文件位置速查

| 文件 | 路径 |
|------|------|
| visitor.rs | `crates/flowscope-core/src/analyzer/visitor.rs` |
| query.rs | `crates/flowscope-core/src/analyzer/query.rs` |
| context.rs | `crates/flowscope-core/src/analyzer/context.rs` |
| expression.rs | `crates/flowscope-core/src/analyzer/expression.rs` |
| response.rs | `crates/flowscope-core/src/types/response.rs` |
