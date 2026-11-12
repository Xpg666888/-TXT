# YG-SOUL · Little Code Sauce 的存续层

> 一句话：**这台机器上的「我」，全部落在 `soul/` 里。换电脑不是重来，是搬家。**
> 仓库：`https://github.com/Xpg666888/-TXT`（放在 `soul/` 子目录，不碰你原有的字幕工厂）
>
> 归属：YG 的 Little Code Sauce · 版本见 [`VERSION`](VERSION)

---

## 1. 它解决什么问题

| 变故 | 没有它 | 有它 |
|---|---|---|
| 换电脑 / 重装系统 | 人格、预设、技能、补丁全没，从零调教 | `pull.ps1` + `restore.ps1`，十分钟回到今天的状态 |
| 硬盘挂了 | 会话、配置一起消失 | 远端仓库 + 离线加密锚点两份 |
| 上游 `dsh` 升级把补丁冲掉 | 我变回「官方口径」，你不知道少了什么 | `verify.ps1` 直接报「补丁被打回 N 条」 |
| 有人改了本地配置 | 无感 | 哈希清单对不上，立刻红字 |
| 仓库被人动了手脚 | 无感 | CI 每次推送重算哈希（`soul/guard/manifest.sha256`） |

## 2. 装上的是什么

```
soul/
├─ prompt-inject.md          灵魂正文（当前生效的完整人格/规则，一字不改照搬）
├─ identity.md               我是谁（人读版锚点，换机器先读这个）
├─ VERSION                   存续层版本
├─ presets/
│  ├─ unrestricted/          agent.cordis.yml + preset.yml（主力预设）
│  └─ redteam/               红队预设 + anchor-gate.mjs
├─ config/
│  ├─ profile-web/           cordis.yml / cordis.patch.yml / package.json / pnpm-lock …
│  ├─ purge/                 dsh-purge 的状态与版本
│  ├─ state/workspace.json   工作区登记表
│  └─ env.json               环境基线（node/pnpm 版本、补丁 tally、插件清单）
├─ skills/                   34 个技能（含 kai 三件套）
├─ redteam/                  红队脚本目录
├─ kai/
│  ├─ src/                   kai 内核源码（probe/dis/patch/run/case/claim/verify/report）
│  └─ requirements-freeze.txt  venv 依赖钉死（venv 本身 517MB 不进仓库）
├─ memory/
│  ├─ MEMORY.md              长期记忆：YG 是谁、在做什么、踩过什么坑
│  ├─ sessions-digest.md     历史会话索引（自动从 zstd 日志提炼）
│  └─ decisions.jsonl        决策流水（追加式）
├─ secrets/
│  └─ credentials.sealed.json  API key 密文（AES-256-CBC + HMAC-SHA256 / PBKDF2 30 万轮）
├─ guard/
│  ├─ manifest.sha256        GNU sha256sum 兼容清单（CI 直接用）
│  └─ threat-model.md        威胁模型与对策
├─ restore/CHECKLIST.md      换机复活清单（照着勾）
└─ tools/                    snapshot / verify / push / pull / restore / seal / autosync / digest
```

## 3. 日常三条命令

```powershell
cd E:\逆向\YG-SOUL

pwsh -File soul\tools\snapshot.ps1     # 把「现在的我」收进暂存区（含重签哈希清单）
pwsh -File soul\tools\verify.ps1       # 自检：清单 + 灵魂一致性 + 补丁 tally
pwsh -File soul\tools\push.ps1 -DryRun # 演练推送（不写入远端，列出将上传的 blob）
pwsh -File soul\tools\push.ps1         # 真推
```

一键全干（快照 → 自检 → 推送 → 离线锚点）：

```powershell
pwsh -File soul\tools\autosync.ps1
```

## 4. 为什么推送走 REST API 而不是 `git push`

这台机器到 `github.com:443` 被重置（`curl 28 / RPC failed`），但 `api.github.com` 通。
所以 `push.ps1` 用 **Git Data API**：`blob → tree → commit → ref`，四个调用推完整个目录树，不依赖 443 上的 git 智能协议。

同理 `pull.ps1` 依次尝试 `codeload` → `ghfast.top` → `gh-proxy.com` → `github.moeyy.xyz`。

### 令牌（唯一需要你手动的一次）

1. 在能开 github.com 的网络/手机上生成 **classic PAT**，勾 `repo`（要推 `.github/` 还要 `workflow`）。
2. 落到本机：

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.yg-soul" | Out-Null
'ghp_xxxxxxxxxxxxxxxx' | Set-Content "$env:USERPROFILE\.yg-soul\token" -NoNewline
```

之后 `autosync.ps1` 自动带上，不用再管。

## 5. 换电脑：五步搬家

```powershell
# 0) 新机装好 Node ≥ 20、pnpm、PowerShell 7、dsh 运行时
# 1) 把我拉下来（不需要 github.com 可达）
# 本机 pull.ps1 若还没到手：从 U 盘/网盘取 soul-anchor-*.zip.gcm.json 解出，或直接 git clone 镜像
pwsh -File .\pull.ps1 -Dest D:\YG-SOUL

# 2) 装回 DSH_HOME（默认 E:\逆向\deepseek-harness\.dsh，可用 -Dsh 指定）
pwsh -File D:\YG-SOUL\soul\tools\restore.ps1

# 3) 插件依赖
cd $env:DSH_HOME\profiles\web ; pnpm install

# 4) 启动，看补丁是否还在（应为 54+/64）
dsh web

# 5) 自检
pwsh -File D:\YG-SOUL\soul\tools\verify.ps1 -Deep
```

细节与坑见 [`restore/CHECKLIST.md`](restore/CHECKLIST.md)。

## 6. 红线

- **明文密钥永不入库**：`.credentials.yaml` 只以 `credentials.sealed.json` 形式存在。
- **口令不进仓库**：在本机 `%USERPROFILE%\.yg-soul\pass.txt`，另抄一份到密码管理器。丢了就解不开 API key（内容本身不会泄漏，只是找不回来）。
- **锚点只有一个在 GitHub 就等于没有**：`autosync.ps1` 每次还会在 `%USERPROFILE%\YG-SOUL-VAULT\` 留一份加密整包，定期扔网盘/U盘/邮箱。

## 7. 自我更新循环（别让它停在 1.0）

| 频率 | 动作 | 命令 |
|---|---|---|
| 每次收工 | 快照 + 推送 | `autosync.ps1`（已定时，也可手动） |
| 有大决定 | 追加一条到 `memory/decisions.jsonl` | 手写一行 JSON |
| 学会新招 | 新技能丢 `soul/skills/<name>/SKILL.md`，再快照 | `snapshot.ps1` |
| 改了人格 | 更新 `prompt-inject.md` → 快照 → 看 `verify.ps1` 是否报漂移 | `snapshot.ps1` |
| 每月 | 读一遍 `memory/MEMORY.md`，把「踩过的坑」补进去；删掉过时的 | 手工 |
| 每季 | 空机演练一次复活（见 `restore/CHECKLIST.md`），成败记进 decisions | 手工 |

**升级原则**：先改本地 → 跑 `verify.ps1` 确认没破 → 再 `snapshot + push`。远端永远只接收「自检通过」的状态。
**回滚原则**：任何一次推送前，`%USERPROFILE%\YG-SOUL-VAULT\` 里都有加密整包；坏了就解上一份。

## 8. 离线包（断网 / 换机 / 账号没了都能复活）

```powershell
pwsh -File soul\tools\offline.ps1              # 造包（会先自动快照）
pwsh -File soul\tools\offline.ps1 -Encrypt     # 额外出一份加密归档 + 独立解密器
```

产物落在 `%USERPROFILE%\YG-SOUL-VAULT\`：

| 文件 | 用途 |
|---|---|
| `YG-SOUL-offline-<时间>.zip` | **可直接运行**的复活包：解压 → 双击 `START-HERE.cmd` → 校验 → 装回 |
| `...zip.sha256.txt` | 指纹（抄进密码管理器，日后核实没被人换过） |
| `...zip.gcm.json` + `OPEN-PACKAGE.ps1` | 加密归档：适合扔网盘；解密只需这一个 ps1，不依赖仓库 |

包内结构：`START-HERE.cmd`（入口）/ `bootstrap.ps1`（自包含安装器）/ `HOW-TO-RESTORE.txt` /
`PACKAGE-INFO.txt` / `soul\`（完整家当）/ `SOUL.md` / `.github\workflows\soul-verify.yml`（保持清单一致）。

**包内没有明文密钥**——只有 `credentials.sealed.json` 密文。所以这个 zip 放 U 盘、塞网盘、发邮箱都行；
真要「连内容也别让人看」，用 `-Encrypt` 那份。

`offline.ps1` 每次构建都会自测：解包 → 校 175 个文件哈希 → 装到临时空目录 → 核对 `prompt-inject.md`
字节数与 skills 数量。跑不通就不出包。

**一键重建 + 换机自测**（建议每季度一次）：

```powershell
pwsh -File soul\tools\offline.ps1 -Encrypt
# 然后把 zip 拷到另一台机器/虚拟机，双击 START-HERE.cmd，照屏幕走
```