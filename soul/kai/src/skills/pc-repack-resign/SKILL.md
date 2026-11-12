---
name: pc-repack-resign
description: 改包与重签名（APK 解包回包重签、PE 重签名、jar 重签）。当需要修改客户端资源/代码后让它还能安装或运行、或验证"签名校验"逻辑时使用。
---

# 改包 / 重签名

## 一、APK

### 解包 → 改 → 回包 → 重签

```powershell
sec apk app.apk                       # apktool d → app.apk.out
# 改 smali / AndroidManifest.xml / res
java -jar E:\tools\apktool.jar b app.apk.out -o repacked.apk
sec resign repacked.apk               # uber-apk-signer
adb install -r repacked.apk.signed/*.apk
```

### 只改 dex（不走 apktool）

```powershell
# 用 jadx 看逻辑，用 apktool/baksmali 改字节码
# 或用 frida 直接 hook，免改包
```

### 签名校验的三种位置

| 位置 | 特征 | 处理 |
|---|---|---|
| Java 层 `getPackageInfo(GET_SIGNATURES)` | 常见于登录/支付 | hook 或改 smali 返回原签名 |
| native 层 | `.so` 里算签名哈希 | frida hook 或 patch `.so` |
| 服务端校验 | 登录时上报签名 | 需要服务端配合，本地改包会被拒 |

## 二、PE（Windows exe/dll）

| 目的 | 做法 |
|---|---|
| 改完能跑（去掉签名校验） | patch 校验函数或跳过 WinVerifyTrust |
| 重新签名（自签） | `signtool sign /f cert.pfx /p pass /fd sha256 app.exe`（需 Windows SDK） |
| 无 SDK 时 | `osslsigncode sign -certs cert.pem -key key.pem -in app.exe -out signed.exe` |
| 仅验证签名是否有效 | `signtool verify /pa app.exe` 或 PowerShell `Get-AuthenticodeSignature` |

注意：任何字节改动都会让原签名失效；很多程序只在启动时校验一次，patch 校验调用即可。

## 三、jar / .NET

```powershell
# jar
keytool -genkeypair -alias mykey -keyalg RSA -keysize 2048 -validity 3650 -keystore my.keystore -storepass changeit -dname "CN=test"
jarsigner -keystore my.keystore -storepass changeit app.jar mykey

# .NET 强名称
sn -Vr *            # 本机跳过验证（开发用）
# 或 ilspy 重编译 + 重新签名
```

## 四、验证链（必须做）

```powershell
# 1. 改包前后哈希
Get-FileHash app.apk, repacked.apk -Algorithm SHA256

# 2. 安装并跑一遍关键路径
adb install -r repacked.apk.signed/app-signed.apk
adb logcat | Select-String -Pattern 'signature|verify|SecurityException'

# 3. 入账
kai claim add --case <case> "重签名后安装成功，登录接口未校验签名" --evidence E00x
```

## 常见坑

- apktool 回包后 `AndroidManifest` 的 `android:debuggable` 会变，可能影响行为。
- uber-apk-signer 默认 v1+v2+v3 全签；Android 11+ 需要 v2 以上。
- 改 so 后要注意 32/64 位两套库都要改。
