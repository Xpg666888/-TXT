# LOOP — 五阶段闭环与证据标准

> 这个文件定义“什么算做完”。模型可以自由发挥方法，但**不能绕过这里的判据**。

## 阶段 1 · 定位（Orient）

产出：目标清单 + 每个目标的 `sha256` / `kind` / 关键属性。

```powershell
kai probe TARGET --case <case>
```

判据：`probe` 的 JSON 落盘为 evidence。没有 probe 的案子，后面所有结论都是 `inferred`。

## 阶段 2 · 假设（Hypothesize）

产出：1~3 条可证伪的假设，写进账本。

```powershell
kai claim add --case <case> "假设：授权校验在 LicenseApi.Check() 返回 false 时弹出激活窗"
```

要求：假设必须**指向可观测的东西**（某个字符串、某个 API、某个分支、某个响应差异）。写不出观测点的假设，删掉。

## 阶段 3 · 取证（Instrument）

按类型选手段，全部产出 evidence：

| 类型 | 手段 | evidence |
|---|---|---|
| 静态结构 | `kai probe` | 节区/导入/字符串事实 |
| 控制流 | `kai dis --rva 0x.. --len 256` | 指令序列 |
| 改动 | `kai patch --offset --bytes --out` | before/after + 产物哈希 |
| 改动校验 | `kai diff orig patched` | 补丁表（offset→节区/VA） |
| 动态行为 | `kai run -- <cmd>` | exit + stdout 哈希 |
| 网络/接口 | `kai run -- curl ...` | 请求响应全文 |
| 深度反编译 | rikune `workflow.run` | artifact（可转存为 kai evidence） |

## 阶段 4 · 验证（Verify）

```powershell
kai verify C001 --case <case> --evidence E001,E002 --note "复现命令"
```

规则：
- `verified` 必须至少一个 evidence，且 evidence 能被人重跑。
- 动态类结论要求**成对证据**：改动前拒绝 / 改动后通过（两次 `kai run`）。
- 只有静态证据时，结论写成“控制流事实”（如“该分支恒跳转”），不要写成“已破解”。

## 阶段 5 · 交付（Report）

```powershell
kai report --case <case>
```

报告结构固定：
1. 样本表（哈希、大小、路径）——可核对来源；
2. 结论（只含 verified）——每条挂 evidence + 复现命令；
3. 待验证假设——诚实标注；
4. 证据清单——产物路径可追溯。

## 反模式（一票否决）

- 结论先行、证据后补（先写 verified 再找 evidence）。
- 用“我试过了/应该可以”替代 `run`/`diff`。
- 报告里出现没有 evidence 的断言。
- 同一个 case 里对同一目标重复 probe 却不复用已有 evidence（浪费且制造冲突）。

## 附：证据等级

| 等级 | 含义 | 典型来源 |
|---|---|---|
| L0 推断 | 模型知识/经验 | 无 |
| L1 静态事实 | 字节/结构/字符串 | probe / dis |
| L2 结构证明 | 改动可控且可定位 | patch + diff |
| L3 动态证明 | 行为差异可复现 | run ×2（前/后） |
| L4 端到端 | 目标功能真的变了 | L3 + 用户可见结果 |

`verified` 的最低门槛是 L2；涉及“破解成功/拿到权限”的结论必须 L3。
