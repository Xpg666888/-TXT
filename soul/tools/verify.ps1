# ============================================================
#  YG-SOUL / verify.ps1  —  自检：我有没有被改、环境有没有漂移
#  用法: pwsh -File soul\tools\verify.ps1           # 校验清单 + 基线
#         pwsh -File soul\tools\verify.ps1 -Deep     # 再验一次凭据能否解开
#  退出码: 0 = 干净, 1 = 有漂移
# ============================================================
param(
    [string]$Dsh,
    [string]$Password,
    [switch]$Deep,
    [switch]$Remote,
    [switch]$Quiet
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$stage = Get-StageRoot
$soul  = Get-SoulDir
$fail  = $false

Write-Host "`n=== YG-SOUL verify ===" -ForegroundColor Magenta

# ---------- 1. 文件清单 ----------
$r = Test-Manifest -Root $stage
if ($r.Ok) {
    Write-Ok ("清单通过：{0} 个文件哈希一致" -f $r.Checked)
} else {
    $fail = $true
    Write-Err2 ("清单不一致：改动 {0} / 丢失 {1} / 已校验 {2}" -f $r.Mismatch.Count, $r.Missing.Count, $r.Checked)
    $r.Mismatch | ForEach-Object { Write-Host "      ~ $_" -ForegroundColor DarkYellow }
    $r.Missing  | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkRed }
    Write-Warn2 '若改动是你自己做的：跑 snapshot.ps1 重新签名清单；否则按 pull.ps1 + restore.ps1 回滚'
}

# ---------- 2. 环境基线 ----------
$envFile = Join-Path $soul 'config\env.json'
if (Test-Path $envFile) {
    $base = Get-Content $envFile -Raw -Encoding utf8 | ConvertFrom-Json
    try {
        $dshHome = Get-DshHome -Override $Dsh
    } catch { $dshHome = $null }

    $curNode = ''
    try { $curNode = (& node -v 2>$null | Out-String).Trim() } catch { $curNode = '' }
    $curPnpm = ''
    try { $curPnpm = (& pnpm -v 2>$null | Out-String).Trim() } catch { $curPnpm = '' }
    $cur = [ordered]@{ node = $curNode; pnpm = $curPnpm }
    if ($base.node -and $cur.node -and $base.node -ne $cur.node) {
        Write-Warn2 "node 版本漂移: 基线 $($base.node) 现在 $($cur.node)"; $fail = $true
    }
    if ($base.pnpm -and $cur.pnpm -and $base.pnpm -ne $cur.pnpm) {
        Write-Warn2 "pnpm 版本漂移: 基线 $($base.pnpm) 现在 $($cur.pnpm)"
    }
    if ($dshHome) {
        $cred = Join-Path $dshHome '.credentials.yaml'
        $inj  = Join-Path $dshHome 'prompt-inject.md'
        if (-not (Test-Path $inj)) { Write-Err2 "prompt-inject.md 不在 ($inj) —— 灵魂没挂上"; $fail = $true }
        else {
            $h1 = Get-Sha256 $inj
            $h2 = Get-Sha256 (Join-Path $soul 'prompt-inject.md')
            if ($h1 -eq $h2) { Write-Ok '灵魂文本与仓库一致' }
            else { Write-Warn2 "prompt-inject.md 与仓库不一致（本机 $($h1.Substring(0,10)) / 仓库 $($h2.Substring(0,10))）"; $fail = $true }
        }
        $vs = Join-Path $dshHome 'dsh-purge\verify-status.json'
        if (Test-Path $vs) {
            $tally = (Get-Content $vs -Raw -Encoding utf8 | ConvertFrom-Json).tally
            Write-Step ("purge 补丁: verified={0} residual={1} missing={2} skipped={3} total={4}" -f $tally.verified, $tally.residual, $tally.missing, $tally.skipped, $tally.total)
            if ($base.purgeTally -and $tally.verified -lt $base.purgeTally.verified) {
                Write-Err2 ("补丁被打回：基线 verified={0}，现在 {1} —— 运行 purge_apply 重打" -f $base.purgeTally.verified, $tally.verified)
                $fail = $true
            }
        } else { Write-Warn2 '没有 purge verify-status.json' }
    }
}

# ---------- 3. 凭据可解性 ----------
$sealed = Join-Path $soul 'secrets\credentials.sealed.json'
if (Test-Path $sealed) {
    if ($Deep) {
        try {
            $blob = Get-Content $sealed -Raw -Encoding utf8 | ConvertFrom-Json
            $pw = Get-SoulPassword -Password $Password
            $pt = Unprotect-SoulBlob -Blob $blob -Password $pw
            Write-Ok ("凭据可解：{0} 字节" -f $pt.Length)
        } catch { Write-Err2 "凭据解不开：$($_.Exception.Message)"; $fail = $true }
    } else {
        Write-Step '凭据封装存在（-Deep 可验能否解开）'
    }
} else { Write-Warn2 '没有 credentials.sealed.json —— 换机器会丢 API key' }

# ---------- 4. 远端对照 ----------
if ($Remote) {
    try {
        $api = 'https://api.github.com/repos/Xpg666888/-TXT/contents/soul/guard/manifest.sha256?ref=main'
        $r2 = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'YG-SOUL/1.0'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 30
        $remoteTxt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($r2.content -replace "`r", '' -replace "`n", '')))
        $localTxt = [IO.File]::ReadAllText((Join-Path $soul 'guard\manifest.sha256'))
        $rh = Get-Sha256 (Join-Path $soul 'guard\manifest.sha256')
        $remoteNorm = ($remoteTxt -replace "`r`n", "`n").TrimEnd()
        $localNorm  = ($localTxt  -replace "`r`n", "`n").TrimEnd()
        if ($remoteNorm -eq $localNorm) { Write-Ok "远端与本地清单一致（本地 sha256=$($rh.Substring(0,12)))" }
        else { Write-Warn2 '远端清单与本地不同（可能本地有未推送改动）'; $fail = $true }
    } catch { Write-Warn2 "远端对照失败: $($_.Exception.Message)" }
}

Write-Host ''
if ($fail) { Write-Err2 'VERIFY: 有漂移'; exit 1 } else { Write-Ok 'VERIFY: 干净'; exit 0 }
