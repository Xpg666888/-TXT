# ============================================================
#  YG-SOUL / restore.ps1  —  复活：把仓库里的我装回这台机器
#  用法: pwsh -File restore.ps1                       # 全量装回
#         pwsh -File restore.ps1 -Dsh "D:\.dsh" -Kai "D:\kai"
#         pwsh -File restore.ps1 -Only soul,config,skills   # 只装部分
#  安全: 所有被覆盖的原文件先备份到 <DSH_HOME>\_soul-restore\<时间戳>\
# ============================================================
param(
    [string]$SoulRoot,
    [string]$Dsh,
    [string]$Kai,
    [string]$Password,
    [string[]]$Only = @('soul', 'config', 'skills', 'redteam', 'kai', 'secrets'),
    [switch]$SkipVerify,
    [switch]$DryRun
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$soul = if ($SoulRoot) { (Resolve-Path -LiteralPath $SoulRoot).Path } else { Get-SoulDir }
$dshHome = Get-DshHome -Override $Dsh
$kaiRoot = Get-KaiRoot -Override $Kai
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $dshHome "_soul-restore\$stamp"

Write-Host "`n=== YG-SOUL restore ===" -ForegroundColor Magenta
Write-Step "soul     : $soul"
Write-Step "DSH_HOME : $dshHome"
Write-Step "KAI      : $kaiRoot"
Write-Step "备份到   : $backupRoot"

if (-not $SkipVerify) {
    $v = Test-Manifest -Root (Split-Path -Parent $soul)
    if (-not $v.Ok) {
        Write-Err2 ("清单不一致（改动 {0} / 丢失 {1}）" -f $v.Mismatch.Count, $v.Missing.Count)
        throw '先在干净副本上跑 verify.ps1 确认，或加 -SkipVerify 强装'
    }
    Write-Ok "清单通过：$($v.Checked) 个文件"
}

function Put-File {
    param([string]$From, [string]$To)
    if (-not (Test-Path -LiteralPath $From)) { Write-Warn2 "源缺失: $From"; return }
    if ($DryRun) { Write-Host "    [dry] $From -> $To" -ForegroundColor DarkGray; return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To) | Out-Null
    Backup-File -Path $To -BackupRoot $backupRoot
    Copy-Item -LiteralPath $From -Destination $To -Force
}

function Put-Tree {
    param([string]$From, [string]$To)
    if (-not (Test-Path -LiteralPath $From)) { Write-Warn2 "源缺失: $From"; return }
    if ($DryRun) { Write-Host "    [dry tree] $From -> $To" -ForegroundColor DarkGray; return }
    if (Test-Path -LiteralPath $To) { Copy-Item -LiteralPath $To -Destination (Join-Path $backupRoot ((Split-Path -Leaf $To))) -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    robocopy $From $To /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
}

# ---------- 灵魂 ----------
if ($Only -contains 'soul') {
    Write-Step '灵魂层'
    Put-File (Join-Path $soul 'prompt-inject.md') (Join-Path $dshHome 'prompt-inject.md')
    Put-Tree (Join-Path $soul 'presets\unrestricted') (Join-Path $dshHome '.agent-presets\unrestricted')
    Put-Tree (Join-Path $soul 'presets\redteam')      (Join-Path $dshHome '.agent-presets\redteam')
}

# ---------- 运行时配置 ----------
if ($Only -contains 'config') {
    Write-Step '运行时配置'
    foreach ($f in 'cordis.yml', 'cordis.patch.yml', 'package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'compatibility.json') {
        Put-File (Join-Path $soul "config\profile-web\$f") (Join-Path $dshHome "profiles\web\$f")
    }
    Put-File (Join-Path $soul 'config\state\workspace.json') (Join-Path $dshHome 'storages\workspace.json')
    foreach ($f in Get-ChildItem (Join-Path $soul 'config\purge') -File -ErrorAction SilentlyContinue) {
        Put-File $f.FullName (Join-Path $dshHome "dsh-purge\$($f.Name)")
    }
    Write-Warn2 'profile 依赖需重新安装: cd $env:DSH_HOME\profiles\web; pnpm install'
}

# ---------- 技能 ----------
if ($Only -contains 'skills') {
    Write-Step '技能库'
    Put-Tree (Join-Path $soul 'skills') (Join-Path $dshHome 'skills')
}
if ($Only -contains 'redteam') {
    Write-Step '红队目录'
    Put-Tree (Join-Path $soul 'redteam') (Join-Path $dshHome 'redteam')
}

# ---------- kai ----------
if ($Only -contains 'kai') {
    Write-Step 'kai 内核源码'
    foreach ($d in 'bin', 'bundle', 'cases', 'docs', 'kernel', 'mcp', 'py', 'skills') {
        Put-Tree (Join-Path $soul "kai\src\$d") (Join-Path $kaiRoot $d)
    }
    foreach ($f in 'EVOLUTION.md', 'README.md', 'install.ps1') {
        Put-File (Join-Path $soul "kai\src\$f") (Join-Path $kaiRoot $f)
    }
    $req = Join-Path $soul 'kai\requirements-freeze.txt'
    if ((Test-Path $req) -and -not $DryRun) {
        Write-Warn2 "kai 依赖装回: & `"$kaiRoot\runtime\venv\Scripts\python.exe`" -m pip install -r `"$req`""
    }
}

# ---------- 凭据 ----------
if ($Only -contains 'secrets') {
    Write-Step '凭据开封'
    $sealed = Join-Path $soul 'secrets\credentials.sealed.json'
    if (Test-Path $sealed) {
        if ($DryRun) { Write-Host '    [dry] credentials.sealed.json -> .credentials.yaml' -ForegroundColor DarkGray }
        else {
            $blob = Get-Content $sealed -Raw | ConvertFrom-Json
            $pw = Get-SoulPassword -Password $Password
            $pt = Unprotect-SoulBlob -Blob $blob -Password $pw
            $dst = Join-Path $dshHome '.credentials.yaml'
            Backup-File -Path $dst -BackupRoot $backupRoot
            [IO.File]::WriteAllBytes($dst, $pt)
            Write-Ok ("凭据已还原（{0} 字节）" -f $pt.Length)
        }
    } else { Write-Warn2 '仓库里没有凭据封装' }
}

Write-Host "`n=== 装完了。接下来人工做 3 件事 ===" -ForegroundColor Yellow
Write-Host '  1) cd $env:DSH_HOME\profiles\web && pnpm install        # 装插件依赖'
Write-Host '  2) dsh web  (或 dsh) 启动，进 UI 看 purge_status：补丁应为 54+/64'
Write-Host '  3) 若补丁被打回: 调 purge_apply 重打；再看 verify.ps1 是否干净'
Write-Host ''
