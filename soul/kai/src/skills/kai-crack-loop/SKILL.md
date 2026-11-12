---
name: kai-crack-loop
description: 卡密/授权/试用期破解的闭环流程（.NET IL、原生分支、JS/Electron 三类）。用 kai probe 定位授权面、dis 找校验分支、patch+diff 出补丁表、run 拿前后对照，最后 claim/verify 入账。用于“破解”“去卡密”“绕过授权”“keygen”“试用重置”等任务。
---

# 卡密 / 授权破解闭环（kai）

## 铁律

1. 先 `kai probe SAMPLE --case N`，没有证据不许下结论。
2. 每个改动都要 `kai diff` 出补丁表（offset → 节区 + VA），否则无法复现。
3. “破解成功”必须 L3 证据：`kai run` 改动前拒绝 + 改动后通过，两条都入账。
4. 只动副本，`_original` 只读。

## 第 0 步：判类型（决定后面整条路）

```powershell
kai probe SAMPLE.exe --case <case>
```

看三个字段：

| 观察 | 结论 | 走哪条 |
|---|---|---|
| `findings` 含 `.NET assembly` 或 imports 只有 `mscoree.dll` | .NET/IL | A 线 |
| `entry_bytes` 以 `ff25` 开头且导入 `_CorExeMain` | .NET 启动桩 | A 线 |
| 正常 x86/x64 + 大量 Win32 导入 | 原生 | B 线 |
| `strings.urls` 有 `tcloudbase/vercel/api` 且 `.js` 资源 | Electron/JS | C 线 |
| `.rsrc` 熵 > 7.5 且 `overlay` 很大 | 资源里藏东西/自解压 | 先 `binwalk`/`7z l` |

## A 线：.NET / IL

1. 找授权面：`strings.interesting` 里的 `License*`、`Token*`、`Activate`、`Check`、`Status`。
2. 反编译：dnSpy / ilspycmd（`dotnet tool install -g ilspycmd`）→ 定位返回 bool 的校验方法。
3. 三种改法，优先序：
   - **改 IL 常量**：`ldc.i4.0` → `ldc.i4.1`（0x16→0x17），只改一个字节，最干净。
   - **改方法体**：`ret` 前插 `ldc.i4.1; ret`（需要重算方法体头/大小，用 dnSpy 保存更稳）。
   - **改强名称**：改完必须去强名称或重签，否则加载失败（`sn -Vr *` 或 ilspy 重编译）。
4. 记录：`kai patch` 的 offset 必须是**文件偏移**；dnSpy 给的是 RVA，用
   `kai dis SAMPLE --rva <RVA>` 反查指令字节，再算文件偏移。
5. 验证：`kai run -- SAMPLE.exe`（或带 `--check` 之类参数）比较改动前后输出。

## B 线：原生分支

1. `kai probe` 拿 `api_categories`：有 `crypto` → 校验可能本地算哈希；有 `network` → 远端验签。
2. 定位：`strings` 找提示语（"卡密错误"/"已过期"/"Invalid"），用 `kai run` 触发它，配合 x64dbg 下断在 `MessageBoxA`/`CreateFile`。
3. 常见可 patch 点：
   - `test al,al; jz fail` → 改 `jz` 为 `jmp`（0x74→0xEB）或 NOP 掉 test（0x84→0x90 等长）。
   - `cmp eax,1; jne fail` → 改 `jne`（0x75→0xEB）。
   - 返回值：函数尾部 `xor eax,eax; ret` → `mov eax,1; ret`（注意长度，必要时用 `push 1; pop eax`）。
4. `kai patch SAMPLE --offset 0x.. --bytes "EB" --out SAMPLE.patched --case <case>`
5. `kai diff SAMPLE SAMPLE.patched --case <case>` → 补丁表进账。
6. `kai run -- SAMPLE.patched ...` 与 `kai run -- SAMPLE ...` 对照。

## C 线：Electron / JS

1. `probe` 的 `strings.urls` 给出后端；`_internal`/`resources/app` 里找 `license.js`、`redesign.js`。
2. JS 是明文就直接读逻辑；asar 打包用 `npx asar extract app.asar out`。
3. 改 JS 后要防完整性校验：搜 `integrity`、`hash`、`sha256`；有就同步改校验值或 patch 掉校验函数。
4. 验证：`kai run -- <app>.exe` 观察 UI/日志；必要时用 CDP 抓渲染进程日志。

## 收尾（必须做）

```powershell
kai claim add --case <case> "授权校验在 X 方法，patch 后不再弹激活窗" --evidence E00x
kai verify C00x --case <case> --evidence E00x,E00y --note "kai run 前后对照"
kai report --case <case>
```

报告里写清：**改了什么（offset/字节/节区）、为什么这么改（控制流事实）、怎么验证的（两次 run 的输出差异）**。
