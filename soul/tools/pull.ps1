# ============================================================
#  YG-SOUL / pull.ps1  —  新机器上把我拉下来（github.com 不通也能拉）
#  用法: pwsh -File pull.ps1                 # 拉到 %USERPROFILE%\YG-SOUL
#         pwsh -File pull.ps1 -Dest D:\YG-SOUL
#  依次尝试: codeload -> ghfast 镜像 -> gh-proxy 镜像 -> api.github.com 逐文件
# ============================================================
param(
    [string]$Owner = 'Xpg666888',
    [string]$Repo  = '-TXT',
    [string]$Branch = 'main',
    [string]$Dest,
    [string]$Token,
    [switch]$Force
)
. (Join-Path $PSScriptRoot 'lib.ps1')

if (-not $Dest) { $Dest = Join-Path $env:USERPROFILE 'YG-SOUL' }
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$zip = Join-Path ([IO.Path]::GetTempPath()) ("soul-$([guid]::NewGuid().ToString('N').Substring(0,8)).zip")

$mirrors = @(
    "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/$Branch",
    "https://ghfast.top/https://github.com/$Owner/$Repo/archive/refs/heads/$Branch.zip",
    "https://gh-proxy.com/https://github.com/$Owner/$Repo/archive/refs/heads/$Branch.zip",
    "https://github.moeyy.xyz/https://github.com/$Owner/$Repo/archive/refs/heads/$Branch.zip"
)

Write-Host "`n=== YG-SOUL pull <- $Owner/$Repo@$Branch ===" -ForegroundColor Magenta
$ok = $false
foreach ($u in $mirrors) {
    Write-Step "尝试 $u"
    try {
        Invoke-WebRequest -Uri $u -OutFile $zip -MaximumRedirection 5 -TimeoutSec 120 -Headers @{ 'User-Agent' = 'YG-SOUL/1.0' }
        if ((Get-Item $zip).Length -gt 1000) { Write-Ok ("下载成功 {0:N0} 字节" -f (Get-Item $zip).Length); $ok = $true; break }
    } catch { Write-Warn2 $_.Exception.Message }
}
if (-not $ok) { throw '所有通道都失败：挂代理，或用 Token 走 api 逐文件拉取' }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("soul-x-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
$top = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
$srcSoul = Join-Path $top.FullName 'soul'
if (-not (Test-Path $srcSoul)) { throw "压缩包里没有 soul/ 目录（$($top.FullName)）" }

$dstSoul = Join-Path $Dest 'soul'
if ((Test-Path $dstSoul) -and -not $Force) {
    $bak = "$dstSoul.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Write-Warn2 "已有旧副本，备份到 $bak"
    Move-Item -LiteralPath $dstSoul -Destination $bak
}
Copy-Item -LiteralPath $srcSoul -Destination $dstSoul -Recurse -Force
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

Write-Ok "已拉到 $dstSoul"
& (Join-Path $dstSoul 'tools\verify.ps1') -Quiet
Write-Host "`n下一步: pwsh -File `"$dstSoul\tools\restore.ps1`"  (把配置装回 DSH_HOME)" -ForegroundColor Yellow
