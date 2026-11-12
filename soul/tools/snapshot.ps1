# ============================================================
#  YG-SOUL / snapshot.ps1  —  把「现在这台机器上的我」收进仓库暂存区
#  用法:  pwsh -NoProfile -File soul\tools\snapshot.ps1
#         pwsh -NoProfile -File soul\tools\snapshot.ps1 -Dsh "D:\x\.dsh" -Kai "D:\kai"
# ============================================================
param(
    [string]$Dsh,
    [string]$Kai,
    [switch]$SkipKai,
    [switch]$SkipSeal,
    [switch]$SkipDigest,
    [string]$Password
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$stage = Get-StageRoot
$soul  = Get-SoulDir
$dshHome = Get-DshHome -Override $Dsh
$kaiRoot = Get-KaiRoot -Override $Kai
$stamp = (Get-Date).ToString('s:yyyy-MM-ddTHH:mm:sszzz')

Write-Host "`n=== YG-SOUL snapshot ===  $stamp" -ForegroundColor Magenta
Write-Step "DSH_HOME : $dshHome"
Write-Step "KAI      : $kaiRoot"
Write-Step "STAGE    : $stage"

function Copy-Into {
    param([string]$From, [string]$To, [string[]]$Filter, [string[]]$ExcludeDir, [string[]]$ExcludeFile)
    if (-not (Test-Path -LiteralPath $From)) { Write-Warn2 "缺: $From"; return }
    if ((Get-Item -LiteralPath $From).PSIsContainer) {
        New-Item -ItemType Directory -Force -Path $To | Out-Null
        $rargs = @($From, $To, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
        if ($ExcludeDir)  { $rargs += '/XD'; $rargs += $ExcludeDir }
        if ($ExcludeFile) { $rargs += '/XF'; $rargs += $ExcludeFile }
        robocopy @rargs | Out-Null
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To) | Out-Null
    Copy-Item -LiteralPath $From -Destination $To -Force
    return
}

# ---------- 1. 灵魂层 ----------
Write-Step '1/7 灵魂层（prompt-inject / 预设）'
Copy-Into (Join-Path $dshHome 'prompt-inject.md') (Join-Path $soul 'prompt-inject.md')
Copy-Into (Join-Path $dshHome '.agent-presets\unrestricted') (Join-Path $soul 'presets\unrestricted') $null @('__pycache__') @('*.bak')
Copy-Into (Join-Path $dshHome '.agent-presets\redteam')      (Join-Path $soul 'presets\redteam')      $null @('__pycache__') @('*.bak')

# ---------- 2. 运行时配置 ----------
Write-Step '2/7 运行时配置（profile / purge 状态）'
foreach ($f in 'cordis.yml','cordis.patch.yml','package.json','pnpm-lock.yaml','pnpm-workspace.yaml','compatibility.json') {
    $src = Join-Path $dshHome "profiles\web\$f"
    if (Test-Path $src) { Copy-Item $src (Join-Path $soul "config\profile-web\$f") -Force }
}
Copy-Into (Join-Path $dshHome 'dsh-purge') (Join-Path $soul 'config\purge') @('*.json','installed-rev') @('backups') @('last-cwd.txt')
Copy-Into (Join-Path $dshHome 'dsh-purge-community\audit.jsonl') (Join-Path $soul 'config\purge\community-audit.jsonl')
Copy-Into (Join-Path $dshHome 'storages\workspace.json') (Join-Path $soul 'config\state\workspace.json')

# ---------- 3. 技能库 ----------
Write-Step '3/7 技能库（skills / redteam）'
Copy-Into (Join-Path $dshHome 'skills')  (Join-Path $soul 'skills')  $null @('__pycache__') @('*.pyc')
Copy-Into (Join-Path $dshHome 'redteam') (Join-Path $soul 'redteam') $null @('__pycache__') @('*.pyc')

# ---------- 4. kai 内核（只收源码，不收 venv/二进制）----------
if (-not $SkipKai) {
    Write-Step '4/7 kai 内核源码'
    foreach ($d in 'bin','bundle','cases','docs','kernel','mcp','py','skills') {
        if (Test-Path (Join-Path $kaiRoot $d)) {
            Copy-Into (Join-Path $kaiRoot $d) (Join-Path $soul "kai\src\$d") $null @('__pycache__','node_modules') @('*.pyc','*.so','*.pyd')
        }
    }
    foreach ($f in 'EVOLUTION.md','README.md','install.ps1') {
        if (Test-Path (Join-Path $kaiRoot $f)) { Copy-Item (Join-Path $kaiRoot $f) (Join-Path $soul 'kai\src') -Force }
    }
    # venv 不进仓库，但把可复现的依赖钉下来
    $py = Join-Path $kaiRoot 'runtime\venv\Scripts\python.exe'
    if (Test-Path $py) {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $freeze = @()
        $freeze = & $py -m pip freeze --disable-pip-version-check 2>$null
        $ErrorActionPreference = $oldEap
        if (-not $freeze) {
            # venv 里没 pip（uv 建的那种）：直接从 dist-info 读版本
            $sp = Join-Path $kaiRoot 'runtime\venv\Lib\site-packages'
            if (Test-Path $sp) {
                $freeze = Get-ChildItem $sp -Directory -Filter '*.dist-info' | ForEach-Object {
                    $n = $_.Name -replace '\.dist-info$', ''
                    $i = $n.LastIndexOf('-')
                    if ($i -gt 0) { "{0}=={1}" -f $n.Substring(0, $i), $n.Substring($i + 1) }
                } | Sort-Object
            }
            Write-Warn2 'pip 不可用，改用 dist-info 生成依赖清单'
        }
        if ($freeze) {
            [IO.File]::WriteAllLines((Join-Path $soul 'kai\requirements-freeze.txt'), [string[]]$freeze, (New-Object Text.UTF8Encoding($false)))
            Write-Ok ("依赖清单 -> {0} 行" -f @($freeze).Count)
        }
    }
} else { Write-Warn2 '跳过 kai 源码' }

# ---------- 5. 环境基线 ----------
Write-Step '5/7 环境基线 env.json'
function Try-Cmd { param($Cmd, $Arg) try { (& $Cmd $Arg 2>$null | Out-String).Trim() } catch { '' } }
$purgeVerify = Join-Path $dshHome 'dsh-purge\verify-status.json'
$profilePkg  = Join-Path $dshHome 'profiles\web\package.json'
$purgeVer = ''
if (Test-Path (Join-Path $dshHome 'dsh-purge\installed-rev')) { $purgeVer = (Get-Content (Join-Path $dshHome 'dsh-purge\installed-rev') -Raw).Trim() }
$purgeTally = $null
if (Test-Path $purgeVerify) { $purgeTally = (Get-Content $purgeVerify -Raw -Encoding utf8 | ConvertFrom-Json).tally }
$bundles = $null; $dynDeps = $null
if (Test-Path $profilePkg) { $pj = Get-Content $profilePkg -Raw -Encoding utf8 | ConvertFrom-Json; $bundles = $pj.dsh.profile.bundles; $dynDeps = $pj.dependencies }
$dshBin = ''
$c = Get-Command dsh -ErrorAction SilentlyContinue
if ($c) { $dshBin = [string]$c.Source }
$envObj = [ordered]@{
    snapshotAt   = $stamp
    machine      = $env:COMPUTERNAME
    user         = $env:USERNAME
    dshHome      = $dshHome
    kaiRoot      = $kaiRoot
    node         = (Try-Cmd node '-v')
    pnpm         = (Try-Cmd pnpm '-v')
    pwsh         = $PSVersionTable.PSVersion.ToString()
    os           = [Environment]::OSVersion.VersionString
    dshCmd       = (Try-Cmd dsh '--version')
    dshBin       = $dshBin
    purgeVersion = $purgeVer
    purgeTally   = $purgeTally
    profileBundles = $bundles
    dynamicDeps  = $dynDeps
}
$envJson = Join-Path $soul 'config\env.json'
[IO.File]::WriteAllText($envJson, ($envObj | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Ok "env.json"

# ---------- 6. 记忆 ----------
if (-not $SkipDigest) {
    Write-Step '6/7 会话记忆索引'
    try {
        $node = (Get-Command node).Source
        & $node (Join-Path $PSScriptRoot 'digest.mjs') (Join-Path $dshHome 'sessions') (Join-Path $soul 'memory\sessions-digest.md')
        Write-Ok 'sessions-digest.md'
    } catch { Write-Warn2 "会话索引失败: $($_.Exception.Message)" }
} else { Write-Warn2 '跳过会话索引' }

# ---------- 7. 凭据封装 ----------
if (-not $SkipSeal) {
    Write-Step '7/7 凭据封装（AES-256-CBC + HMAC-SHA256 / PBKDF2 30万轮）'
    $cred = Join-Path $dshHome '.credentials.yaml'
    $out = Join-Path $soul 'secrets\credentials.sealed.json'
    if (Test-Path $cred) {
        try {
            $srcHash = Get-Sha256 -Path $cred
            $skipSeal = $false
            if (Test-Path $out) {
                try {
                    $old = Get-Content $out -Raw -Encoding utf8 | ConvertFrom-Json
                    if ($old.srcHash -eq $srcHash) { $skipSeal = $true; Write-Ok '凭据未变，沿用已有密文（清单哈希保持稳定）' }
                } catch { $skipSeal = $false }
            }
            if (-not $skipSeal) {
                $pw = Get-SoulPassword -Password $Password -Generate
                $plain = [IO.File]::ReadAllBytes($cred)
                $blob = Protect-SoulBlob -Plain $plain -Password $pw
                $blob | Add-Member -NotePropertyName 'source'  -NotePropertyValue 'dsh/.credentials.yaml' -Force
                $blob | Add-Member -NotePropertyName 'sealedAt' -NotePropertyValue $stamp -Force
                $blob | Add-Member -NotePropertyName 'srcHash'  -NotePropertyValue $srcHash -Force
                [IO.File]::WriteAllText($out, ($blob | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
                Write-Ok ("credentials.sealed.json ({0} bytes -> {1} bytes)" -f $plain.Length, (Get-Item $out).Length)
            }
        } catch { Write-Warn2 "凭据封装跳过: $($_.Exception.Message)" }
    } else { Write-Warn2 '本机没有 .credentials.yaml' }
} else { Write-Warn2 '跳过凭据封装' }

# ---------- 清单 ----------
Write-Step '生成哈希清单'
New-Manifest -Root $stage

# ---------- 汇总 ----------
$files = Get-ChildItem -LiteralPath $stage -Recurse -File -Force
$mb = [math]::Round((($files | Measure-Object -Property Length -Sum).Sum) / 1MB, 2)
Write-Host "`n快照完成: $($files.Count) 个文件 / $mb MB" -ForegroundColor Magenta
