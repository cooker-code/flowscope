## 实施顺序

1. 读取jsonl和Spec，精确复现根因。
2. 最小正式实现和有意义的语法/字段血缘回归；不修改原SQL。
3. 本类测试、diff/fmt检查，记录证据。
4. 主session集成、53份全量重放、独立字段验收和WASM检查后合master。

## 单类实现验证

方言15项、complex_types_lineage 1项、fmt/diff通过。无Generic全文fallback；已修复debug_assert副作用、合法可选冒号与128层局部递归上限。11份复杂类型首错已消除，其中557500仍被暂缓exists阻挡；557564需与标识符集成后回测。最终native/WASM、独立字段和隔离图由集成任务核验后才允许合master。
