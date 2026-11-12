# 凭据封装说明

**这里只允许出现密文。**

## 文件

| 文件 | 内容 |
|---|---|
| `credentials.sealed.json` | `<DSH_HOME>\.credentials.yaml` 的 AES-256-CBC + HMAC-SHA256 密文（Encrypt-then-MAC） |

格式：

```json
{
  "v": 1,
  "kdf": "PBKDF2-SHA1",
  "iter": 300000,
  "alg": "AES-256-CBC+HMAC-SHA256",
  "salt": "base64", "iv": "base64", "tag": "base64", "ct": "base64",
  "len": 541,
  "source": "dsh/.credentials.yaml",
  "sealedAt": "2026-11-13T01:10:00+08:00"
}
```

- 盐 16 字节、IV 16 字节、HMAC 32 字节，每次封存随机。
- Encrypt-then-MAC：先验 HMAC 再解密，口令错或密文被改都会直接抛异常，不会静默解出垃圾。
- 30 万轮 PBKDF2-SHA1；离线爆破成本按「强口令」算可忽略，按「123456」算等于裸奔 → **口令要长**。

## 口令在哪

```
%USERPROFILE%\.yg-soul\pass.txt        # 本机副本（snapshot 时自动生成/复用）
```

**必须另抄一份到密码管理器。** 仓库被攻破拿到的只是密文；口令丢了丢的是「能不能解」，不是「别人能不能解」。

## 常用命令

```powershell
# 封存（默认取 DSH_HOME\.credentials.yaml）
pwsh -File soul\tools\seal.ps1 -Action seal

# 开封到指定位置
pwsh -File soul\tools\seal.ps1 -Action unseal -Out "D:\.dsh\.credentials.yaml"

# 换口令（旧口令立即作废）
pwsh -File soul\tools\seal.ps1 -Action rotate

# 演练：能不能解开
pwsh -File soul\tools\verify.ps1 -Deep
```

## 环境变量覆盖

- `YG_SOUL_PASS` — 临时用口令（优先级高于 pass.txt）
- `GITHUB_TOKEN` / `GH_TOKEN` — 推送令牌，也可写 `%USERPROFILE%\.yg-soul\token`

## 绝对禁止

- 把 `.credentials.yaml`、`pass.txt`、`token` 复制进这个目录。
- 把口令写进任何会被 git 看到的文件（包括 `cordis.patch.yml` 注释）。
- 用截图/聊天记录当口令保管方式。
