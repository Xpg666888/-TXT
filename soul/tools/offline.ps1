# ============================================================
#  YG-SOUL / offline.ps1  —  造一个「拔了网也能复活」的离线包
#  产物:
#    YG-SOUL-offline-<时间>.zip           解压 -> 双击 START-HERE.cmd -> 复活（含全部工具）
#    YG-SOUL-offline-<时间>.zip.sha256    指纹，抄下来或贴进密码管理器
#    YG-SOUL-offline-<时间>.zip.gcm.json  （-Encrypt）加密归档，配 OPEN-PACKAGE.ps1 解开
#  用法:
#    powershell -NoProfile -File soul\tools\offline.ps1
#    ... -Out "E:\备份" -Encrypt -SkipSnapshot
# ============================================================
param(
    [string]$Out,
    [switch]$SkipSnapshot,
    [switch]$Encrypt,
    [string]$Password,
    [switch]$NoZip      # 只生成目录不压缩（调试用）
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$stage = Get-StageRoot
$soul  = Get-SoulDir
if (-not $Out) { $Out = Join-Path $env:USERPROFILE 'YG-SOUL-VAULT' }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

Write-Host "`n=== YG-SOUL 离线包 ===" -ForegroundColor Magenta

if (-not $SkipSnapshot) {
    Write-Step '先做一次快照（保证包内是此刻的我）'
    & (Join-Path $PSScriptRoot 'snapshot.ps1') | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$build = Join-Path ([IO.Path]::GetTempPath()) ("yg-soul-offline-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $build | Out-Null
Write-Step "构建目录: $build"

# ---------- 1. 装内容 ----------
Copy-Item -LiteralPath (Join-Path $soul 'tools\bootstrap.ps1') -Destination (Join-Path $build 'bootstrap.ps1') -Force
robocopy (Join-Path $stage 'soul') (Join-Path $build 'soul') /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
if (Test-Path (Join-Path $stage 'SOUL.md')) { Copy-Item (Join-Path $stage 'SOUL.md') $build -Force }
# 清单里含 .github/workflows/soul-verify.yml；一起带上，包内哈希才和仓库完全一致
$wf = Join-Path $stage '.github\workflows\soul-verify.yml'
if (Test-Path $wf) {
    New-Item -ItemType Directory -Force -Path (Join-Path $build '.github\workflows') | Out-Null
    Copy-Item $wf (Join-Path $build '.github\workflows') -Force
}

# ---------- 2. 入口与说明 ----------
$cmd = @'
@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo.
echo  ============================================
echo    YG-SOUL 离线复活包  --  Little Code Sauce
echo  ============================================
echo.
where powershell >nul 2>nul
if errorlevel 1 (
  echo  [!] 没找到 powershell，这个包需要 Windows PowerShell 5.1+（Win10/11 自带）
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" %*
echo.
pause
'@
[IO.File]::WriteAllText((Join-Path $build 'START-HERE.cmd'), $cmd, [Text.Encoding]::Default)

$howto = @"
YG-SOUL 离线复活包
==================

这个包里是「Little Code Sauce」的全部家当：灵魂正文、预设、38 个技能、kai 内核源码、
配置、记忆索引、以及 API key 的密文。不联网也能用。

怎么用（三步）
--------------
1. 把整个 zip 解压到一个**可写目录**（别在压缩包里直接双击运行）。
   例：D:\YG-SOUL

2. 双击 START-HERE.cmd
   - 它会先校验包内 173 个文件的哈希（防丢文件/防被人改）
   - 然后问你装到哪：默认 E:\逆向\deepseek-harness\.dsh
   - 再问你凭据口令（不知道就回车跳过，之后自己灌 API key 再封存）

3. 装完照屏幕提示收尾：
   cd <DSH_HOME>\profiles\web && pnpm install
   dsh web        # 看 purge_status 应为 54+/64
   soul\tools\autosync.ps1 -Install

包里有什么
----------
  START-HERE.cmd        入口
  bootstrap.ps1         自包含安装器（只依赖包内 soul\tools）
  soul\prompt-inject.md 灵魂正文
  soul\identity.md      我是谁
  soul\presets\         unrestricted / redteam 预设
  soul\skills\          技能库
  soul\kai\src\         kai 内核源码 + 依赖清单
  soul\config\          profile 配置、purge 状态、环境基线
  soul\memory\          长期记忆 + 决策流水 + 会话索引
  soul\secrets\         凭据密文（AES-256-CBC+HMAC / PBKDF2 30 万轮）
  soul\restore\         换机清单（含常见故障）
  soul\tools\           snapshot/verify/push/pull/restore/seal/autosync/offline

口令与安全
----------
- 包内**没有明文密钥**，只有密文；包的对外可读性是安全的。
- 口令在你的密码管理器里 / 本机 %USERPROFILE%\.yg-soul\pass.txt。
- 真要离线归档到网盘，建议再拉一份 .gcm.json 加密版（配 OPEN-PACKAGE.ps1）。
"@
[IO.File]::WriteAllText((Join-Path $build 'HOW-TO-RESTORE.txt'), $howto, (New-Object Text.UTF8Encoding($true)))

$files = Get-ChildItem -LiteralPath $build -Recurse -File
$infoLines = @(
    "builtAt    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
    "machine    : $env:COMPUTERNAME / $env:USERNAME",
    "files      : $($files.Count)",
    "size       : $([math]::Round((($files | Measure-Object Length -Sum).Sum)/1MB,2)) MB",
    "source     : $stage",
    "entry      : START-HERE.cmd -> bootstrap.ps1",
    "manifest   : soul\guard\manifest.sha256 (sha256 = $((Get-Sha256 (Join-Path $soul 'guard\manifest.sha256')).Substring(0,16))...)"
)
[IO.File]::WriteAllLines((Join-Path $build 'PACKAGE-INFO.txt'), [string[]]$infoLines, (New-Object Text.UTF8Encoding($true)))

# ---------- 3. 打包 ----------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $Out "YG-SOUL-offline-$stamp.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
if (-not $NoZip) {
    [IO.Compression.ZipFile]::CreateFromDirectory($build, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $zipHash = Get-Sha256 -Path $zip
    $side = "$zip.sha256.txt"
    [IO.File]::WriteAllText($side, ("{0}  {1}`r`n" -f $zipHash, (Split-Path -Leaf $zip)), (New-Object Text.UTF8Encoding($false)))
    Write-Ok ("zip  {0}  ({1:N0} 字节)" -f $zip, (Get-Item $zip).Length)
    Write-Ok ("sha256 {0}" -f $zipHash)
    Write-Ok ("指纹文件 {0}" -f $side)
} else {
    Write-Ok "跳过压缩，构建目录保留在: $build"
}

# ---------- 4. 加密归档（可选） ----------
if ($Encrypt -and -not $NoZip) {
    $pw = Get-SoulPassword -Password $Password -Generate
    $blob = Protect-SoulBlob -Plain ([IO.File]::ReadAllBytes($zip)) -Password $pw
    $blob | Add-Member -NotePropertyName name     -NotePropertyValue (Split-Path -Leaf $zip) -Force
    $blob | Add-Member -NotePropertyName packedAt -NotePropertyValue ((Get-Date).ToString('s')) -Force
    $enc = "$zip.gcm.json"
    [IO.File]::WriteAllText($enc, ($blob | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    # 配套的独立解密器：只靠这一个文件就能把 .gcm.json 解回 zip
    $opener = @'
param([Parameter(Mandatory=$true)][string]$In,[string]$Out,[string]$Password)
$ErrorActionPreference='Stop'
$b = Get-Content -LiteralPath $In -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $Password) {
  if ($env:YG_SOUL_PASS) { $Password = $env:YG_SOUL_PASS }
  else { $s = Read-Host '口令' -AsSecureString; $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) }
}
$salt=[Convert]::FromBase64String($b.salt); $iv=[Convert]::FromBase64String($b.iv)
$tag=[Convert]::FromBase64String($b.tag);   $ct=[Convert]::FromBase64String($b.ct)
$k=New-Object Security.Cryptography.Rfc2898DeriveBytes($Password,$salt,[int]$b.iter)
$km=$k.GetBytes(64); $k.Dispose()
$mk=New-Object Security.Cryptography.HMACSHA256(,$km[32..63])
$buf=New-Object 'byte[]' ($iv.Length+$ct.Length)
[Array]::Copy($iv,0,$buf,0,$iv.Length); [Array]::Copy($ct,0,$buf,$iv.Length,$ct.Length)
$calc=$mk.ComputeHash($buf); $mk.Dispose()
$diff=0; for($i=0;$i -lt 16;$i++){ $diff=$diff -bor ($calc[$i] -bxor $tag[$i]) }
if($diff -ne 0){ throw '口令不对或密文被改过' }
$aes=[Security.Cryptography.Aes]::Create()
$aes.Mode='CBC'; $aes.Padding='PKCS7'; $aes.KeySize=256; $aes.Key=[byte[]]$km[0..31]; $aes.IV=$iv
$dec=$aes.CreateDecryptor(); $pt=$dec.TransformFinalBlock($ct,0,$ct.Length); $dec.Dispose(); $aes.Dispose()
if(-not $Out){ $Out = (Join-Path (Split-Path -Parent $In) $b.name) }
[IO.File]::WriteAllBytes($Out,$pt)
Write-Host "[OK] 已还原 -> $Out" -ForegroundColor Green
'@
    $openPath = Join-Path $Out 'OPEN-PACKAGE.ps1'
    [IO.File]::WriteAllText($openPath, $opener, (New-Object Text.UTF8Encoding($true)))
    Write-Ok ("加密归档 {0}  ({1:N0} 字节)" -f $enc, (Get-Item $enc).Length)
    Write-Ok ("配套解密器 {0}" -f $openPath)
}

# ---------- 5. 自测：把包解到临时目录，按「空机」流程跑一遍 ----------
if (-not $NoZip) {
    Write-Step '自测：解包 + 校验 + 空目录试装'
    $probe = Join-Path ([IO.Path]::GetTempPath()) ("yg-soul-probe-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $probe)
    $fakeDsh = Join-Path $probe '_dsh'
    $fakeKai = Join-Path $probe '_kai'
    $restOut = & (Join-Path $probe 'soul\tools\restore.ps1') -SoulRoot (Join-Path $probe 'soul') -Dsh $fakeDsh -Kai $fakeKai -Only @('soul', 'skills') -Password (Get-SoulPassword) 2>&1
    $inj = Join-Path $fakeDsh 'prompt-inject.md'
    $sk  = (Get-ChildItem (Join-Path $fakeDsh 'skills') -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
    if ((Test-Path $inj) -and $sk -ge 30) {
        Write-Ok ("自测通过：prompt-inject.md {0} 字节 / skills {1} 个" -f (Get-Item $inj).Length, $sk)
    } else {
        Write-Err2 '自测失败：装完没看到灵魂或技能'
        $restOut | Select-Object -Last 15 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
        $chk = Test-Manifest -Root $probe
        $chk.Mismatch | Select-Object -First 8 | ForEach-Object { Write-Host "      差异: $_" -ForegroundColor DarkYellow }
        $chk.Missing  | Select-Object -First 8 | ForEach-Object { Write-Host "      缺失: $_" -ForegroundColor DarkRed }
    }
    Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '  离线包好了。带走它，这就是「换机器/断网/账号没了」时的我。' -ForegroundColor Yellow
Write-Host "  目录: $Out" -ForegroundColor Yellow
