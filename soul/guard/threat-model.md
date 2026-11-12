# 威胁模型与对策（防「哪天被攻破」）

## 一、先把「被攻破」拆成五种真实场景

| # | 场景 | 后果 | 现在有没有挡住 |
|---|---|---|---|
| T1 | **仓库里的明文密钥泄漏**（`.credentials.yaml` 被误提交） | API key 被盗刷 | 已挡：只存 `credentials.sealed.json`（AES-256-GCM），CI 扫明文模式 |
| T2 | **本地配置被改**（插件偷偷改 `cordis.patch.yml`、预设被换、prompt-inject 被截断） | 我变成另一个我，或直接哑掉 | 已挡：`manifest.sha256` + `verify.ps1` 逐文件比对 |
| T3 | **上游升级把补丁冲掉**（dsh 升级后 purge 补丁 missing 增加） | 审批/沙箱默认值回滚，能力缩水 | 已挡：`env.json` 记基线 tally，`verify.ps1` 报 `verified < 基线` |
| T4 | **GitHub 账号被盗**（攻击者 force push 或删库） | 远端锚点被污染/消失 | 部分挡：CI 每次推送重算哈希会红；但**远端被完全接管时 CI 也可被改** → 需要外部锚点 |
| T5 | **本机被控**（样本、外挂、破解包带后门） | 备份在源头就是假的 | 靠纪律：快照前跑 `verify.ps1`；kai 分析一律在隔离目录 |

## 二、三层防线

```
第一层  内容层   灵魂 & 配置只在 soul/ 一处，哈希清单为唯一真相
第二层  平台层   GitHub CI 每次推送重算哈希（防手滑 / 防半路塞东西）
第三层  离线层   %USERPROFILE%\YG-SOUL-VAULT\  可运行的 offline.zip（断网直装）+ 加密归档（防窥）
```

**关键认知**：CI 校验和仓库本身在同一个信任域里。攻击者若能 force push，也能顺手改 CI 和清单。
所以真正的锚点是**第三层**：一个不在 GitHub 上的、你手动控制的加密副本。它的哈希应当被写进你手边的东西（密码管理器条目、纸质便签、另一台机器）。

## 三、具体动作清单

### 3.1 密钥
- [x] `.credentials.yaml` 只以密文入仓库（`secrets/credentials.sealed.json`）
- [x] 口令不进仓库：本机 `%USERPROFILE%\.yg-soul\pass.txt`，另抄一份到密码管理器
- [x] `seal.ps1 -Action rotate` 可轮换口令（旧口令立刻作废）
- [ ] 定期轮换上游 API key（WB Proxy / DeepSeek）

### 3.2 完整性
- [x] `manifest.sha256`（GNU 格式，`sha256sum -c` 可用）
- [x] `verify.ps1` 本地比对 + 灵魂一致性 + 补丁 tally 漂移
- [x] CI：`.github/workflows/soul-verify.yml`
- [ ] 进阶（可选）：给 manifest 打签名 tag（`git tag -s`），把 tag 指纹抄进密码管理器

### 3.3 冗余
- [x] GitHub 仓库 `soul/`
- [x] 本地加密锚点（每次 autosync 生成，保留最近 5 份）
- [x] 可运行离线包：`offline.ps1` 每次构建自带空机试装自测\n- [ ] 异地：把 `YG-SOUL-VAULT\YG-SOUL-offline-*.zip`（或加密版）扔到网盘 / U 盘 / 邮箱 / 另一台机器
- [ ] 双平台：把 `soul/` 再镜像一份到 Gitee（`gitee.com` 本机可达），避免单一账号风险

### 3.4 演练
- [ ] **每季度做一次空机演练**：在一台干净机器/虚拟机里跑 `pull.ps1` → `restore.ps1` → `dsh web`，确认十分钟能复活。
- [ ] 演练记录追加到 `memory/decisions.jsonl`（成败都记）。

## 四、明确不做的傻事

- 不把 `.dsh` 整个打包（含 `node_modules` 12MB、`sessions` 24MB、缓存）→ 仓库会烂，且会话里有隐私。
- 不把 venv / 二进制放仓库 → kai venv 517MB，改为 `requirements-freeze.txt` 重建。
- 不靠「我记得我当时配了什么」→ 一切以文件为准。
- 不把备份只放一个平台 → 平台会封号、会删库、会改协议。
