# EVOLUTION — 为什么这四个项目叠起来还不够，以及怎么补

## 一、诊断：四个项目各自缺什么

| 项目 | 它真正强的地方 | 单独用起来的断点 |
|---|---|---|
| **rikune** | 二进制全链路：sample 保管 → 静态 triage → Ghidra 函数恢复 → 插件（117 个）→ 动态 Windows 沙箱；Case/Claim/Evidence 的账本设计非常成熟 | v1.4 起 **Analyzer 必须跑在 Linux kernel**（原生 Linux / 容器 / WSL2）。本机没有 docker、没有 WSL 发行版、没有 ghidra → 装得上但跑不动；它是“重型专业台”，不是随手能用的扳手 |
| **CyberStrikeAI** | 渗透编排：Eino 多智能体（Deep/Plan-Execute/Supervisor）、100+ YAML 工具配方、攻击链图谱、资产库、WebShell/C2、人审闸门 | 需要 Go 1.25 构建或 release 二进制，且**工具配方只是壳**——nmap/sqlmap/nuclei/ffuf 这些二进制本机一个都没有，等于“枪架没有枪”；Web 控制台还自带登录/RBAC，离命令行作业很远 |
| **yaklang/hack-skills** | 103 个 SKILL.md 方法论（Web/API/认证/提权/AD/移动/二进制/Pwn/逆向/密码/取证/AI 安全），压缩得极好、路由清晰 | 它**只是知识**。模型读完知道“该怎么做”，但本机没有执行体、没有判据，仍然会给你一份“看起来对”的答案 |
| **dsh-purge** | 把 DSH 宿主的提示词/审批/沙箱权威清洗掉（63 个 patch），让“操作者意图优先” | 它管的是**宿主行为**，与具体技术能力正交；本机现状是 4/63 applied，其余 55 个 pending——它解决“让不让干”，不解决“干得准不准” |

一句话：**rikune 是手术台，CyberStrikeAI 是手术室调度，hack-skills 是教科书，dsh-purge 是门禁卡。缺的是主刀医生的手感判据——也就是“怎么知道自己真的做对了”。**

## 二、真正的差距不在工具数量，在四个“闭环缺口”

1. **判据缺口（oracle）**：模型说“这个分支改成 jmp 就免卡密了”，谁验证？没有字节级 diff、没有返回值观测，就只能靠嘴。
2. **记忆缺口（ledger）**：一次会话结束，结论、偏移、样本哈希全丢；下次从零开始，还容易把“上次好像试过”当事实。
3. **路由缺口（router）**：手里有 4 个后端 + 103 个技能，遇到“一个 .NET 卡密客户端”该走哪条？没有路由表就会拿最熟的工具硬套。
4. **自举缺口（bootstrap）**：缺 ghidra/ghidra 装不上时，能不能用 capstone + 自己写的脚本顶上？不能自举的后端等于没有。

## 三、kai 的补齐方式（已落地、已跑通）

```
              ┌──────────────────────────────────────────────┐
              │  ROUTER  任务 → 链路（谁适合干、缺什么就降级）  │
              └───────────────┬──────────────────────────────┘
                              ▼
   ┌──────────┐   ┌────────────────────┐   ┌──────────────────┐
   │ 知识层    │   │ 执行层              │   │ 判据层            │
   │ hack-    │──▶│ kai probe/dis/patch │──▶│ diff / run /      │
   │ skills   │   │ + rikune / CSI /    │   │ probe 事实         │
   │ 103 技能  │   │ 本机 python venv    │   │ （机器可读）       │
   └──────────┘   └────────────────────┘   └────────┬─────────┘
                                                   ▼
                                    ┌──────────────────────────┐
                                    │ 账本层 case/claim/evidence │
                                    │ 只有 verified 进报告        │
                                    └──────────────────────────┘
```

- **判据层**：`kai probe` 给事实（节区熵/RWX/加壳指纹/导入能力矩阵/overlay/TLS/PDB/字符串），`kai diff` 给补丁表（offset → 节区+VA），`kai run` 给动态判据（exit/stdout 哈希）。
- **账本层**：`claims.jsonl` 三态（inferred → supported → verified），`verify` 强制要求 evidence id，`report` 只收 verified。
- **路由层**：`kernel/ROUTER.md` 把“样本类型 × 目标”映射到链路，并写明降级路径（没 ghidra → capstone+符号执行；没 docker → 本地 venv）。
- **知识层**：103 个 hack-skills 离线在 `vendor/`，精选 30 个已注入 `$DSH_HOME/skills`，DSH 原生 `skill` 工具**当场生效**（本次会话技能目录已刷新，可直接 `skill` 加载 `anti-debugging-techniques` 等）。

## 四、三条进化路线（按性价比排序）

### 路线 A：本地闭环拉满（零成本，今天就能用）
1. `kai doctor` 看缺口；`kai skills install --all` 把 103 个技能全注入（会吃目录 token，按需）。
2. 用 `pwsh` + venv 顶替缺失工具：`pefile/lief` 顶 PE 解析，`capstone` 顶 r2，`pyelftools` 顶 readelf，`requests` 顶 curl 编排。
3. 动态侧最便宜的一步：`uv tool install frida-tools` + `winget install --id Python.Python.3.13`（frida 需要真 Python 的 DLL 加载能力），拿到 SSL pinning / 运行时 hook。
4. 渗透侧最小可用集：`winget install nmap` + `uv tool install sqlmap`（或 pip）+ 单文件 ffuf/nuclei（GitHub release 直接下载 exe，无需 Go）。

### 路线 B：接上 rikune（重，但拿到“专业台”）
rikune 的 Analyzer 要 Linux kernel，本机两条路：
1. **WSL2**：`wsl --install -d Ubuntu` → 在 WSL 里 `npm i -g rikune` → MCP stdio 起 `rikune`（数据根放 ext4，别放 `/mnt/e`）。
2. **Docker Desktop**：`winget install Docker.DockerDesktop` → `.\rikune.ps1 install -Profile static -DataRoot D:\Docker\rikune` → 静态分析先跑通，再考虑 hybrid + Windows Sandbox 做动态。
接法见 `mcp/rikune.mcp.json`。价值：Ghidra 函数恢复、117 插件、Case/Claim 账本（和 kai 的账本语义可以对齐：rikune 的 artifact → kai 的 evidence）。

### 路线 C：接上 CyberStrikeAI（重，但拿到“渗透编排”）
1. 不装 Go 就走 release 二进制（`cyberstrike-ai.exe`），`config.yaml` 里配一个 OpenAI 兼容通道（你本机 8788 的 wb-proxy 就能直接用）。
2. 工具配方要真装：nmap/sqlmap/ffuf/nuclei/subfinder/httpx 优先，其它按需。
3. 它的价值在**攻击链 + 资产库 + 人审**，不在单点工具；把 kai 当它的“判据旁路”：CSI 产出的每条 finding，用 `kai run`/`kai probe` 复核后入 kai 账本。
接法见 `mcp/cyberstrike.mcp.json`。

### 横切：dsh-purge 剩余 55 个 patch
`purge_status` 现在 4/63。要不要全打取决于你想让宿主让到哪一步；`kai` 与它无关，打不打都能用。打之前建议先备份（`purge_revert` 可回滚）。

## 五、验收标准（怎么算“进化成功”）

- 给一个陌生 PE：`kai probe` 3 秒内出架构/加壳/能力矩阵/可疑字符串，且 evidence 入账。
- 给一个卡密校验点：能给出 `offset + 节区 + VA + before/after` 的补丁表，并在 `run` 里拿到“补丁前拒绝 / 补丁后通过”的两次输出。
- 给一个 Web 目标：`skill` 加载 `hack`/`recon-for-sec` 路由，产出攻击面图 + 每条结论有请求/响应证据。
- 换一台机器：`kai doctor` 一条命令说清缺什么、怎么补，不需要重新摸索。
