# ============================================================
#  YG-SOUL / push.ps1  —  用 GitHub REST API 推送（绕开被墙的 github.com）
#  为什么不用 git push：本机到 github.com:443 被重置，但 api.github.com 通
#  用法:
#    pwsh -File soul\tools\push.ps1 -DryRun           # 只演练，不写入
#    pwsh -File soul\tools\push.ps1                   # 真推
#    pwsh -File soul\tools\push.ps1 -Message "soul: 更新记忆"
#  令牌: 环境变量 GITHUB_TOKEN / GH_TOKEN，或 %USERPROFILE%\.yg-soul\token
#        需要 classic PAT 的 repo 权限（推 workflow 文件还要 workflow 权限）
# ============================================================
param(
    [string]$Owner = 'Xpg666888',
    [string]$Repo  = '-TXT',
    [string]$Branch = 'main',
    [string]$Message = '',
    [string]$Token,
    [switch]$DryRun,
    [switch]$SkipCI
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$stage = Get-StageRoot
$api = 'https://api.github.com'

function Get-Token {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    $f = Join-Path (Join-Path $env:USERPROFILE '.yg-soul') 'token'
    if (Test-Path $f) { return (Get-Content -LiteralPath $f -Raw).Trim() }
    # 兜底 1：gh 的 keyring 令牌（hosts.yml 里看不到 oauth_token，但 token 还在 keyring）
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $ghTok = (gh auth token 2>$null | Out-String).Trim()
        if ($ghTok -match '^gh[opsu]_') { $ErrorActionPreference = $old; Write-Step '令牌来源：gh auth token'; return $ghTok }
    } catch { }
    # 兜底 2：Git Credential Manager
    try {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) 'yg-cred-in.txt'
        [IO.File]::WriteAllText($tmp, "protocol=https`r`nhost=github.com`r`n`r`n", (New-Object Text.UTF8Encoding($false)))
        $out = cmd /c "git credential fill < `"$tmp`" 2>nul"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $pw = ($out | Where-Object { $_ -match '^password=' }) -replace '^password=', ''
        if ($pw) { $ErrorActionPreference = $old; Write-Step '令牌来源：Git Credential Manager'; return $pw.Trim() }
    } catch { }
    $ErrorActionPreference = $old
    return $null
}

$tok = Get-Token -Explicit $Token
$baseHeaders = @{
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'YG-SOUL/1.0'
}
if ($tok) { $baseHeaders['Authorization'] = "Bearer $tok" }

function Invoke-Api {
    param([string]$Path, [string]$Method = 'GET', $Body)
    $uri = "$api$Path"
    $p = @{ Uri = $uri; Method = $Method; Headers = $baseHeaders; ContentType = 'application/json; charset=utf-8'; TimeoutSec = 60 }
    if ($null -ne $Body) { $p['Body'] = ([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 12 -Compress))) }
    Invoke-RestMethod @p
}

# ---------- 收集待推文件 ----------
$files = Get-ChildItem -LiteralPath $stage -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -notlike '*.tmp' -and $_.Name -ne 'push-plan.json' } |
    Sort-Object FullName
if ($SkipCI) { $files = $files | Where-Object { $_.FullName -notmatch '\\\.github\\' } }

$entries = foreach ($f in $files) {
    [pscustomobject]@{
        Path = (Get-RelPath -Root $stage -Path $f.FullName)
        Full = $f.FullName
        Size = $f.Length
    }
}
$totalBytes = ($entries | Measure-Object -Property Size -Sum).Sum

Write-Host "`n=== YG-SOUL push -> $Owner/$Repo@$Branch ===" -ForegroundColor Magenta
Write-Step ("待推 {0} 个文件 / {1:N0} 字节" -f @($entries).Count, $totalBytes)
if (-not $tok) { Write-Warn2 '没有令牌：只做只读演练（真推会失败）' }

# ---------- 当前提交 ----------
$ref = Invoke-Api "/repos/$Owner/$Repo/git/ref/heads/$Branch"
$baseCommit = $ref.object.sha
$commitInfo = Invoke-Api "/repos/$Owner/$Repo/git/commits/$baseCommit"
$baseTree = $commitInfo.tree.sha
Write-Step "基点 commit: $($baseCommit.Substring(0,12))  tree: $($baseTree.Substring(0,8))"

# ---------- 本地算 blob sha（dry-run 也用它证明内容一致）----------
function Get-GitBlobSha {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = [byte[]]::new($header.Length + $bytes.Length)
    [Array]::Copy($header, 0, $all, 0, $header.Length)
    [Array]::Copy($bytes, 0, $all, $header.Length, $bytes.Length)
    $sha = [Security.Cryptography.SHA1]::Create().ComputeHash($all)
    ($sha | ForEach-Object { $_.ToString('x2') }) -join ''
}

if ($DryRun) {
    $i = 0
    $plan = foreach ($e in $entries) {
        $i++
        if ($i % 25 -eq 0) { Write-Host "." -NoNewline }
        [pscustomobject]@{ path = $e.Path; sha = (Get-GitBlobSha -Path $e.Full); size = $e.Size }
    }
    Write-Host ''
    Write-Host "`n--- DRY RUN 计划（不写入远端）---" -ForegroundColor Yellow
    $plan | Select-Object -First 12 | ForEach-Object { "  {0}  {1,9}  {2}" -f $_.sha.Substring(0,10), $_.size, $_.path }
    Write-Host "  ... 共 $($plan.Count) 个 blob"
    [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetTempPath()) 'yg-soul-push-plan.json'), ($plan | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Write-Ok "完整计划已写入 push-plan.json（可核对路径与哈希）"
    return
}

if (-not $tok) { throw '需要令牌：设置 $env:GITHUB_TOKEN，或写入 %USERPROFILE%\.yg-soul\token' }

# ---------- 和远端树比对，只传变化的 blob ----------
$remoteMap = @{}
try {
    $base = Invoke-Api "/repos/$Owner/$Repo/git/trees/$baseTree`?recursive=1"
    foreach ($node in $base.tree) { if ($node.type -eq 'blob') { $remoteMap[$node.path] = $node.sha } }
    Write-Step ("远端已有 blob: {0} 个，开始比对" -f $remoteMap.Count)
} catch { Write-Warn2 "取远端树失败，退化为全量上传: $($_.Exception.Message)" }

$tree = New-Object System.Collections.ArrayList
$n = 0; $up = 0; $same = 0
foreach ($e in $entries) {
    $n++
    $localSha = Get-GitBlobSha -Path $e.Full
    if ($remoteMap.ContainsKey($e.Path) -and $remoteMap[$e.Path] -eq $localSha) { $same++; continue }
    $up++
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($e.Full))
    $blob = Invoke-Api "/repos/$Owner/$Repo/git/blobs" -Method POST -Body ([ordered]@{ content = $content; encoding = 'base64' })
    [void]$tree.Add([ordered]@{ path = $e.Path; mode = '100644'; type = 'blob'; sha = $blob.sha })
    if ($up % 20 -eq 0 -or $up -eq ($entries.Count - $same)) { Write-Host "  blob $up" -ForegroundColor DarkGray }
    if ($n -ge $entries.Count) { break }
}
Write-Step ("比对完成：未变 {0} / 需上传 {1}" -f $same, $tree.Count)

if ($tree.Count -eq 0) {
    Write-Ok '远端已是最新，无需提交'
    return
}

# ---------- tree / commit / ref ----------
$newTree = Invoke-Api "/repos/$Owner/$Repo/git/trees" -Method POST -Body ([ordered]@{ base_tree = $baseTree; tree = $tree })

if (-not $Message) {
    $Message = "soul: snapshot $(Get-Date -Format 'yyyy-MM-dd HH:mm') — $(@($entries).Count) files"
}
$newCommit = Invoke-Api "/repos/$Owner/$Repo/git/commits" -Method POST -Body ([ordered]@{
        message = $Message
        tree    = $newTree.sha
        parents = @($baseCommit)
    })

try {
    $updated = Invoke-Api "/repos/$Owner/$Repo/git/refs/heads/$Branch" -Method PATCH -Body ([ordered]@{ sha = $newCommit.sha; force = $false })
    Write-Ok ("已推送: {0} -> {1}" -f $baseCommit.Substring(0, 12), $newCommit.sha.Substring(0, 12))
    Write-Host ("  https://github.com/{0}/{1}/commit/{2}" -f $Owner, $Repo, $newCommit.sha) -ForegroundColor Green
} catch {
    $msg = $_.Exception.Message
    Write-Err2 "更新 ref 失败: $msg"
    throw
}
