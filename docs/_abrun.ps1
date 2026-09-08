# Is 2.4's scan slower than 2.3's? Runs both builds over an identical line set, alternating
# so machine drift (3-6 % run to run on this box) cannot be mistaken for a real difference.
#
# 2.4 is also run with its rule table emptied, which separates "the rule engine costs X" from
# "the 23 rules cost Y".
param(
    [string]$Log = '',
    [int]$Lines = 150000,
    [int]$Rounds = 2
)

$ErrorActionPreference = 'Stop'
$DocsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DocsRoot
if (-not $Log) { $Log = Join-Path $DocsRoot 'PVSS_II_Examples\PVSS_II_C2P.log' }

$stage = Join-Path $env:TEMP 'pvss_ab_stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

Push-Location $Root
try {
    # 2.3 = committed baseline, before the rule engine landed.
    git show HEAD:Watch/Watch-PvssLog.ps1 | Set-Content -LiteralPath (Join-Path $stage 'v23.ps1') -Encoding UTF8
}
finally { Pop-Location }
$v23 = Join-Path $stage 'v23.ps1'
if ((Get-Content $v23 -Raw) -match 'PvssRules\.ps1') { Write-Host 'NOTE: HEAD already references PvssRules.ps1 - HEAD may not be 2.3.' -ForegroundColor Yellow }

$v24 = Join-Path $Root 'Watch\Watch-PvssLog.ps1'
$rules = Join-Path $Root 'Watch\PvssRules.ps1'

# 2.4 engine with zero rules: keep every other 2.4 change, drop only the rule table.
$rulesEmpty = Join-Path $stage 'PvssRules.ps1'
$rt = [System.IO.File]::ReadAllText($rules)
$rt = [regex]::Replace($rt, '(?s)\$script:PvssRules = @\(.*?\r?\n\)\r?\n', "`$script:PvssRules = @()`r`n")
[System.IO.File]::WriteAllText($rulesEmpty, $rt)

$ab = Join-Path $DocsRoot '_ab.ps1'
Write-Host ("Log: {0}   lines: {1:N0}   rounds: {2}" -f (Split-Path -Leaf $Log), $Lines, $Rounds) -ForegroundColor Cyan
Write-Host ''

$cases = @(
    @{ Tag = '2.3'; S = $v23; R = '' }
    @{ Tag = '2.4-0'; S = $v24; R = $rulesEmpty }
    @{ Tag = '2.4'; S = $v24; R = $rules }
)

for ($r = 1; $r -le $Rounds; $r++) {
    Write-Host ("-- round {0}" -f $r) -ForegroundColor DarkGray
    foreach ($c in $cases) {
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ab,
            '-Script', $c.S, '-Log', $Log, '-Lines', $Lines, '-Tag', $c.Tag)
        if ($c.R) { $argv += @('-Rules', $c.R) }
        & powershell.exe @argv
    }
}

Write-Host ''
Write-Host '2.3    = committed baseline      2.4-0 = 2.4 with an empty rule table      2.4 = shipping' -ForegroundColor DarkGray
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
