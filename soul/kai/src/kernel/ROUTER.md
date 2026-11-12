# ROUTER — 任务 → 链路 的路由表

> 用法：先在这里定位“这是哪一类活”，再决定用 kai 本地链路、rikune、CyberStrikeAI，还是三者组合。
> 每一行都写了**降级路径**：缺工具时不阻塞，换下一档。

## 0. 先判两件事

1. **目标是什么形态？** 文件（PE/ELF/Mach-O/APK/JS/固件）还是 服务（URL/IP/内网）？
2. **要的产出是什么？** 结论（能跑起来/拿到权限/证明漏洞）还是 报告（可复现的证据链）？

产出若是“结论”，必须有 `kai run` 或 `diff` 级别的判据；否则只能写成假设。

## 1. 文件类（逆向 / 破解）

| 目标特征 | 首选链路 | 具体动作 | 降级 |
|---|---|---|---|
| 未知 PE/ELF，先摸底 | kai 本地 | `kai probe X --case N` → 看节区熵/RWX/加壳/导入能力/overlay/PDB | 无 python 时 `strings` + 手写 JS 解析（probe 内建 PE 节区表） |
| .NET / Unity / 有 mscoree | kai + IL 工具 | `probe` 确认 .NET → dnSpy/ilspy 读 IL → 找校验方法 → `patch` IL/字节 | 无 dnSpy：`strings` 找 `License*` 符号 + `lief` 改 IL 元数据 |
| 加壳（UPX/Themida/VMProtect） | kai + skill | `skill code-obfuscation-deobfuscation`；`probe` 的 packer-section-name 给指纹；UPX 直接 `upx -d` | 无 upx：先 dump 内存（frida/pe-sieve），再 `probe` 复核熵是否下降 |
| 卡密/授权校验 | kai 闭环 | `probe` 找 License/Token/Activate 字符串 → `dis` 定位分支 → `patch` → `diff` 出补丁表 → `run` 两次对照 | 无动态环境：用 `dis` 证明“分支恒真/恒假”的控制流事实，标为 supported 而非 verified |
| 反调试/反虚拟机 | kai + skill | `skill anti-debugging-techniques`；`probe` 看 `NtQueryInformationProcess`/`GetTickCount`/TLS 回调 | 无调试器：静态 patch 检测点，用 `diff` 记录 |
| 自定义 VM / 字节码 | kai + skill | `skill vm-and-bytecode-reverse`；`dis` 取 dispatcher 循环 → 建 opcode 映射表 | 无 IDA：capstone 批量导出 + 自写 handler 表 |
| 有明确 check 函数、需要解 | kai + skill | `skill symbolic-execution-tools`；angr/Z3 求解（`uv pip install angr`） | angr 装不上：改用 unicorn 单函数模拟 + 爆破约束 |
| 需要跑起来观察 | kai run / rikune runtime | `kai run -- sample.exe` 记录 exit/stdout；深动态交 rikune（Windows Sandbox/Hyper-V） | 无沙箱：只在一次性 VM/容器里跑，别在宿主机 |

## 2. 服务类（渗透）

| 目标特征 | 首选链路 | 具体动作 | 降级 |
|---|---|---|---|
| 只给一个域名/单位名 | skill 路由 | `skill hack` → `recon-for-sec` → `attack-surface-mapping` | 无 FOFA：crt.sh + 被动 DNS + 搜索引擎 |
| 要给攻击面图 | kai + skill | 从现有页面/JS 提 host、API、key、对象图；每条落 evidence | 无浏览器：curl + JS 静态提取 |
| 有登录/Token/对象 id | skill | `authbypass-authentication-flaws` / `idor-broken-object-authorization` / `jwt-oauth-token-attacks` | 无 Burp：`kai run -- curl ...` 逐条留证 |
| 输入进解释器 | skill | `sqli` / `xss` / `ssrf` / `cmdi` / `deserialization-insecure`，按 skill 的判据矩阵 | 无 sqlmap：手注 + 时间盲注，`kai run` 记响应差异 |
| 文件上传/路径 | skill | `upload-insecure-files` / `path-traversal-lfi` | — |
| 拿到低权 shell | skill | `linux/windows-privilege-escalation` → `tunneling-and-pivoting` → `reverse-shell-techniques` | 无隧道工具：ssh -D / socat |
| 多步、要资产库/攻击链/人审 | CyberStrikeAI | 见 `mcp/cyberstrike.mcp.json`；它的资产库 + 攻击链图谱负责“编排与留痕” | 纯 kai：每个 case 就是一个“手工攻击链”，evidence 顺序即链路 |
| 要复现/回归验证 | kai | 把 CSI 的 finding 用 `kai run` 复核后入账 | — |

## 3. 组合拳（推荐姿势）

```
skill(hack) ──路由──▶ skill(具体域)
        │
        ├─ 文件类 ──▶ kai probe/dis/patch/diff ──▶ (重活) rikune workflow.run
        └─ 服务类 ──▶ skill 判据矩阵 ──▶ kai run 留证 ──▶ (多步) CyberStrikeAI 攻击链
                                            │
                                            ▼
                                   kai case/claim/verify/report
```

## 4. 不该做的事

- 没 probe 就直接下结论（连架构/加壳都不知道，谈何 patch）。
- 把 `supported` 当 `verified` 写进报告。
- 用宿主机跑不可信样本（动态一律 VM/容器/沙箱）。
- 同一目标重复造轮子：先 `kai case show` 看已有什么证据。
