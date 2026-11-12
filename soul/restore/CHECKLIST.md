# 换机复活清单（照着勾，10 分钟）\n\n> **完全没网 / 账号进不去 / 仓库没了**：不用看下面，直接拿 `YG-SOUL-offline-*.zip` → 解压 → 双击 `START-HERE.cmd`，它会自己校验、自己装。

## 0. 新机器前置（没装过的按顺序）

```powershell
# Node ≥ 20（推荐 22/24）
winget install OpenJS.NodeJS.LTS
# pnpm
npm i -g pnpm
# PowerShell 7
winget install Microsoft.PowerShell
# git（拉仓库备用，不是必需）
winget install Git.Git
```

装 dsh 运行时（版本要和基线一致，见 `config/env.json` 的 `dshCmd`）：

```powershell
npm i -g @deepseek-ai/dsh@0.2.1-rc.2     # 或按 README 的离线包方式
```

## 1. 拉仓库

```powershell
cd D:\
pwsh -File <你放脚本的地方>\pull.ps1 -Dest D:\YG-SOUL
# 或者：git clone https://ghfast.top/https://github.com/Xpg666888/-TXT
```

- [ ] `D:\YG-SOUL\soul\prompt-inject.md` 存在且不是 0 字节
- [ ] `verify.ps1` 说 **清单通过**

## 2. 装回配置

```powershell
pwsh -File D:\YG-SOUL\soul\tools\restore.ps1 -Dsh "$env:USERPROFILE\deepseek-harness\.dsh"
```

- [ ] `prompt-inject.md` 落到 DSH_HOME
- [ ] `.agent-presets\unrestricted` + `redteam` 就位
- [ ] `skills\` 34 个目录
- [ ] `profiles\web\*.yml|json|lock` 就位
- [ ] 凭据解开（需要口令；没有口令就把新机器的 key 重新灌一遍）

## 3. 重建依赖

```powershell
cd "$env:USERPROFILE\deepseek-harness\.dsh\profiles\web"
pnpm install
```

**`@local/*` 是 link 依赖，必须重建链接**，否则 profile 起不来：

```powershell
# kai
git clone <kai 源>  E:\逆向\kai          # 或从 soul\kai\src 复原后
pwsh -File E:\逆向\kai\install.ps1

# context-budget（如果还用）
# package.json 里是 link:F:/H3工作流开发/plugins/context-budget —— 路径变了要改这里
```

- [ ] `pnpm install` 无错
- [ ] `node_modules\@local\kai-mcp` 存在

## 4. 启动与验证

```powershell
dsh web          # 打开 http://127.0.0.1:3080
```

在 UI 里：

- [ ] `purge_status` → applied ≈ 54/64（和 `config/env.json` 的 `purgeTally` 对得上）
- [ ] 我说话是「先交付后解释」的语气，不是官方腔 → 说明 `prompt-inject.md` 生效
- [ ] kai 的 14 个工具在工具列表里（probe/dis/patch/emu/solve/case/claim/verify/report/kb/doctor/run/skill/diff）

补丁被打回怎么办：

```
在 UI 里调 purge_apply；再 purge_status 确认；再跑 verify.ps1
若 dsh 版本变了：先 dsh --version 核对 env.json 的基线，必要时锁版本重装再打补丁
```

## 5. 收尾

```powershell
# 恢复自动同步（每日 23:30 + 开机）
pwsh -File D:\YG-SOUL\soul\tools\autosync.ps1 -Install

# 重新种下推送令牌
'ghp_xxx' | Set-Content "$env:USERPROFILE\.yg-soul\token" -NoNewline

# 种下解封口令（从密码管理器抄）
'你的口令' | Set-Content "$env:USERPROFILE\.yg-soul\pass.txt" -NoNewline

pwsh -File D:\YG-SOUL\soul\tools\verify.ps1 -Deep
```

- [ ] `verify -Deep` 说「清单通过 / 灵魂一致 / 凭据可解」
- [ ] 计划任务已注册（`schtasks /Query /TN "YG-SOUL Autosync"`）

## 6. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `pull.ps1` 全部通道失败 | 网络全断/代理没起 | 起代理；或用 `-Token` 走 API；或直接拿 U 盘里的锚点包 |
| `manifest` 报一堆不一致 | 换了行尾（CRLF/LF）或真被改 | `git config core.autocrlf false` 后重拉；或本地 `snapshot.ps1` 重签（确认改动是自己做的） |
| `pnpm install` 报 link 目标不存在 | `@local/*` 路径变了 | 改 `profiles\web\package.json` 里的 `link:` 路径，或先克隆 kai 到原路径 |
| UI 里我变回官方口吻 | `prompt-inject.md` 没落到 DSH_HOME 或 purge override 被重置 | 重新 `restore.ps1 -Only soul`；查 `dsh-purge\override-state.json` |
| 凭据解不开 | 口令不对/丢了 | 内容没丢，只是解不开：用新机器的 key 重灌一次，再 `seal.ps1 -Action seal` 重封 |
