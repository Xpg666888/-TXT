# ============================================================
#  YG-SOUL / bootstrap.ps1  —  离线包入口（自包含，不依赖仓库/网络）
#  这个文件会被 offline.ps1 打进离线包根目录；解压后双击 START-HERE.cmd 即可
#  用法:  powershell -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1
#         ... -Dsh "D:\xxx\.dsh" -Kai "D:\kai" -DryRun
# ============================================================
param(
    [string]$Dsh,
    [string]$Kai,
    [string]$Password,
    [switch]$DryRun,
    [switch]$SkipSecrets,
    [switch]$SkipKai
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$soul = Join-Path $here 'soul'
$lib  = Join-Path $soul 'tools\lib.ps1'
$rest = Join-Path $soul 'tools\restore.ps1'
$ver  = Join-Path $soul 'tools\verify.ps1'

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Magenta
Write-Host '   YG-SOUL 离线复活包  ·  Little Code Sauce' -ForegroundColor Magenta
Write-Host '=====================================================' -ForegroundColor Magenta

if (-not (Test-Path $lib)) {
    Write-Host "  [X] 包不完整：找不到 soul\tools\lib.ps1" -ForegroundColor Red
    Write-Host "      请先把 zip 完整解压到一个可写目录，别在压缩包里直接运行。" -ForegroundColor Yellow
    Read-Host '按回车退出' | Out-Null
    exit 1
}
. $lib

$info = Join-Path $here 'PACKAGE-INFO.txt'
if (Test-Path $info) { Get-Content $info -Encoding UTF8 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
Write-Host ''

# ---------- 1. 包完整性 ----------
Write-Step '校验包完整性（哈希清单）'
$v = Test-Manifest -Root $here
if ($v.Ok) { Write-Ok "清单通过：$($v.Checked) 个文件" }
else {
    Write-Err2 ("包被改动或损坏：不一致 {0} / 缺失 {1}" -f $v.Mismatch.Count, $v.Missing.Count)
    $v.Mismatch | Select-Object -First 5 | ForEach-Object { Write-Host "      ~ $_" -ForegroundColor DarkYellow }
    $v.Missing  | Select-Object -First 5 | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkRed }
    $ans = Read-Host '仍要继续吗？(y/N)'
    if ($ans -ne 'y') { exit 1 }
}

# ---------- 2. 目标位置 ----------
if (-not $Dsh) {
    $guess = 'E:\逆向\deepseek-harness\.dsh'
    Write-Host ''
    Write-Host "  目标 DSH_HOME 默认: $guess" -ForegroundColor Cyan
    $ans = Read-Host '  回车=用这个 / 或直接输入别的路径'
    if ($ans.Trim()) { $guess = $ans.Trim() }
    $Dsh = $guess
}
if (-not $Kai) {
    $guessK = 'E:\逆向\kai'
    Write-Host "  目标 kai 目录 默认: $guessK" -ForegroundColor Cyan
    $ans = Read-Host '  回车=用这个 / 或直接输入别的路径'
    if ($ans.Trim()) { $guessK = $ans.Trim() }
    $Kai = $guessK
}
Write-Host ''

# ---------- 3. 口令 ----------
if (-not $SkipSecrets -and (Test-Path (Join-Path $soul 'secrets\credentials.sealed.json'))) {
    if (-not $Password -and -not $env:YG_SOUL_PASS) {
        $passFile = Join-Path (Join-Path $env:USERPROFILE '.yg-soul') 'pass.txt'
        if (-not (Test-Path $passFile)) {
            Write-Step '凭据是密文，需要口令解密（直接回车=跳过，稍后自己灌 key）'
            $sec = Read-Host '  口令' -AsSecureString
            if ($sec.Length -gt 0) {
                $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
            } else { $SkipSecrets = $true }
        }
    }
}

# ---------- 4. 真正装回 ----------
$only = @('soul', 'config', 'skills', 'redteam', 'kai', 'secrets')
if ($SkipSecrets) { $only = $only | Where-Object { $_ -ne 'secrets' } }
if ($SkipKai)     { $only = $only | Where-Object { $_ -ne 'kai' } }
$restArgs = @{ Dsh = $Dsh; Kai = $Kai; Only = $only }
if ($DryRun)   { $restArgs['DryRun'] = $true }
if ($Password) { $restArgs['Password'] = $Password }

& $rest @restArgs

# ---------- 5. 装完自检 ----------
if (-not $DryRun) {
    Write-Host ''
    Write-Step '装完自检'
    & $ver -Dsh $Dsh
}

Write-Host ''
Write-Host '  下一步（必须人工确认）:' -ForegroundColor Yellow
Write-Host '   1) cd <DSH_HOME>\profiles\web ; pnpm install'
Write-Host '   2) dsh web  ->  看 purge_status 是否 54+/64'
Write-Host '   3) 没有凭据/口令的，自己灌 API key 后跑  soul\tools\seal.ps1 -Action seal'
Write-Host '   4) 恢复每日同步: soul\tools\autosync.ps1 -Install'
Write-Host ''
Read-Host '按回车结束' | Out-Null
