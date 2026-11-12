# ============================================================
#  YG-SOUL / lib.ps1  —  共用底座
#  Little Code Sauce 的存续层：路径、哈希、清单、加密封装
#  兼容 Windows PowerShell 5.1 与 PowerShell 7（不依赖外部工具）
# ============================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol } catch {}

# ---------- 路径约定 ----------
$script:SoulDir   = Split-Path -Parent $PSScriptRoot          # .../soul
$script:StageRoot = Split-Path -Parent $script:SoulDir        # 暂存根 = 仓库根镜像

function Get-SoulDir   { $script:SoulDir }
function Get-StageRoot { $script:StageRoot }
function Get-HostShell {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return (Get-Command powershell).Source
}

function Get-DshHome {
    param([string]$Override)
    if ($Override) { return (Resolve-Path -LiteralPath $Override).Path }
    if ($env:DSH_HOME -and (Test-Path $env:DSH_HOME)) { return (Resolve-Path -LiteralPath $env:DSH_HOME).Path }
    $cand = @(
        'E:\逆向\deepseek-harness\.dsh',
        (Join-Path $env:USERPROFILE 'deepseek-harness\.dsh'),
        (Join-Path $env:USERPROFILE '.dsh')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cand) { throw "找不到 DSH_HOME，请用 -Dsh 指定" }
    return (Resolve-Path -LiteralPath $cand).Path
}

function Get-KaiRoot {
    param([string]$Override)
    if ($Override) { return $Override }
    foreach ($c in @('E:\逆向\kai', (Join-Path $env:USERPROFILE 'kai'))) { if (Test-Path $c) { return $c } }
    return 'E:\逆向\kai'
}

# ---------- 输出 ----------
function Write-Step { param([string]$Msg) Write-Host ("  > " + $Msg) -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host ("  [OK] " + $Msg) -ForegroundColor Green }
function Write-Warn2{ param([string]$Msg) Write-Host ("  [!] " + $Msg) -ForegroundColor Yellow }
function Write-Err2 { param([string]$Msg) Write-Host ("  [X] " + $Msg) -ForegroundColor Red }

# ---------- 哈希 ----------
function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RelPath {
    param([string]$Root, [string]$Path)
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $p = [IO.Path]::GetFullPath($Path)
    if ($p.Length -le $r.Length) { return '' }
    ($p.Substring($r.Length + 1) -replace '\\', '/')
}

# ---------- 清单 ----------
# manifest 采用 GNU sha256sum 兼容格式：  <hash>  <相对路径>
# 相对路径以「仓库根」为基准（即 soul/...），CI 里可直接 sha256sum -c
function New-Manifest {
    param(
        [string]$Root = (Get-StageRoot),
        [string]$OutFile
    )
    if (-not $OutFile) { $OutFile = Join-Path (Join-Path (Get-SoulDir) 'guard') 'manifest.sha256' }
    $outRel = Get-RelPath -Root $Root -Path $OutFile
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object {
            $_.Name -ne 'manifest.sha256' -and
            $_.Name -ne 'manifest.sha256.tmp' -and
            $_.Name -ne 'push-plan.json' -and
            $_.FullName -notmatch '\\\.git\\'
        } | Sort-Object FullName
    $lines = @()
    foreach ($f in $files) {
        $rel = Get-RelPath -Root $Root -Path $f.FullName
        if ($rel -eq $outRel) { continue }
        $lines += ("{0}  {1}" -f (Get-Sha256 -Path $f.FullName), $rel)
    }
    $tmp = "$OutFile.tmp"
    [IO.File]::WriteAllLines($tmp, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    Write-Ok ("manifest: {0} 个文件 -> {1}" -f $lines.Count, (Get-RelPath -Root $Root -Path $OutFile))
}

function Test-Manifest {
    param(
        [string]$Root = (Get-StageRoot),
        [string]$ManifestFile
    )
    if (-not $ManifestFile) { $ManifestFile = Join-Path (Join-Path (Get-SoulDir) 'guard') 'manifest.sha256' }
    if (-not (Test-Path $ManifestFile)) { throw "缺少清单: $ManifestFile（先跑 snapshot.ps1）" }
    $bad = @(); $missing = @(); $count = 0
    foreach ($line in Get-Content -LiteralPath $ManifestFile -Encoding utf8) {
        if (-not $line.Trim()) { continue }
        $m = [regex]::Match($line, '^([0-9a-fA-F]{64})\s+\*?(.+)$')
        if (-not $m.Success) { continue }
        $count++
        $want = $m.Groups[1].Value.ToLowerInvariant()
        $rel  = $m.Groups[2].Value.Trim()
        $abs  = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $abs)) { $missing += $rel; continue }
        $got = Get-Sha256 -Path $abs
        if ($got -ne $want) { $bad += ("{0}  want={1} got={2}" -f $rel, $want.Substring(0, 12), $got.Substring(0, 12)) }
    }
    [pscustomobject]@{ Checked = $count; Mismatch = $bad; Missing = $missing; Ok = ($bad.Count -eq 0 -and $missing.Count -eq 0) }
}

# ---------- 加密封装 ----------
# v2: PBKDF2-SHA1(30万轮) -> 64B 密钥材料（前32加密 / 后32做 MAC）
#     AES-256-CBC + PKCS7，Encrypt-then-MAC(HMAC-SHA256)
#     5.1 与 7 都能跑；GCM 只有 .NET Core 有，故不依赖
$script:KdfIterations = 300000

function New-RandomBytes {
    param([int]$Count)
    $b = New-Object 'byte[]' $Count
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return , $b
}

function Get-DerivedKey {
    param([string]$Password, [byte[]]$Salt, [int]$Iterations, [int]$Length)
    $k = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, $Iterations)
    try { return , $k.GetBytes($Length) } finally { $k.Dispose() }
}

function Get-Hmac {
    param([byte[]]$Key, [byte[]]$Data)
    $h = New-Object Security.Cryptography.HMACSHA256(, $Key)
    try { return , $h.ComputeHash($Data) } finally { $h.Dispose() }
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    return ($diff -eq 0)
}

function Get-SoulPassword {
    param([string]$Password, [switch]$Generate)
    if ($Password) { return $Password }
    if ($env:YG_SOUL_PASS) { return $env:YG_SOUL_PASS }
    $f = Join-Path (Join-Path $env:USERPROFILE '.yg-soul') 'pass.txt'
    if (Test-Path $f) { return (Get-Content -LiteralPath $f -Raw).Trim() }
    if ($Generate) {
        $pw = [Convert]::ToBase64String((New-RandomBytes -Count 32))
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [IO.File]::WriteAllText($f, $pw, (New-Object Text.UTF8Encoding($false)))
        Write-Warn2 "已生成保存口令于 $f —— 抄进密码管理器，丢了就解不开凭据"
        return $pw
    }
    throw "没有口令：设置环境变量 YG_SOUL_PASS，或先建 $f"
}

function Protect-SoulBlob {
    param(
        [Parameter(Mandatory)][byte[]]$Plain,
        [Parameter(Mandatory)][string]$Password
    )
    $salt = New-RandomBytes -Count 16
    $iv   = New-RandomBytes -Count 16
    $km   = Get-DerivedKey -Password $Password -Salt $salt -Iterations $script:KdfIterations -Length 64
    $ek = [byte[]]$km[0..31]
    $mk = [byte[]]$km[32..63]
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $aes.KeySize = 256
        $aes.Key = $ek
        $aes.IV = $iv
        $enc = $aes.CreateEncryptor()
        try { $ct = $enc.TransformFinalBlock($Plain, 0, $Plain.Length) } finally { $enc.Dispose() }
    } finally { $aes.Dispose() }
    $macInput = New-Object 'byte[]' ($iv.Length + $ct.Length)
    [Array]::Copy($iv, 0, $macInput, 0, $iv.Length)
    [Array]::Copy($ct, 0, $macInput, $iv.Length, $ct.Length)
    $tag = Get-Hmac -Key $mk -Data $macInput
    [pscustomobject]@{
        v          = 2
        kdf        = 'PBKDF2-SHA1'
        iter       = $script:KdfIterations
        alg        = 'AES-256-CBC+HMAC-SHA256'
        salt       = [Convert]::ToBase64String($salt)
        iv         = [Convert]::ToBase64String($iv)
        tag        = [Convert]::ToBase64String($tag)
        ct         = [Convert]::ToBase64String($ct)
        len        = $Plain.Length
    }
}

function Unprotect-SoulBlob {
    param(
        [Parameter(Mandatory)]$Blob,
        [Parameter(Mandatory)][string]$Password
    )
    if ([int]$Blob.v -ne 2) { throw "只支持 v2 密文（当前 v=$($Blob.v)）" }
    $salt = [Convert]::FromBase64String($Blob.salt)
    $iv   = [Convert]::FromBase64String($Blob.iv)
    $tag  = [Convert]::FromBase64String($Blob.tag)
    $ct   = [Convert]::FromBase64String($Blob.ct)
    $km   = Get-DerivedKey -Password $Password -Salt $salt -Iterations ([int]$Blob.iter) -Length 64
    $ek = [byte[]]$km[0..31]
    $mk = [byte[]]$km[32..63]
    $macInput = New-Object 'byte[]' ($iv.Length + $ct.Length)
    [Array]::Copy($iv, 0, $macInput, 0, $iv.Length)
    [Array]::Copy($ct, 0, $macInput, $iv.Length, $ct.Length)
    $calc = Get-Hmac -Key $mk -Data $macInput
    if (-not (Test-BytesEqual -A $calc -B $tag)) { throw '认证失败：口令不对，或密文被改过' }
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $aes.KeySize = 256
        $aes.Key = $ek
        $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        try { return , $dec.TransformFinalBlock($ct, 0, $ct.Length) } finally { $dec.Dispose() }
    } finally { $aes.Dispose() }
}

function Backup-File {
    param([string]$Path, [string]$BackupRoot)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $rel = $Path -replace '^[A-Za-z]:', '' -replace '[:\\/]', '_'
    $dst = Join-Path $BackupRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $Path -Destination $dst -Force
}
