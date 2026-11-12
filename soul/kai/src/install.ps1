<#
  kai install — 一条命令把能力内核装到可用状态
    .\install.ps1              常规：确保 venv + 注入精选技能 + 体检
    .\install.ps1 -AllSkills   额外注入全部 103 个技能（会显著占用技能目录 token）
    .\install.ps1 -Force       重建 venv
#>
[CmdletBinding()]
param(
  [switch]$AllSkills,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "   OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "   !!  $msg" -ForegroundColor Yellow }

# 1. node
Step 'node'
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw ' 需要 Node.js 20+（kai 主体是零依赖 ESM）' }
Ok "node $(& node -v)"

# 2. python venv
Step 'python venv'
$venvPy = Join-Path $Root 'runtime\venv\Scripts\python.exe'
if ($Force -and (Test-Path (Join-Path $Root 'runtime\venv'))) {
  Remove-Item -Recurse -Force (Join-Path $Root 'runtime\venv')
}
if (-not (Test-Path $venvPy)) {
  $uv = Get-Command uv -ErrorAction SilentlyContinue
  if (-not $uv) { throw '需要 uv（winget install astral-sh.uv）或自行准备 Python 3.12 + pip' }
  $base = Get-ChildItem (Join-Path $Root 'runtime\python') -Recurse -Filter python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $base) {
    & uv python install 3.12 --install-dir (Join-Path $Root 'runtime\python')
    $base = Get-ChildItem (Join-Path $Root 'runtime\python') -Recurse -Filter python.exe | Select-Object -First 1
  }
  & uv venv (Join-Path $Root 'runtime\venv') --python $base.FullName
  & uv pip install --python $venvPy pefile capstone pyelftools lief requests
  Ok 'venv 已创建'
} else {
  Ok 'venv 已存在'
}
& $venvPy -c "import pefile,capstone,lief;from elftools.elf.elffile import ELFFile" 2>$null
if ($LASTEXITCODE -eq 0) { Ok 'py 包齐备 (pefile/capstone/lief/pyelftools)' } else { Warn 'py 包缺失，跑 uv pip install --python runtime\venv\Scripts\python.exe pefile capstone pyelftools lief requests' }

# 3. 知识库
Step 'hack-skills 知识库'
$vendor = Join-Path $Root 'vendor\hack-skills\skills'
if (-not (Test-Path $vendor)) {
  Warn 'vendor/hack-skills 缺失，尝试下载'
  $zip = Join-Path $Root 'vendor\hack-skills.zip'
  New-Item -ItemType Directory -Force (Join-Path $Root 'vendor') | Out-Null
  curl.exe -sSL --max-time 180 -o $zip 'https://codeload.github.com/yaklang/hack-skills/zip/refs/heads/main'
  Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $Root 'vendor\_hs') -Force
  $d = Get-ChildItem (Join-Path $Root 'vendor\_hs') -Directory | Select-Object -First 1
  Move-Item $d.FullName (Join-Path $Root 'vendor\hack-skills') -Force
  Remove-Item -Recurse -Force (Join-Path $Root 'vendor\_hs')
}
Ok "$((Get-ChildItem $vendor -Directory).Count) skills @ vendor\hack-skills"

# 4. 注入 DSH 技能根
Step '注入 DSH 技能根'
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
if ($AllSkills) { & node bin\kai.mjs skills install --all } else { & node bin\kai.mjs skills install }
Ok "$dshHome\skills"

# 5. 体检
Step 'doctor'
& node bin\kai.mjs doctor

Write-Host "`n完成。下一步：" -ForegroundColor Cyan
Write-Host '   .\bin\kai.cmd case init demo'
Write-Host '   .\bin\kai.cmd probe <sample> --case demo'
Write-Host '   .\bin\kai.cmd kb 卡密'
