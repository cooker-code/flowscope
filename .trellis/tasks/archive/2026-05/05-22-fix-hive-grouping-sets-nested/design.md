# 技术设计 — Bug 1 GROUPING SETS 多级嵌套

## 推荐方案：字符级括号计数

### 算法

```text
1. 用 case-insensitive regex 定位下一个 `group by grouping sets` 头部
   （含其后第一个 `(` 之前的所有空白）
2. 从匹配头部的第一个 `(` 起，逐字节扫描，维护 depth: i32
3. 扫描时跳过：
   - 单引号字符串体（含 \' 反斜杠转义；按 Step 7 之后的形态处理）
   - 行注释 `-- ...` 到行尾
   - 块注释 `/* ... */`
4. 遇到 `(` → depth += 1
5. 遇到 `)` → depth -= 1；若 depth == 0，记录闭合位置 close_idx
6. 把 [head_start, close_idx] 整段（包括 `group by grouping sets` 头）
   替换为字符串 "GROUP BY 1"
7. 从 close_idx + 1 处继续 step 1，覆盖一个 SQL 内多个 GROUPING SETS 的情形
8. 输入耗尽或不再找到匹配 → 返回结果
```

### 为什么字符级计数

| 方案 | 嵌套深度 | 实现规模 | 维护性 |
|------|---------|---------|-------|
| 正则 1 级（现状） | 1 | 1 行 | 已知 bug |
| 正则 2 级 | 2 | 1 行（约 70 字符） | 仍有上限 |
| 正则 N 级（手动展开） | N | 长度 ~2^N | 不可读 |
| 字符级计数 | 任意 | ~40 行 | 一次写好，未来不再触发同类 bug |

`regex` crate **不支持** PCRE 递归 `(?R)`，无法一次性写"任意嵌套"。
字符级计数是 `O(n)` 单次扫描，逻辑简单清晰。

### 边界处理

| 输入 | 期望行为 | 说明 |
|------|---------|-----|
| `'group by grouping sets (a)'`（字符串字面值） | 不替换 | 头部位于字符串体内，跳过 |
| `-- group by grouping sets (a)` | 不替换 | 头部位于行注释，跳过 |
| `/* ... grouping sets ... */ select 1` | 不替换 | 头部位于块注释，跳过 |
| `GROUP\n\tBY\n\tGROUPING\nSETS\n((a))` | 替换为 `GROUP BY 1` | regex 已用 `\s+` 处理空白；扫描器只需从首个 `(` 起 |
| `group by grouping sets ((a),(b))` | 替换 | 简单 1 级（现状已支持，防回归） |

### 扫描器伪代码

```rust
fn rewrite_grouping_sets(input: &str) -> String {
    let re = grouping_sets_head_re();   // 只匹配头部 "group by grouping sets" + 首个 `(`
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut cursor = 0;

    while cursor < input.len() {
        match re.find(&input[cursor..]) {
            None => {
                out.push_str(&input[cursor..]);
                break;
            }
            Some(m) => {
                let abs_start = cursor + m.start();   // "group" 的位置
                let abs_open_paren = cursor + m.end() - 1;   // 首个 `(` 的位置
                out.push_str(&input[cursor..abs_start]);
                // scan from abs_open_paren to matching `)`
                let close = find_matching_paren(bytes, abs_open_paren);
                match close {
                    Some(close_idx) => {
                        out.push_str("GROUP BY 1");
                        cursor = close_idx + 1;
                    }
                    None => {
                        // 不平衡括号 → 保留原文（保守降级），跳到匹配头后继续
                        out.push_str(&input[abs_start..=abs_open_paren]);
                        cursor = abs_open_paren + 1;
                    }
                }
            }
        }
    }
    out
}

fn find_matching_paren(bytes: &[u8], open_idx: usize) -> Option<usize> {
    let mut depth = 0i32;
    let mut i = open_idx;
    while i < bytes.len() {
        match bytes[i] {
            b'\'' => i = skip_single_quoted_string(bytes, i),
            b'-' if i + 1 < bytes.len() && bytes[i + 1] == b'-' => i = skip_to_eol(bytes, i),
            b'/' if i + 1 < bytes.len() && bytes[i + 1] == b'*' => i = skip_block_comment(bytes, i),
            b'(' => { depth += 1; i += 1; }
            b')' => {
                depth -= 1;
                if depth == 0 { return Some(i); }
                i += 1;
            }
            _ => i += 1,
        }
    }
    None
}
```

> `skip_single_quoted_string` / `skip_to_eol` / `skip_block_comment` 复用思路与
> Step 6 / Step 12.5 已有实现一致；可考虑抽公共 helper，也可独立写（取决于
> implement 时的代码复用判断）。

### 头部 regex

```rust
fn grouping_sets_head_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?is)group\s+by\s+grouping\s+sets\s*\(").unwrap())
}
```

注意：尾部带上 `\(` 让 `m.end()` 直接指向首个 `(` 之后，便于定位 open paren。

## 备选方案

### 备选 A：正则 2 级嵌套

```
group\s+by\s+grouping\s+sets\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)
```

- **优点**：1 行改动，最小 patch
- **缺点**：3 级嵌套（set 内 `func(func(x))` 这种）依然失败；本质 kicking the can
- **降级触发条件**：仅在字符级方案实现遇阻、本任务严重超期时考虑

### 备选 B：放弃匹配，整段删除 `group by ...` 子句

- 太激进，会改变血缘骨架（GROUP BY 的列在某些边缘场景仍有价值），**否决**

## 风险

| 风险 | 严重度 | 缓解 |
|------|-------|-----|
| 字符串体跳过逻辑写错，吞掉合法 SQL | 中 | 必须有 `grouping_sets_inside_string_literal_not_touched` 单测；行/块注释场景也要负例覆盖 |
| 不平衡括号导致死循环或越界 | 中 | `find_matching_paren` 返回 `Option`，None 时保守降级（保留原文，cursor 推进 1 字节） |
| 与 Step 11（auto_split_statements）顺序冲突 | 低 | Step 13 在最后跑，无下游 step；新增字符级扫描只读不改其他形态 |

## 兼容性 & rollback

- 纯替换 `rewrite_grouping_sets` 函数体 + 新增 helper（`grouping_sets_head_re`、`find_matching_paren`、字符串/注释跳过 helper）
- 单文件单 commit，git revert 一步回退
- 不影响 `analyze()` 接口

## 文档同步

`hive-compat-preprocess.md` Step 13 段表述更新（**由父任务统一收口**）：
- 删除"最多支持 1 级嵌套"的隐含限制
- 改为"字符级括号计数，任意嵌套层数；跳过字符串体与注释"
