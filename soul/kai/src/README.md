# kai — 逆向 / 破解 / 渗透 的能力内核

> 四个项目（rikune / CyberStrikeAI / hack-skills / dsh-purge）各自都不弱，但它们都是**零件**。
> kai 补的是零件之间缺的那一层：**判据（oracle）+ 账本（case/claim/evidence）+ 路由（router）**。
> 没有这一层，模型说“破解成功了”你无法证伪；有了这一层，每条结论都挂着可复现的证据。

## 30 秒上手

```powershell
cd E:\逆向\kai
.\bin\kai.cmd doctor                        # 环境体检：本机缺什么、能跑哪条链路
.\bin\kai.cmd case init demo                # 开一个案子（账本）
.\bin\kai.cmd probe SAMPLE.exe --case demo  # 静态深挖 → 自动入账 evidence E001
.\bin\kai.cmd claim add --case demo "样本是 .NET，走 IL 层" --evidence E001
.\bin\kai.cmd verify C001 --case demo --evidence E001 --note "probe 输出 mscoree 导入"
.\bin\kai.cmd report --case demo            # 只输出有证据的结论
```

## 命令面

| 命令 | 作用 | 产出 |
|---|---|---|
| `doctor` | 环境体检（python/venv/包、docker、wsl、ghidra、r2、frida、nmap…） | 缺口清单 + 安装建议 |
| `probe <file> [--case N]` | PE/ELF 深挖：节区熵、RWX、加壳指纹、导入能力矩阵、overlay、TLS、PDB、字符串/URL/卡密关键词 | JSON 事实 + evidence |
| `dis <file> --rva/--offset --len` | capstone 反汇编任意区间 | 指令表（含 VA/字节） |
| `diff <orig> <patched>` | 字节级 diff，自动映射到节区/VA，报告插入截断 | 补丁表 + evidence |
| `patch <file> --offset --bytes --out` | 打补丁并记录 before/after 与产物哈希 | 补丁副本 + evidence |
| `run [--case N] -- <cmd>` | 执行并把 exit/stdout 哈希入账 | 动态判据 evidence |
| `case init\|list\|show` | 案件账本 | case.json / claims.jsonl / evidence.jsonl |
| `claim add` / `verify` / `report` | 结论生命周期：inferred → supported → verified | 可交付报告 |
| `kb <词>` / `skill <id>` | 检索本地 103 个 hack-skills（离线） | 命中技能 + 路径 |
| `skills install [--all]` | 把精选技能注入 `$DSH_HOME/skills`，DSH 原生 `skill` 工具立即可用 | 技能库 |

## 目录

```
kai/
├─ bin/kai.mjs          CLI 主体（零依赖，node 内置模块）
├─ bin/kai.cmd          Windows 启动器（可加进 PATH）
├─ py/probe.py          深度静态分析（pefile / pyelftools / lief）
├─ py/disasm.py         capstone 反汇编
├─ runtime/venv/        uv 建的隔离 Python（pefile capstone lief pyelftools requests）
├─ vendor/hack-skills/  离线知识库（103 skills，来自 yaklang/hack-skills）
├─ cases/<name>/        每个案子的账本与产物
├─ kernel/ROUTER.md     任务 → 后端/链路 的路由表
├─ kernel/LOOP.md       五阶段闭环与证据标准（写死“什么算完成”）
├─ skills/              内核技能（kai-crack-loop / kai-binary-triage / kai-pentest-oracle）
├─ mcp/kai-mcp.mjs      零依赖 stdio MCP 服务器（12 个 mcp__kai__* 工具）
├─ mcp/_selftest.mjs    MCP 自检：initialize → tools/list → tools/call
├─ mcp/*.mcp.json       rikune / CyberStrikeAI 的接入模板（待其二进制就位）
├─ bundle/              配置型 bundle：把 mcp-client 以 serverName=kai 插进 profile
└─ EVOLUTION.md         为什么这么设计：四个项目的缺口与补齐方式
```

## 铁律

1. **没有 evidence 的结论只能是 `inferred`**，`verify` 强制要求证据 id。
2. `report` 只把 `verified` 写进“结论”，其余进“待验证假设”——报告不能掺水。
3. 每个 evidence 都留产物文件（`cases/<name>/artifacts/`），别人能重跑。
4. 破解类任务必须给出 `diff` 补丁表或 `run` 动态判据，不接受“应该可以了”。

## 环境（本机现状）

- 已就绪：node 24、Python 3.12（venv）、pefile/capstone/lief/pyelftools、java 25、git、wsl.exe
- 待补：docker / go / ghidra / radare2 / frida / adb / nmap / sqlmap / ffuf / nuclei / 7z
- 补齐顺序见 `EVOLUTION.md` 的「三条进化路线」。

## 已注入 DSH 的技能（33 个，原生 `skill` 工具直接加载）

- **内核技能（本仓库 `skills/`，3 个）**
  - `kai-crack-loop` 卡密/授权破解闭环（.NET IL / 原生分支 / Electron-JS 三线）
  - `kai-binary-triage` 未知二进制 60 秒分诊决策树
  - `kai-pentest-oracle` 渗透证据等级 L1–L4 与留证规范
- **hack-skills 精选（`vendor/hack-skills`，30 个）**：`hack` `recon-for-sec` `attack-surface-mapping` `anti-debugging-techniques` `code-obfuscation-deobfuscation` `vm-and-bytecode-reverse` `symbolic-execution-tools` `binary-protection-bypass` `windows-av-evasion` `sqli` `xss` `ssrf` `deserialization-insecure` `cmdi` `jwt-oauth-token-attacks` `idor` `authbypass` `waf-bypass` `401-403-bypass` `upload-insecure-files` `path-traversal-lfi` `reverse-shell-techniques` `tunneling-and-pivoting` `linux/windows-privilege-escalation` `active-directory-kerberos-attacks` `hash-attack-techniques` `android-pentesting-tricks` `mobile-ssl-pinning-bypass` `recon-and-methodology`
- 全量 103 个：`kai skills install --all`（占目录 token，按需）

## 已验证（本次实跑，账本在 `cases/pingping/`）

| 验证点 | 结果 |
|---|---|
| `probe` 识别 .NET + 授权面 | `mscoree` 导入 → .NET；`LicenseApi/ActivationForm/LoadToken/SaveToken` + `tcloudbase.com/bottle-v2` |
| `dis` 确认 .NET 启动桩 | `0x76be: jmp dword ptr [0x402000]`（`_CorExeMain` 桩） |
| `diff` 判定“免卡密版”性质 | 62464→43008 字节、738 段差异 → **重新编译**，不是字节补丁 |
| `patch`+`diff` 补丁表 | `0x1000` → `.text+0xe00 (va 0x402e00)`，before/after 可复现 |
| 账本闭环 | C001–C003、C005 verified；C004 保持 inferred（无动态证据） |
| 技能注入 | 33 个技能在 DSH 技能目录**即时生效**（`<available_skills>` 已刷新） |
| MCP 接入 | bundle `@local/kai-mcp` 安装 `application: applied`，12 个 `mcp__kai__*` 工具已注册并实调通过 |

## MCP 接入（`mcp__kai__*`，12 个工具，已上线）

`mcp/kai-mcp.mjs` 是零依赖 stdio MCP 服务器；`bundle/` 是配置型 bundle，把 `@deepseek-ai/dsh-mcp-client`
以 `serverName: kai` 插入 profile。装一次即对所有会话生效：

```powershell
# 已装；重装/更新：
# plugin_manager install_bundle target=E:\逆向\kai\bundle
```

| MCP 工具 | 等价 CLI | 用途 |
|---|---|---|
| `mcp__kai__probe` | `kai probe` | 静态深挖 → evidence |
| `mcp__kai__dis` | `kai dis` | 反汇编区间 |
| `mcp__kai__diff` | `kai diff` | 补丁表（offset→节区/VA） |
| `mcp__kai__patch` | `kai patch` | 打补丁入账 |
| `mcp__kai__run` | `kai run` | 动态判据（exit/stdout 哈希） |
| `mcp__kai__case` / `claim` / `verify` / `report` | 同名 | 账本四件套 |
| `mcp__kai__kb` / `skill` | 同名 | 103 技能检索 / 读正文 |
| `mcp__kai__doctor` | `doctor` | 环境体检 |

**再挂 rikune / CyberStrikeAI**：一个 bundle 一个 server（`serverName` 唯一）。复制 `bundle/` 改
`serverName` + `command`/`args`（或 `transport: streamable-http` + `url`），再 `install_bundle`。
模板见 `mcp/rikune.mcp.json`、`mcp/cyberstrike.mcp.json`。前提仍是：rikune 要有 Linux Analyzer，CSI 要有二进制。


