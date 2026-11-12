---
name: kai-binary-triage
description: 未知二进制 60 秒分诊决策树。用 kai probe 的字段（节区熵、RWX、加壳指纹、导入能力矩阵、overlay、TLS、PDB、字符串）判断“这是什么、值不值得深挖、下一步用哪个工具”。用于拿到陌生 exe/dll/elf/so/固件片段时的第一分钟。
---

# 未知二进制分诊（kai）

## 一条命令

```powershell
kai probe TARGET --case <case>
```

## 读表（按顺序，逐条否决）

| # | 看什么 | 判读 | 下一步 |
|---|---|---|---|
| 1 | `kind` | pe / elf / macho / unknown | unknown → `strings` + `binwalk`，可能是固件/加密容器 |
| 2 | `file_entropy` | > 7.4 且非 pe | 加密/压缩容器，先解包再谈逆向 |
| 3 | `sections[].entropy` | 某段 > 7.2 且 raw_size 大 | 该段被压缩/加密：找解压 stub，或动态 dump |
| 4 | RWX 段（findings `wx-section`） | 有 | 自解压/自改码，重点看该段 |
| 5 | `packer-section-name` | UPX/ASPack/Themida/VMProtect | UPX 直接 `upx -d`；Themida/VMProtect 走动态 dump（frida/pe-sieve） |
| 6 | `import_func_count == 0` | 无导入 | 加壳或手工解析 API：先脱壳 |
| 7 | `api_categories` | injection/hooking/network/persistence/crypto | 决定它“能干什么”，不是“干了什么” |
| 8 | `overlay.size` | > 4KB | 附加数据：安装包/签名块/dropper 二级载荷，`binwalk` 切出来 |
| 9 | `has_tls` | true | TLS 回调先于入口执行：反调试/解密常藏这里 |
| 10 | `pdb` | 有路径 | 构建环境泄露，可推断源码结构与编译选项 |
| 11 | `version_info` / `strings.urls` | 有 | 归属、后端 API、更新通道 |
| 12 | `entry_bytes` | `ff25` + mscoree | .NET → 转 `kai-crack-loop` 的 A 线 |

## 三条结论模板

- **值得深挖**：给出“哪一段、什么保护、入口在哪、下一步工具”。
- **先脱壳**：给出壳指纹 + 脱壳方案（静态/动态）+ 脱壳后复检命令（`probe` 熵应下降）。
- **不值得**：安装器/自解压/纯资源包 → 直接 `7z l` 看内容，别反编译。

## 常见坑

- `imphash` 相同 ≠ 同一家族（同一打包器会撞）。
- `.rsrc` 高熵多半是压缩过的资源或图标，不代表加壳。
- `signed=true` 只说明有签名目录，**改一个字节签名就失效**（要重签或关校验）。
- 32 位 PE 的 `entry` 是 RVA，`dis` 用 `--rva`；overlay 区域要用 `--offset`。
