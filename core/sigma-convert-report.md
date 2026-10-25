# Sigma 规则转换报告

- 源：`E:\ai\_tools\errwatch\tools\sigma-samples`
- 扫描到的规则文件：**9**
- 成功转换：**6**　　跳过：**3**
- 产物：`core\rules-sigma.json`　　生成时间：2026-10-23 12:12

## 为什么会有"跳过"

errwatch 用**文本正则**匹配，Sigma 用**结构化字段**匹配，两者不是同一种东西。
所以只转换能可靠表达的条件；表达不了的**宁可跳过也不硬转** —— 一条转错的规则会直接变成误诊。

## 跳过的规则（及理由）

### 1 条：过滤组「filter」无法表达：该规则没有文本条件可供负向断言附着（丢掉过滤会让规则变宽松）

- `sample-filtered.yml`

### 1 条：字段修饰符不支持：|base64offset

- `sample-unsupported-mod.yml`

### 1 条：condition 形式不支持："(selection_a or selection_b) and not filter"（只支持「单组」或「组 and not 组」）

- `sample-complex-condition.yml`

## 转换成功的规则（抽样）

| id | author | level | 事件ID | 标题 |
|---|---|---|---|---|
| `sigma-1a111111` | errwatch sample | critical | 1001 | Windows BugCheck (Blue Screen Recorded)：Detect… |
| `sigma-2b222222` | errwatch sample | high | 7,11,51 | Disk Bad Block Or Controller Errors：Detects st… |
| `sigma-5e555555` | errwatch sample | informational |  | Kernel Power Loss Keywords：Keyword based detec… |
| `sigma-6f666666` | errwatch sample | high | 11708 | MSI Install Failure 1603：Detects MSI installer… |
| `sigma-3c333333` | errwatch sample | medium | 7000 | Service Failed To Start：A service did not star… |
| `sigma-9c999999` | errwatch sample | low | 6416 | External Disk Drive Recognised：Detects a newly… |

> 完整规则在输出文件里。每条都带 ``note`` 说明近似点。

## 转换成功的规则：按日志来源分布（Top 15）

| 日志来源（product/service） | 条数 |
|---|---|
| `windows/system` | 3 |
| `windows/` | 1 |
| `windows/application` | 1 |
| `windows/security` | 1 |

## 已知的近似点（务必知情）

1. **字段名被忽略**：Sigma 的字段匹配（CommandLine / Image / TargetFilename…）在 errwatch 里展平成"文本包含"。
2. **等值 = 包含**：Sigma 默认是等值匹配，文本匹配下按"包含"处理，理论上比原规则更宽松。
3. **AND 用负向无关的 lookahead 表达**：``(?=.*A)(?=.*B)`` 只保证"都出现过"，不保证同一条记录内的字段顺序。
4. **condition 只支持两种形式**：单组、``组 and not 组``。更复杂的（or 组合、多层括号）跳过。
5. **falsepositives 不参与**：Sigma 官方明说该字段不参与转换，只在报告里提醒人。
6. **level 只映射成建议语气**：Sigma 没有"怎么办"，errwatch 不替它编处置方案。

