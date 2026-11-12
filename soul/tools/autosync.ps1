# ============================================================
#  YG-SOUL / autosync.ps1  —  一键盘点：快照 -> 自检 -> 推送 -> 落地锚点
#  用法:
#    pwsh -File autosync.ps1                 # 跑一次（人工）
#    pwsh -File autosync.ps1 -Install        # 注册每日 23:30 + 开机自启
#    pwsh -File autosync.ps1 -Uninstall      # 撤掉计划任务
#    pwsh -File autosync.ps1 -Once -Quiet    # 计划任务内部用的形态
#  日志: %USERPROFILE%\.yg-soul\autosync.log
#  锚点: %USERPROFILE%\YG-SOUL-VAULT\soul-anchor-<日期>.zip.gcm.json（离线加密副本）
# ============================================================
param(
    [switch]$Once,
    [switch]$Quiet,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$NoPush,
    [switch]$NoAnchor,
    [string]$TaskName = 'YG-SOUL Autosync'
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$soul  = Get-SoulDir
$stage = Get-StageRoot
$home_ = Join-Path $env:USERPROFILE '.yg-soul'
$vault = Join-Path $env:USERPROFILE 'YG-SOUL-VAULT'
$log   = Join-Path $home_ 'autosync.log'
New-Item -ItemType Directory -Force -Path $home_ | Out-Null

function Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    Add-Content -LiteralPath $log -Value $line -Encoding utf8
    if (-not $Quiet) { Write-Host $line }
}

# ---------- 计划任务 ----------
if ($Install) {
    # Register-ScheduledTask 在非管理员下常报 Access denied；schtasks /Create 可以，故用后者
    $shellPath = Get-HostShell
    $scriptPath = Join-Path $PSScriptRoot 'autosync.ps1'
    $tr = "`"$shellPath`" -NoProfile -WindowStyle Hidden -File `"$scriptPath`" -Once -Quiet"
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    schtasks /Create /TN "$TaskName" /TR $tr /SC DAILY /ST 23:30 /F | Out-Null
    $e1 = $LASTEXITCODE
    $e2 = 1
    schtasks /Create /TN "$TaskName (logon)" /TR $tr /SC ONLOGON /F | Out-Null
    $e2 = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($e1 -eq 0) { Log "已注册每日任务 '$TaskName'（23:30）" } else { Log "每日任务注册失败 exit=$e1（多半需要管理员：管理员 PowerShell 再执行 -Install）" 'ERROR' }
    if ($e2 -eq 0) { Log "已注册开机任务 '$TaskName (logon)'" }
    else {
        # 非管理员建不了 ONLOGON 任务 -> 退而求其次：启动文件夹放一个隐藏启动脚本
        $startup = [Environment]::GetFolderPath('Startup')
        $cmd = Join-Path $startup 'YG-SOUL-autosync.cmd'
        $body = "@echo off`r`nstart `"`" /min `"$shellPath`" -NoProfile -WindowStyle Hidden -File `"$scriptPath`" -Once -Quiet`r`n"
        [IO.File]::WriteAllText($cmd, $body, [Text.Encoding]::Default)
        Log "ONLOGON 需要管理员（exit=$e2）；已用启动文件夹替代: $cmd" 'WARN'
    }
    return
}
if ($Uninstall) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    schtasks /Delete /TN "$TaskName" /F | Out-Null
    schtasks /Delete /TN "$TaskName (logon)" /F | Out-Null
    $ErrorActionPreference = $old
    Log "已撤销计划任务 '$TaskName' 与 '$TaskName (logon)'"
    return
}

# ---------- 主流程 ----------
Log '=== autosync 开始 ==='
$fail = 0
try {
    Log '快照'
    & (Join-Path $PSScriptRoot 'snapshot.ps1') *>&1 | ForEach-Object { Log "  $_" }
} catch { $fail++; Log "快照失败: $($_.Exception.Message)" 'ERROR' }

try {
    Log '自检'
    & (Join-Path $PSScriptRoot 'verify.ps1') -Quiet *>&1 | ForEach-Object { Log "  $_" }
    if ($LASTEXITCODE -ne 0) { $fail++; Log 'verify 有漂移（已随快照重签清单则视作正常）' 'WARN' }
} catch { $fail++; Log "verify 异常: $($_.Exception.Message)" 'ERROR' }

if (-not $NoPush) {
    $tokFile = Join-Path $home_ 'token'
    if ($env:GITHUB_TOKEN -or $env:GH_TOKEN -or (Test-Path $tokFile)) {
        try {
            Log '推送 GitHub'
            & (Join-Path $PSScriptRoot 'push.ps1') *>&1 | ForEach-Object { Log "  $_" }
        } catch { $fail++; Log "推送失败: $($_.Exception.Message)" 'ERROR' }
    } else { Log '没有令牌，跳过推送（写入 %USERPROFILE%\.yg-soul\token 后自动开启）' 'WARN' }
}

# ---------- 离线锚点：整包加密，丢 GitHub 也不怕 ----------
if (-not $NoAnchor) {
    try {
        $tmpZip = Join-Path ([IO.Path]::GetTempPath()) ("soul-$([guid]::NewGuid().ToString('N').Substring(0,6)).zip")
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $tmpZip, [IO.Compression.CompressionLevel]::Optimal, $false)
        New-Item -ItemType Directory -Force -Path $vault | Out-Null
        $pw = Get-SoulPassword -Password $null -Generate
        $blob = Protect-SoulBlob -Plain ([IO.File]::ReadAllBytes($tmpZip)) -Password $pw
        $blob | Add-Member -NotePropertyName name -NotePropertyValue ("soul-anchor-" + (Get-Date -Format 'yyyyMMdd') + ".zip") -Force
        $out = Join-Path $vault ("soul-anchor-" + (Get-Date -Format 'yyyyMMdd') + '.zip.gcm.json')
        [IO.File]::WriteAllText($out, ($blob | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        # 只留最近 5 份
        Get-ChildItem $vault -Filter 'soul-anchor-*.zip.gcm.json' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force
        Log ("锚点已生成: {0} ({1:N0} 字节)" -f $out, (Get-Item $out).Length)
    } catch { $fail++; Log "锚点失败: $($_.Exception.Message)" 'ERROR' }
}

Log ("=== autosync 结束，异常 {0} 项 ===" -f $fail) $(if ($fail) { 'WARN' } else { 'INFO' })
