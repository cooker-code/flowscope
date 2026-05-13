# Research: CTE Alias Scope Collision — Scope Mechanism Analysis

- **Query**: 在 flowscope-core 引擎中，找出同名别名在不同作用域被合并成同一节点的根本原因
- **Scope**: internal
- **Date**: 2026-05-13

---

## 1. 节点 ID 生成机制

### `generate_node_id` — 基础函数
**文件**: `crates/flowscope-core/src/analyzer/helpers/id.rs:6-13`

```rust
pub fn generate_node_id(node_type: &str, name: &str) -> Arc<str> {
    let mut hasher = DefaultHasher::new();
    node_type.hash(&mut hasher);
    name.hash(&mut hasher);
    let hash = hasher.finish();
    format!("{node_type}_{hash:016x}").into()
}
```

**只哈希 (node_type, name)，不含任何作用域信息**。相同类型 + 相同名字 → 永远相同 ID。

### `generate_statement_scoped_node_id` — 语句级隔离
**文件**: `crates/flowscope-core/src/analyzer/helpers/id.rs:42-48`

```rust
pub fn generate_statement_scoped_node_id(
    node_type: &str,
    statement_index: usize,
    name: &str,
) -> Arc<str> {
    generate_node_id(node_type, &format!("statement_{statement_index}::{name}"))
}
```

加入了 `statement_index`，但**没有加入 CTE 嵌套深度、父 CTE 名字或词法 scope_id**。

---

## 2. CTE 节点注册 — `visit_query`

**文件**: `crates/flowscope-core/src/analyzer/visitor.rs:519-579`

```
visitor.rs:534-547  — 为每个 WITH CTE 创建节点
visitor.rs:535-539  — 调用 generate_statement_scoped_node_id("cte", statement_index, &cte_name)
visitor.rs:553-555  — 插入 ctx.cte_definitions: HashMap<String, Arc<str>>
```

关键点：`cte_definitions` 是 **`StatementContext` 的全局 HashMap**，key 是裸名（如 `"new_device"`）。当 `visit_query` 被递归调用处理嵌套 CTE 时（例如 CTE 内部还有 WITH 子句），新的 CTE 定义会直接写入同一个 `cte_definitions` 映射，**覆盖或污染已有条目**。

---

## 3. 派生表（Derived Table）节点注册 — `visit_table_factor`

**文件**: `crates/flowscope-core/src/analyzer/visitor.rs:676-738`

```
visitor.rs:692-706  — 为 FROM (...) AS <alias> 创建派生表节点
visitor.rs:694-698  — 调用 generate_statement_scoped_node_id("derived", statement_index, name)
```

**核心碰撞点**：

当 SQL 包含以下结构时：

```sql
WITH new_device AS (
    ...
    LEFT JOIN (...) b ON ...        -- CTE 内部的 subquery alias b
)
INSERT INTO tgt
SELECT ...
FROM new_device a
LEFT JOIN (...) b ON ...            -- INSERT 顶层的 subquery alias b
```

两个 `FROM (...) AS b` 都会走到 `visit_table_factor` 的 `Derived` 分支，生成：

```
generate_statement_scoped_node_id("derived", 0, "b")
→ generate_node_id("derived", "statement_0::b")
→ derived_<hash of "derived" + "statement_0::b">
```

**两次调用的 `statement_index` 相同（均为 0），name 相同（均为 `"b"`），因此产生完全相同的 ID**。

当第二次 `add_node` 调用时（`context.rs:371-378`）：

```rust
pub(crate) fn add_node(&mut self, node: Node) -> Arc<str> {
    let id = node.id.clone();
    if self.node_ids.insert(id.clone()) {   // ← 已存在，跳过插入
        ...
    }
    id  // ← 返回已有节点的 ID
}
```

第二个 `b` 的节点被静默丢弃，**两个 `b` 使用同一个节点**，所有边都混流到同一节点。

同样情况适用于 `a1`、`a` 等任何在同一 statement 内不同词法深度重用的 derived-table alias。

---

## 4. Scope 机制现状

**文件**: `crates/flowscope-core/src/analyzer/context.rs`

`StatementContext` 存在 `scope_stack: Vec<Scope>`（第 169 行），每个 `Scope` 有 `scope_id: usize`（第 41-42 行），由 `next_scope_id` 单调递增（第 171 行）。

- `push_scope()` / `pop_scope()` 在 `visit_select` 中被调用（`visitor.rs:629, 639`）
- Scope 用于列解析（`alias_instances`、`subquery_columns`、`tables`）
- **但 scope_id 没有被传入 `generate_statement_scoped_node_id`**

即：scope 机制存在，但**节点 ID 生成完全不使用 scope_id**。

---

## 5. 问题的精确触发点

### 触发条件

在同一个 SQL statement（`statement_index` 相同）中，有两个不同词法深度的 `FROM (...) AS <same_name>` 出现时必然触发。

### 代码路径

1. **外层 visit_query（处理 INSERT）** 调用 `cte_visitor.visit_query(&cte.query)` (`visitor.rs:567`)
2. → 内部调用 `visit_set_expr` → `visit_select` → `visit_table_with_joins` → `visit_table_factor`
3. → `Derived` 分支在 `visitor.rs:694-698` 生成 `derived_statement_0::b`
4. **外层 visit_select（INSERT 的顶层 SELECT）** 再次调用 `visit_table_factor`
5. → 同样在 `visitor.rs:694-698` 生成同一个 `derived_statement_0::b`
6. → `add_node` 因 ID 已存在跳过（`context.rs:373`）

### 同名 CTE 叠加问题

`cte_definitions` 是 `HashMap<String, Arc<str>>`（`context.rs:121`），无嵌套隔离。如果 CTE 内部同样使用 `WITH` 子句定义同名 CTE，`cte_definitions.insert` 会直接覆盖外层同名 CTE 的映射（`visitor.rs:553-555`）。

---

## 6. 修复方向的技术建议

### 方向 A：在节点 ID 中加入 scope_id（推荐）

修改 `visit_table_factor` 的 `Derived` 分支（`visitor.rs:692-706`），将当前 scope_id 纳入 ID 生成：

```rust
// visitor.rs 约 694 行，修改前：
id: generate_statement_scoped_node_id("derived", self.ctx.statement_index, name),

// 修改后（示意）：
let scope_id = self.ctx.current_scope_id().unwrap_or(0);
id: generate_node_id("derived", &format!(
    "statement_{}::scope_{}::{}", 
    self.ctx.statement_index, scope_id, name
)),
```

同理，对 CTE 定义节点（`visitor.rs:535-539`）也需要类似处理（仅当支持嵌套 WITH 时）。

### 方向 B：使用递增计数器（更稳健）

在 `StatementContext` 上增加一个 `derived_counter: usize`，每次创建 derived 节点时自增，确保全局唯一：

```rust
id: generate_node_id("derived", &format!(
    "statement_{}::d{}::{}", 
    self.ctx.statement_index, self.ctx.derived_counter, name
)),
```

优点：完全消除同名碰撞；缺点：ID 不再由名字决定，可能影响幂等性。

### 方向 A 的注意事项

`push_scope` 发生在 `visit_select` 进入时，`visit_table_factor` 中的 Derived 分支在 `visit_table_with_joins` 内部触发，此时 scope 已 push。CTE 内部的 derived table 处于不同 scope_id，因此可以区分。但需要验证：外层 SELECT 和内层 CTE-body SELECT 是否确实产生不同 scope_id。

根据 `context.rs:515-519`，`push_scope` 每次调用递增 `next_scope_id`，因此每个 SELECT 体确实有不同的 `scope_id`。

---

## 7. 修复的影响范围

### 会影响的现有测试（节点 ID 变更）

以下测试验证 derived table 节点存在，但不直接检查 node ID 字符串：
- `derived_table_alias_does_not_shadow_cte_with_same_name` (`lineage_engine.rs:4880`)
- `derived_tables_and_exists_predicates_produce_complete_lineage` (`lineage_engine.rs:486`)
- `derived_table_alias_tracks_column_flow` (`lineage_engine.rs:4837`)
- `nested_derived_tables_track_full_lineage` (`lineage_engine.rs:6608`)
- `insert_overwrite_outer_subquery_has_data_flow_to_target` (`lineage_engine.rs:3440`)

这些测试验证的是 **edge 存在性和节点类型**，而非 ID 字符串本身，因此节点 ID 变更不会破坏它们。

### 需要新增的测试场景

目前没有测试覆盖"同名 derived-table alias 在不同 CTE 作用域中不冲突"的场景。需要新增：

```sql
WITH new_device AS (
    SELECT ... FROM t1 LEFT JOIN (...) b ON ...
)
INSERT INTO tgt
SELECT ... FROM new_device a LEFT JOIN (...) b ON ...
```

---

## 8. 相关文件索引

| 文件 | 描述 |
|---|---|
| `crates/flowscope-core/src/analyzer/helpers/id.rs` | 节点 ID 生成函数（`generate_node_id`、`generate_statement_scoped_node_id`） |
| `crates/flowscope-core/src/analyzer/visitor.rs:534-547` | CTE 节点创建（`visit_query`，WITH 处理） |
| `crates/flowscope-core/src/analyzer/visitor.rs:692-706` | **碰撞触发点**：Derived table 节点创建 |
| `crates/flowscope-core/src/analyzer/context.rs:371-378` | `add_node`：已有 ID 时静默跳过 |
| `crates/flowscope-core/src/analyzer/context.rs:515-519` | `push_scope`：scope_id 生成逻辑 |
| `crates/flowscope-core/src/analyzer/context.rs:120-122` | `cte_definitions: HashMap<String, Arc<str>>`（全局，无嵌套隔离） |
| `crates/flowscope-core/src/analyzer/cross_statement.rs:318-326` | `relation_identity`：基于 `generate_node_id` 的全局 ID（与 derived table 无关，但适用于同名 CTE 跨语句问题） |
| `crates/flowscope-core/tests/lineage_engine.rs:4880` | `derived_table_alias_does_not_shadow_cte_with_same_name`（最相关的已有测试） |

---

## Caveats / Not Found

- **嵌套 WITH（CTE 内 CTE）**：`visit_query` 递归时 `cte_definitions` 没有进入/退出隔离，但这是另一个独立 bug，当前问题聚焦于 derived table alias。
- **`a` 别名的情况**：`a` 在 CTE 内和 INSERT 外层均作为 derived table alias 出现，碰撞机制与 `b` 完全相同。
- 未确认 sqlparser-rs 的 AST 访问顺序，但从代码逻辑可以确定：CTE body 先被访问（`visitor.rs:563-571`），随后才是顶层 SELECT（`visitor.rs:573`）。
