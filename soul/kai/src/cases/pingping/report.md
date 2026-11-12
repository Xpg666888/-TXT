# 分析报告 — pingping

生成时间：2026-11-11T08:00:41.970Z

## 样本

| 类型 | 大小 | SHA-256 | 路径 |
|---|---|---|---|
| pe | 61.0KB | `0cc758e4beaf31d82988560f7f51becf30302ae3e4bde4e2df960a1a90667a47` | E:\逆向\瓶瓶下载器-复原\_original\瓶瓶下载器-1.2-最终版-新版UI客户端\瓶瓶下载器.exe |

## 结论（只收录有证据的）

- **C001** 样本为 .NET 程序集（mscoree 导入 + .NET 元数据），破解应走 IL 层而非 x86 原生补丁
  - 证据：E001
  - 复现：`kai probe ... --case pingping`
- **C002** 授权逻辑位于 LicenseApi/ActivationForm/LoadToken/SaveToken，远端为 tcloudbase.com/bottle-v2
  - 证据：E001
- **C003** 免卡密版与原版不是同一构建：体积 62464→43008、738 段差异，属于重新编译而非定点字节补丁
  - 证据：E002
  - 复现：`kai diff orig patched`
- **C005** 工具链自检：.text+0xe00 处 2 字节替换可被 diff 精确定位到 VA 0x402e00，补丁可复现
  - 证据：E004
  - 复现：`kai patch --offset 0x1000 --bytes 9090 && kai diff`

## 待验证假设

- C004 [inferred] 本地校验点位于 .text 段，需定位 LicenseStatus 返回值分支后 patch

## 证据清单

| ID | 类型 | 摘要 | 产物 |
|---|---|---|---|
| E001 | probe | {"kind":"pe","findings":2,"severity_max":"medium","sections":3,"imports":1} | artifacts\probe-瓶瓶下载器.exe-0cc758e4beaf.json |
| E002 | diff |  | artifacts\diff-0cc758e4-99830c5e.json |
| E003 | patch | 0000 → 9090 |  |
| E004 | diff |  | artifacts\diff-0cc758e4-461e6f0c.json |
