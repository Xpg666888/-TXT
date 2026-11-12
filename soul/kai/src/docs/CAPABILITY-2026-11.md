# 能力评估与优化路线（2026-11-13）

## 一、评级（诚实版）

| 维度 | 评分 | 依据 | 主要缺口 |
|---|---|---|---|
| **静态逆向** | ★★★★☆ | Ghidra 12.2 headless 可用、radare2 6.2.6、capstone/lief、dnSpy 6.6、ilspycmd 8.2、kai probe/dis | Ghidra 批处理脚本（函数表/交叉引用/反编译导出）、.NET 脱混淆（de4dot） |
| **动态逆向** | ★★★☆☆ | x64dbg 手动、frida 17.26、unicorn 单函数模拟（本轮新增，已实测） | 进程级调试自动化、内存 dump（pe-sieve）、VM/沙箱（WSL 未启用）、Qiling 全系统模拟 |
| **破解/授权** | ★★★★☆ | probe 定位授权面 → dnSpy/ilspycmd 读 IL → emu 跑校验函数（bool_ret 实测 1/0）→ angr 求解 → diff 出补丁表 | 批量爆破（emu 单次 ~0.3s）、.NET 强名称/混淆自动化 |
| **渗透** | ★★★☆☆ | nmap 7.92、sqlmap、ffuf、nuclei、subfinder、httpx、interactsh OAST、mitmproxy、chisel | Npcap（SYN 扫描）、Burp 类改包 GUI、资产库/攻击链（CSI 未配置）、浏览器自动化、内网工具（fscan/gogo） |
| **编排/证据** | ★★★★★ | kai 账本（case/claim/evidence/verify/report）+ 14 个 MCP 工具 + 33 技能 | —— 这是目前最强项 |
| **基建** | ★★★☆☆ | 工具全在 E:（C 盘释放 16GB）、缓存重定向 | **WSL2/Docker 待重启**，Linux 侧工具链全被卡住 |

## 二、本轮新增（2026-11-13）

| 能力 | 状态 | 验证 |
|---|---|---|
| `kai emu`（unicorn 单函数模拟） | ✅ | Go crackme：正确 8 字节 → `bool_ret=1`（75 条指令）；错误 → 0；长度不对 → 5 条指令早退 |
| `kai solve`（angr 符号执行） | ✅ 已接入 | 需要明确的 find/avoid 地址 |
| interactsh-client 1.4.1 | ✅ | 盲打 SSRF/XXE/RCE 的带外验证 |
| mitmproxy（mitmdump/mitmweb） | ✅ | 抓包/改包可脚本化 |
| nmap 7.92 | ✅ | 6.00 的旧二进制缺 DLL 跑不起来，已替换；**仍缺 Npcap**（只能 connect 扫描） |
| MCP 工具 14 个 | ✅ | `mcp__kai__emu` / `mcp__kai__solve` 已上线 |

## 三、P0（先做这三件，收益最大）

### 1. 重启 Windows，开 WSL2 + Docker
一条命令解锁整条 Linux 工具链（angr 跑 ELF、pwntools、one_gadget、ROPgadget、AFL++、Qiling、rikune）：
```powershell
# 重启后
pwsh -File E:\tools\_setup\03-wsl.ps1 -Setup
```

### 2. 装 Npcap（nmap 才真正可用）
```powershell
# 官网下载 npcap-*.exe 安装（勾 WinPcap 兼容模式）
# 之后 nmap 才有 -sS / -O / -sV 的完整能力
```

### 3. `kai emu` 批量化（把"能调用"变成"能爆破"）
当前每次调用起一个 python 进程（~0.3s），爆破 8 位 ASCII 不可行。方案：
- `emu --batch <jsonl>`：一次进程内跑 N 组输入，只输出 bool_ret 序列
- 或把校验函数逻辑用 capstone 反汇编后直接翻译成 Python 表达式（更快，但只适合简单算法）

## 四、P1（两周内）

4. **Ghidra 脚本自动化**：`analyzeHeadless` + 自定义脚本，导出函数表/交叉引用/反编译到 JSON，直接进 kai evidence。
5. **.NET 脱混淆**：de4dot（ConfuserEx/.NET Reactor）+ dnlib 脚本，补上 .NET 破解的关键一环。
6. **浏览器证据链**：Playwright（npm）+ mitmproxy 联动，XSS/DOM 类漏洞自动出截图 + 请求响应。
7. **CyberStrikeAI 启动**：`config.yaml` 指向本机 `http://127.0.0.1:8788/v1`，启用资产库/攻击链/人审。

## 五、P2（可选）

8. Qiling 全系统模拟（带 Windows DLL 根文件系统，跑完整 PE 而不开 VM）
9. AFL++ / honggfuzz fuzz 回路（Linux 侧，配合 WSL）
10. 代理池 / FOFA key（渗透侧规模化）
11. pe-sieve / hollows_hunter（内存 dump 与注入检测）

## 六、一句话结论

**静态逆向和"证据闭环"已经是专业水准；动态逆向和渗透是"工具齐全但缺自动化与联动"；最大瓶颈不是工具数量，而是三件事：WSL 没开、Npcap 没装、emu 不能批量。**
