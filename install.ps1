# session-review 훅 설치: 스크립트를 hooks 폴더에 두고 settings.json 의 SessionEnd 에 등록한다
$ErrorActionPreference = 'Stop'

# Windows 기본 PowerShell 5.1 에서는 아래 ConvertFrom-Json -AsHashtable 이 없어 설치가 중간에 끊긴다 → 시작 전에 막는다
$v = $PSVersionTable.PSVersion
if ($v.Major -lt 7 -or ($v.Major -eq 7 -and $v.Minor -lt 3)) {
    Write-Host "PowerShell 7.3 이상(pwsh)이 필요합니다. 현재: $v" -ForegroundColor Red
    Write-Host 'pwsh 창에서 다시 실행하세요. (설치: winget install Microsoft.PowerShell)'
    return
}

$Base     = 'https://raw.githubusercontent.com/Leeyuno0419/session-review-hook/main'
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$HooksDir  = Join-Path $ClaudeDir 'hooks'
$Script    = Join-Path $HooksDir 'session-review.ps1'
$Settings  = Join-Path $ClaudeDir 'settings.json'

# 1) 스크립트 배치: git clone 한 폴더에서 실행하면 복사, irm | iex 로 실행하면 내려받는다
New-Item -ItemType Directory -Force $HooksDir | Out-Null
$local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'session-review.ps1' }
if ($local -and (Test-Path $local)) { Copy-Item $local $Script -Force }
else { Invoke-WebRequest "$Base/session-review.ps1" -OutFile $Script }

# 2) settings.json 의 SessionEnd 에 등록 (이미 등록돼 있으면 건너뜀, 변경 전 .bak 백업)
$cfg = $null
if (Test-Path $Settings) {
    $cfg = Get-Content $Settings -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    Copy-Item $Settings "$Settings.bak" -Force
    $backedUp = $true
}
if (-not $cfg) { $cfg = @{} }
if (-not $cfg.ContainsKey('hooks')) { $cfg.hooks = @{} }

$registered = $cfg.hooks.SessionEnd | ForEach-Object { $_.hooks } | Where-Object { $_.command -like '*session-review.ps1*' }
if ($registered) {
    Write-Host '이미 등록되어 있습니다. 스크립트만 최신으로 갱신했어요.'
} else {
    $entry = @{ hooks = @(@{ type = 'command'; command = "pwsh -NoProfile -File `"$($Script -replace '\\', '/')`""; timeout = 15 }) }
    $prev  = @(if ($cfg.hooks.SessionEnd) { $cfg.hooks.SessionEnd })
    $cfg.hooks.SessionEnd = @($prev + $entry)
    [IO.File]::WriteAllText($Settings, ($cfg | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
    Write-Host "설치 완료: $Script"
    $bak = if ($backedUp) { " (백업: $Settings.bak)" }
    Write-Host "settings.json 에 SessionEnd 훅을 등록했습니다$bak. Claude Code 를 다시 시작하세요."
}
