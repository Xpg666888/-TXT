---
name: pc-unpack
description: PC 端脱壳流程（UPX 及魔改 UPX、VMProtect/Themida 识别、内存 dump）。当样本 probe 显示高熵节区、packer 指纹、导入表异常或"UPX 解出来是乱码"时使用。产出：脱壳后的二进制 + 节区熵下降的对照证据。
---

# PC 脱壳（UPX / 魔改 UPX / 商业壳）

## 0. 先判定是不是壳

```powershell
kai probe SAMPLE.exe --case <case>
```

| 现象 | 判断 |
|---|---|
| 节区名 `UPX0/UPX1` | 标准 UPX（可能被魔改节区名） |
| 节区名 `.vmp0/.vmp1` | VMProtect |
| `.themida`/`.enigma` | Themida / Enigma |
| 导入表几乎为空 + 入口在最后一段 | 自解压 / 加壳 |
| `.text` 熵 > 7.2 但文件有 overlay | 资源加密或二次载荷 |

`upx -l SAMPLE.exe` 能识别标准 UPX（包括改了节区名的）。

## 1. 标准 UPX

```powershell
sec unpack SAMPLE.exe
# 等价于：
copy SAMPLE.exe SAMPLE.unpacked.exe
upx -d SAMPLE.unpacked.exe
kai probe SAMPLE.unpacked.exe --case <case>     # 熵应明显下降
```

判据：解壳后 `.text` 熵 < 6.5、导入表恢复、文件变大。

## 2. 魔改 UPX（`upx -d` 报 "CantUnpackException"）

原因：作者改了 UPX 头（magic `UPX!` 被改、节区名改、压缩算法改）。

做法：
1. 搜 `UPX!` 特征是否还在；在就用十六进制改回来再试。
2. 找 UPX 版本：`upx -l` 或文件里的 "UPX 3.96" 字样，用对应版本。
3. 都不行 → 内存 dump（下面第 4 节）。

## 3. VMProtect / Themida / Enigma

**不要试图静态脱**。做法：
- 动态：跑起来到 OEP 附近，用 pe-sieve / Scylla dump + 修复 IAT。
- 只关心算法时：`kai emu` 直接调用解密/校验函数，绕开整个壳。

## 4. 内存 dump（通用兜底）

```powershell
Start-Process SAMPLE.exe
pe-sieve64.exe /pid <PID> /out E:\dump\out
# 或：pe-sieve64.exe /pid <PID> /dmode 3   （含 PE 重建）
```

产物：`<pid>_<addr>.exe` + `*.dll`，再 `kai probe` 检查熵/IAT。

## 5. frida 辅助（解自解密段）

```javascript
// hook VirtualProtect，抓 "改成可执行" 的那段内存
Interceptor.attach(Module.getExportByName('kernel32.dll','VirtualProtect'), {
  onEnter(a){ this.p=a[0]; this.s=a[1]; this=np=a[3]; },
  onLeave(){ if (this.np & 0x20) { console.log('RWX', this.p, this.s);
    send('dump', Memory.readByteArray(this.p, this.s)); } }
});
```

## 6. 收尾：把证据入账

```powershell
kai claim add --case <case> "样本使用魔改 UPX，内存 dump 后 .text 熵 7.8→5.9" --evidence E00x
kai verify C00x --case <case> --evidence E00x --note "pe-sieve /pid 1234"
```

## 常见坑

- `upx -d` 成功但运行崩溃：IAT 被改过，需要修复导入表。
- dump 出来的文件比原文件大很多：包含运行时数据，需要按节区裁剪。
- 脱壳后仍有高熵段：可能是资源（图标/字体）或第二层加密，不是壳没脱干净。
