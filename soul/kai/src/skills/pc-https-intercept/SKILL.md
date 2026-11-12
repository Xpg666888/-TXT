---
name: pc-https-intercept
description: PC 端抓 HTTPS 包（mitmproxy 一键代理、CA 安装、Android/iOS 证书、证书固定 pinning 绕过）。当目标是 App/桌面客户端且流量走 TLS、需要看明文或改包时使用。
---

# 抓 HTTPS 包（mitmproxy）

## 1. 起代理

```powershell
sec https 8080
# 等价：mitmdump --listen-port 8080 --set block_global=false
```

- 浏览器/客户端代理设成 `127.0.0.1:8080`（远程设备用本机 IP）。
- 图形界面：`mitmweb --listen-port 8080`（浏览器打开 127.0.0.1:8081）。

## 2. 装 CA 证书

| 端 | 做法 |
|---|---|
| Windows 浏览器 | 访问 `http://mitm.it` → 下载 Windows 证书 → 导入「受信任的根证书颁发机构」 |
| Android 7+ | 用户证书默认不被 App 信任 → 需 root 后放 `/system/etc/security/cacerts/`（或用 frida 绕过） |
| iOS | 装描述文件后还要在「通用 › 关于本机 › 证书信任设置」里手动开启 |
| 桌面客户端（Electron/Qt） | 多数走系统证书库；个别内置 CA 需要 hook |

CA 文件位置：`%USERPROFILE%\.mitmproxy\mitmproxy-ca-cert.cer`

## 3. 客户端不认代理 / 证书固定（pinning）

按平台分流：

```text
Android (Java/Kotlin)：frida -U -f pkg -l pinning_bypass.js
Android (Flutter/RN)：hook BoringSSL 的 SSL_verify_cert_chain
iOS：frida hook SecTrustEvaluate
Electron：启动参数 --ignore-certificate-errors（仅调试）
原生 Win 客户端：hook CertVerifyCertificateChainPolicy / WinHttp 回调
```

skill 索引：`mobile-ssl-pinning-bypass`（hack-skills）里有完整脚本清单。

## 4. 改包（不只是看）

```powershell
# 用脚本改响应
mitmdump -s rewrite.py --listen-port 8080
```
```python
# rewrite.py
from mitmproxy import http
def response(flow: http.HTTPFlow):
    if "/api/license" in flow.request.pretty_url:
        flow.response.text = '{"ok":true,"plan":"pro"}'
```

## 5. 与 kai 账本联动

```powershell
# 抓到的关键请求用 kai run 复现，形成可入账的证据
kai run --case <case> -- curl -sS -i -x http://127.0.0.1:8080 https://TARGET/api/...
kai claim add --case <case> "授权接口返回 plan 字段可被本地改写" --evidence E00x
```

## 常见坑

- 只看到 CONNECT 没有明文：客户端没信任 CA。
- 某些 App 走 QUIC/UDP 443：mitmproxy 抓不到，需要禁用 QUIC 或改用其他方案。
- 时间不同步会导致证书校验失败（尤其 Android 模拟器）。
