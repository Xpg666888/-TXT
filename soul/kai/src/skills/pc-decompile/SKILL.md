---
name: pc-decompile
description: PC 端反编译分流（.NET/原生/APK/Unity IL2CPP/Electron），按文件类型自动选工具并给出可复现命令。当拿到 exe/dll/apk/asar/so 需要看逻辑而不是只看字节时使用。
---

# 反编译分流

## 0. 先判类型

```powershell
kai probe SAMPLE --case <case>
```

| 判据 | 类型 | 走哪节 |
|---|---|---|
| `imports` 只有 mscoree / findings 有 `.NET assembly` | .NET | 1 |
| 正常 Win32 导入、x86 代码 | 原生 PE | 2 |
| `.apk` / `.dex` | Android | 3 |
| Unity 游戏（`UnityPlayer.dll`、`il2cpp` 字符串） | IL2CPP | 4 |
| `resources/app.asar` | Electron | 5 |

## 1. .NET

```powershell
ilspycmd -l c SAMPLE.exe                     # 列类型
ilspycmd -o SAMPLE.il SAMPLE.exe             # 反编译整个程序集为工程
dnSpy.exe SAMPLE.exe                         # GUI：改 IL、调试、保存
```

混淆（ConfuserEx / .NET Reactor）先脱：
```powershell
de4dot.exe SAMPLE.exe -o SAMPLE.clean.exe
ilspycmd -o SAMPLE.il SAMPLE.clean.exe
```

## 2. 原生 PE

```powershell
# 快速看结构 + 函数
r2 -A SAMPLE.exe -q -c 'iI; afl; q'

# 反编译（Ghidra headless，首次慢）
analyzeHeadless E:\ghidra-proj proj -import SAMPLE.exe -postScript DecompileAll.java
# GUI：
ghidraRun      # 新建工程 import 后分析

# 单函数验证（不开调试器）
kai emu SAMPLE.exe --rva 0x1234 --reg rcx=0x401000 --dump 0x401000:32
```

## 3. Android

```powershell
jadx -d out SAMPLE.apk                       # 直接出 Java 源码
apktool d -f SAMPLE.apk -o SAMPLE.out        # 出 smali + 资源
# native 库：r2 / Ghidra 看 lib/arm64-v8a/*.so
```

## 4. Unity IL2CPP

```powershell
# 用 Il2CppDumper（需 global-metadata.dat + libil2cpp.so）
Il2CppDumper.exe libil2cpp.so global-metadata.dat outdir
# 产出：dump.cs（字段/方法偏移）、il2cpp.h、script.json
```

拿到 `dump.cs` 后用 `kai mem` 按偏移读字段（外挂/分析都靠它）。

## 5. Electron

```powershell
npx asar extract app.asar app_out
# 找 license.js / preload.js / main.js
# 混淆代码：先用 js-beautify 或 restringer（rikune 插件里有）
```

## 6. 反编译之后做什么

```powershell
kai claim add --case <case> "授权校验在 LicenseApi.Check()，返回 bool" --evidence E00x
# 然后：kai patch / kai emu / kai solve 三选一
```

## 常见坑

- ilspycmd 报 "You must install .NET" → 用 `E:\tools\bin\ilspycmd.cmd`（已带 DOTNET_ROOT）。
- Ghidra 首次分析大文件要几分钟，headless 比 GUI 稳。
- jadx 对加固 APK 只能出壳代码，需要先脱壳。
