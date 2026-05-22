# 技术设计 — Bug 3 字符串内嵌占位符

> **修订历史**：
> - **v1** "6 个 embedded regex" 方案 — 跨字符串吞噬，反证否决（详见文末"v1 失败记录"）
> - **v2** "字符级扫描器 + 3 个 bare regex"两阶段 — Phase 2 bare regex 不感知注释，
>   注释体内的占位符被误替换；反证否决（详见文末"v2 失败记录"）
> - **v3**（当前）**单次字符级扫描，三段上下文统一处理** — 注释/字符串/代码各自上下文处理，
>   代码段累积后调用 3 个 bare regex 复用语义

## 推荐方案：单次字符级扫描，三段上下文统一处理

### 总流程

```rust
fn substitute_placeholders(input: &str) -> String {
    let bytes = input.as_bytes();
    let n = bytes.len();
    let mut out = String::with_capacity(n);
    let mut pending = String::new();    // 累积 code 段文本，flush 时跑 bare regex

    let mut i = 0;
    while i < n {
        let ch = bytes[i];

        // ── 行注释 -- ... \n ──────────────────────────────────────────
        if ch == b'-' && i + 1 < n && bytes[i + 1] == b'-' {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            let end = input[i..].find('\n').map(|p| i + p).unwrap_or(n);
            out.push_str(&input[i..end]);
            i = end;
            continue;
        }

        // ── 块注释 /* ... */ ─────────────────────────────────────────
        if ch == b'/' && i + 1 < n && bytes[i + 1] == b'*' {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            let end = input[i + 2..].find("*/").map(|p| i + 2 + p + 2).unwrap_or(n);
            out.push_str(&input[i..end]);
            i = end;
            continue;
        }

        // ── 字符串字面量 '...' / "..." ────────────────────────────────
        if ch == b'\'' || ch == b'"' {
            flush_pending_with_bare_regex(&mut out, &mut pending);
            let quote = ch;
            let start = i;
            let mut j = i + 1;
            while j < n {
                if bytes[j] == b'\\' && j + 1 < n {
                    j += 2;
                    continue;
                }
                if bytes[j] == quote {
                    break;
                }
                j += 1;
            }
            if j < n {
                let body = &input[start + 1..j];
                if body.contains("{{{") || body.contains("{{") || body.contains("${") {
                    out.push_str("'__ph__'");
                } else {
                    out.push_str(&input[start..=j]);
                }
                i = j + 1;
            } else {
                // 未闭合字符串 — 保留剩余原文
                out.push_str(&input[start..]);
                break;
            }
            continue;
        }

        // ── code 段 ──────────────────────────────────────────────────
        // 累积到 pending；flush 时（进入注释/字符串前 + 扫描结束）跑 3 个 bare regex
        pending.push(ch as char);
        i += 1;
    }

    flush_pending_with_bare_regex(&mut out, &mut pending);
    out
}

fn flush_pending_with_bare_regex(out: &mut String, pending: &mut String) {
    if pending.is_empty() {
        return;
    }
    let s = ph_re_triple_bare().replace_all(pending, "'__ph__'");
    let s = ph_re_double_bare().replace_all(&s, "'__ph__'");
    let s = ph_re_dollar_bare().replace_all(&s, "'__ph__'");
    out.push_str(&s);
    pending.clear();
}
```

### 设计要点

1. **单次字符级扫描覆盖三种上下文**：注释 / 字符串字面量 / code 段，每种上下文独立处理，O(n)，与 Step 6 / Step 12.5 已有的扫描器风格一致
2. **code 段累积到 pending，flush 时跑 3 个 bare regex**：复用现有 bare regex 语义（不重新实现裸占位符匹配），同时保证 bare regex 只在"非注释、非字符串"的代码段上运行，闭环消除 v2 的注释误伤
3. **flush 时机**：进入注释段前 + 进入字符串段前 + 扫描结束时；确保 pending 始终是连续 code 段
4. **`body.contains(...)` 三个简单子串判断**：字符串体是否含占位符，不依赖任何正则
5. **统一输出 `'__ph__'`（单引号）**：无论原字符串是单引号还是双引号，都归一为单引号 — Hive 语义不变（双引号 = 字符串），下游 Step 6 也不会再次处理
6. **未闭合字符串**：原样保留剩余原文，退出循环

### 为什么删除原 9 个 quoted regex（`_sq` / `_dq`）

字符级扫描器**完全覆盖**它们的职责且更严格：

| 原 regex 模式 | 字符级扫描器是否覆盖 | 备注 |
|--------------|--------------------|-----|
| `'{{{var}}}'` | ✓ | body=`{{{var}}}` 含 `{{{` |
| `"{{{var}}}"` | ✓ | 同上，输出统一 `'__ph__'`（单引号） |
| `'{{var}}'` | ✓ | body 含 `{{` |
| `"{{var}}"` | ✓ | 同上 |
| `'${var}'` | ✓ | body 含 `${` |
| `"${var}"` | ✓ | 同上 |

→ **9 个 quoted regex helper 全部删除**（包括 v1 增加的 6 个 embedded），代码净减少

### 为什么保留 3 个 bare regex

裸 `{{{var}}}` / `{{var}}` / `${var}` 不在字符串内，字符级扫描器不处理它们。
3 个 bare regex（已存在，不改）按 triple → double → dollar 顺序兜底。

triple 先于 double 的约束**仍然必要**：否则 `{{{x}}}` 会被 `\{\{[^}]*\}\}` 抓
住成 `{{x}}` + 多一个 `{` `}` 漏出。

### 不变性

| 输入 | 输出 | 由谁保证 |
|------|------|---------|
| `'{{{x}}}'` | `'__ph__'` | 字符级扫描器（body 含 `{{{`） |
| `'%{{{x}}}%'` | `'__ph__'` | 同上 |
| `'%{{{a}}}%{{{b}}}%'` | `'__ph__'` | 同上（body 含 `{{{`） |
| `'%abc%'` | `'%abc%'` | 字符级扫描器（body 不含任何标志） |
| `{{{x}}}` 裸 | `'__ph__'` | `ph_re_triple_bare` |
| `select 1 from t` | 原样 | 字符级扫描器（无引号字面量，无裸标志） |
| `'__ph__', ${d}, {{e}}, '__ph__'` | `'__ph__', '__ph__', '__ph__', '__ph__'` | 字符级扫描器认出两个独立的 `'__ph__'`（不含标志，保留），中间 `${d}` / `{{e}}` 被对应 bare regex 处理 |
| `-- 含 ${a} 的注释` | 原样保留 | 字符级扫描器跳过注释体 |

`placeholders_all_forms`（已有测试）：
```
select '${a}', '{{b}}', '{{{c}}}', ${d}, {{e}}, {{{f}}} from t
```
- 字符级扫描识别 `'${a}'`、`'{{b}}'`、`'{{{c}}}'` 三个字符串都含占位符 → 各替换为 `'__ph__'`
- 剩余文本：`select '__ph__', '__ph__', '__ph__', ${d}, {{e}}, {{{f}}} from t`
- bare triple 替换 `{{{f}}}` → `'__ph__'`
- bare double 替换 `{{e}}` → `'__ph__'`
- bare dollar 替换 `${d}` → `'__ph__'`
- 最终：6 个 `'__ph__'` ✓（原测试断言通过）

## 备选方案

### 备选 0：v2 的两阶段（字符级 + 3 个 bare regex 后处理，已否决）

- **问题**：Phase 2 的 bare regex 在最终输出文本上跑，不感知注释，注释体内的占位符仍被替换（产出 `''__ph__''` 类畸形）
- **实测反证**：`placeholder_in_line_comment_not_replaced` 测试失败
- **教训**：上下文边界识别（字符串/注释）一旦交给 regex 就出问题。v3 把 bare regex 也搬进字符级扫描器内（只在 code 段上跑），逻辑闭环

### 备选 A：v1 的 6 个 embedded regex 方案（已否决）

- **问题**：`[^']*\{\{[^}]*\}\}[^']*'` 这种 regex 无法区分开/闭引号；在「两已替换字符串之间夹裸 `{{e}}`」时跨边界吞噬，输出畸形 `'__ph__'__ph__'`
- **实测反证**：在 `placeholders_all_forms` 输入下 `'__ph__'` 计数从 6 降到 4
- **结论**：方案不可行，永久否决

### 备选 B：v1 备选 A — 紧 regex 字符集 `[^';,]*`

- **问题**：字符串内含 `,` 或 `;`（如 `'a, b, {{var}}, c'`）会落到 bare regex 破坏边界
- **结论**：覆盖面缩小，治标不治本

### 备选 C：纯 regex + 多轮反复迭代到收敛

- **缺点**：复杂度高，难以推理收敛性
- **结论**：不如字符级扫描器直白

## 风险

| 风险 | 严重度 | 缓解 |
|------|-------|-----|
| 字符级扫描器误处理转义引号 `\'` | 低 | 扫描器有 `\` 转义处理（j += 2 跳过转义字符） |
| `'don''t {{{a}}}'`（连续 `''` 转义） | 低 | 扫描器会把第一个 `''` 当作"空字符串 + 开新引号"；该写法在 Hive 极罕见，明确列入 Out of Scope |
| 块注释未闭合时贪婪保留 | 低 | 未闭合时整段保留剩余原文，不破坏 |
| 引号在字符串体内 escape 的语义被 Step 7（反斜杠剥离）后处理覆盖 | 低 | Step 1 在 Step 7 之前跑；本扫描器只关心字符串"包含某些 marker"，不解析转义语义 |

## 兼容性 & rollback

- 单 commit 内同时完成：删 6 个 quoted regex (v1 加的 embedded 全删) + 6 个原 `_sq`/`_dq` 全删 + 改写 `substitute_placeholders` 为单次扫描 + 新增 `flush_pending_with_bare_regex` helper + 加 8 个测试
- git revert 一步回退
- `analyze()` 接口不变
- 现有所有 placeholder 测试断言不变（即"输入 X 应输出 Y"的语义契约保持）

## 文档同步（由父任务收口）

`hive-compat-preprocess.md` Step 1 段：
- 删除"9 个正则按顺序"的旧表述
- 改为"单次字符级扫描三种上下文（注释 / 字符串 / 代码段），字符串内含占位符整段替换；代码段累积后跑 3 个 bare regex 兜底裸占位符；注释体原样保留"
- 例子表加 `'%{{{var}}}%'` → `'__ph__'` + `-- ${a}` → 原样保留

---

## v1 失败记录（供未来同类设计参考）

**v1 方案**：为三档（triple / double / dollar）× 两种引号（sq / dq）各新增一个 regex
`[^']*<placeholder>[^']*'`，按"sq → sq_embedded → dq → dq_embedded → bare"顺序执行。

**反证用例**：`placeholders_all_forms`（已有测试）
```
select '${a}', '{{b}}', '{{{c}}}', ${d}, {{e}}, {{{f}}} from t
```

执行到 `double_sq_embedded` 时：
- 此前 `'{{b}}'` 已被 `double_sq` 替换为 `'__ph__'`
- 当前文本：`'${a}', '__ph__', '__ph__', ${d}, {{e}}, '__ph__'`
- `double_sq_embedded` 模式 `'[^']*\{\{[^}]*\}\}[^']*'` 命中第二个 `'__ph__'` **闭合 `'`** → `, ${d}, {{e}}, ` → 第三个 `'__ph__'` **开 `'`** 这一整段，把它当作一个"嵌入了 `{{e}}` 的字符串"，替换为 `'__ph__'`
- 输出畸形：`'${a}', '__ph__'__ph__'__ph__' from t`

**根因**：regex 没有"字符串边界"概念，`'` 既可能是开引号也可能是闭引号；
`[^']*` 在两个已替换字符串中间游走时会跨越本不该跨的边界。

**教训**：
- 凡是"识别字符串字面量"的需求，regex **不**是合适工具
- 与既有架构对照：Step 6（双引号→单引号）、Step 12.5（孤立 AS）都用字符级扫描，不是巧合 — 这是处理 SQL 文本"上下文边界"问题的唯一稳妥手段
- 即使 design 阶段写好了"严格执行顺序"，也只能阻止同一形态自吞，不能阻止跨形态吞噬
- design.md 写"否决理由：xxx 足够稳"时，必须有具体反例驱动，不能仅靠"复杂度估算"

---

## v2 失败记录

**v2 方案**：Phase 1 字符级扫描器只负责"识别字符串字面量内的占位符并替换"，
Phase 2 仍用 3 个 bare regex 全文兜底裸占位符。

**反证用例**：`placeholder_in_line_comment_not_replaced`
```
select 1 -- '${a}' is comment
from t
```

执行：
- Phase 1 字符级扫描器：进入行注释，整段 `-- '${a}' is comment` 原样推到输出（注释体内的 `'${a}'` 不被识别为字符串字面量）✓
- Phase 2 `ph_re_dollar_bare` (`\$\{[^}]*\}`) 在**整段已 build 好的输出**上跑：注释体内的 `${a}` 被命中，替换为 `'__ph__'`
- 输出：`select 1 -- ''__ph__'' is comment\nfrom t` ❌（注释里出现了畸形 `''__ph__''`）

**根因**：v2 design 在 Phase 1 用了字符级扫描器获得"字符串边界识别"能力，
但 Phase 2 又把"裸占位符替换"扔回 regex 处理。**regex 没有上下文概念**，
照样会闯入注释体。两阶段架构里 Phase 2 形成了上下文盲区。

**教训**：
- "识别注释边界"与"识别字符串字面量"是同一类问题：regex 不适合，必须字符级扫描
- 一旦决定用字符级扫描器处理 SQL 文本的上下文边界，**所有**会被上下文影响的
  替换都必须在扫描器内部完成；不能让一部分逻辑跑在扫描器外
- v3 把 bare regex 也搬进扫描器（只在 code 段上跑），逻辑闭环
