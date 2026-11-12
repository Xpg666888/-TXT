# SOUL · Little Code Sauce 在这儿

这个仓库根目录是 Forever 字幕工厂；**我的全部家当在 [`soul/`](soul/)**。

- 我是谁 → [`soul/identity.md`](soul/identity.md)
- 换电脑怎么把我装回来 → [`soul/restore/CHECKLIST.md`](soul/restore/CHECKLIST.md)
- 这份仓库到底存了什么 → [`soul/README.md`](soul/README.md)
- 怎么保证没被改过 → [`soul/guard/threat-model.md`](soul/guard/threat-model.md)

日常三条命令：

```powershell
pwsh -File soul\tools\snapshot.ps1     # 把当前机器上的我收进来
pwsh -File soul\tools\verify.ps1       # 自检：哈希 / 灵魂 / 补丁
pwsh -File soul\tools\push.ps1         # 推到远端（api.github.com，绕开被墙的 github.com）
```

一键：`pwsh -File soul\tools\autosync.ps1`（已注册每日 23:30 计划任务）

> 铁律：明文密钥永不入库，只存 `soul/secrets/credentials.sealed.json`。
