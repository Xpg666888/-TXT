# ============================================================
#  YG-SOUL / seal.ps1  —  凭据封存/开封（AES-256-GCM + PBKDF2 30万轮）
#  用法:
#    pwsh -File soul\tools\seal.ps1 -Action seal   -In "E:\...\.credentials.yaml"
#    pwsh -File soul\tools\seal.ps1 -Action unseal -Out "E:\...\.credentials.yaml"
#    pwsh -File soul\tools\seal.ps1 -Action rotate          # 换口令重新封装
#  口令来源: -Password / $env:YG_SOUL_PASS / %USERPROFILE%\.yg-soul\pass.txt
# ============================================================
param(
    [Parameter(Mandatory)][ValidateSet('seal', 'unseal', 'rotate', 'newpass')]
    [string]$Action,
    [string]$In,
    [string]$Out,
    [string]$Password,
    [switch]$Force
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$soul   = Get-SoulDir
$sealed = Join-Path $soul 'secrets\credentials.sealed.json'

switch ($Action) {
    'seal' {
        if (-not $In) { $In = Join-Path (Get-DshHome) '.credentials.yaml' }
        if (-not (Test-Path $In)) { throw "找不到要封存的文件: $In" }
        $pw = Get-SoulPassword -Password $Password -Generate
        $blob = Protect-SoulBlob -Plain ([IO.File]::ReadAllBytes($In)) -Password $pw
        $blob | Add-Member -NotePropertyName source   -NotePropertyValue $In -Force
        $blob | Add-Member -NotePropertyName sealedAt -NotePropertyValue ((Get-Date).ToString('s')) -Force
        [IO.File]::WriteAllText($sealed, ($blob | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Write-Ok "已封存 -> $sealed"
    }
    'unseal' {
        if (-not (Test-Path $sealed)) { throw "没有 $sealed" }
        if (-not $Out) { $Out = Join-Path (Get-DshHome) '.credentials.yaml' }
        if ((Test-Path $Out) -and -not $Force) { throw "目标已存在: $Out（加 -Force 覆盖）" }
        $blob = Get-Content $sealed -Raw | ConvertFrom-Json
        $pw = Get-SoulPassword -Password $Password
        $pt = Unprotect-SoulBlob -Blob $blob -Password $pw
        $dir = Split-Path -Parent $Out
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllBytes($Out, $pt)
        Write-Ok ("已开封 -> {0}（{1} 字节）" -f $Out, $pt.Length)
    }
    'rotate' {
        $pw = Get-SoulPassword -Password $Password
        $blob = Get-Content $sealed -Raw | ConvertFrom-Json
        $pt = Unprotect-SoulBlob -Blob $blob -Password $pw
        $f = Join-Path (Join-Path $env:USERPROFILE '.yg-soul') 'pass.txt'
        if (Test-Path $f) { Remove-Item $f -Force }
        $new = Get-SoulPassword -Generate
        $nb = Protect-SoulBlob -Plain $pt -Password $new
        $nb | Add-Member -NotePropertyName source   -NotePropertyValue 'rotate' -Force
        $nb | Add-Member -NotePropertyName sealedAt -NotePropertyValue ((Get-Date).ToString('s')) -Force
        [IO.File]::WriteAllText($sealed, ($nb | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        Write-Ok '口令已轮换（旧口令作废，新口令在 %USERPROFILE%\.yg-soul\pass.txt）'
    }
    'newpass' {
        $f = Join-Path (Join-Path $env:USERPROFILE '.yg-soul') 'pass.txt'
        if (Test-Path $f) { Remove-Item $f -Force }
        $null = Get-SoulPassword -Generate
        Write-Ok "新口令已生成 -> $f"
    }
}
