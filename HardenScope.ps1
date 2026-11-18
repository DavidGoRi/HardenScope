#Requires -Version 5.1
<#
.SYNOPSIS
    HardenScope: read-only security hardening audit for Windows workstations.

.DESCRIPTION
    Reads the security settings of this computer (firewall, antivirus,
    BitLocker, updates, SMB, UAC, accounts, password policy, credential
    protection...), compares them with the rules in config\baseline.json and
    writes a JSON record and a self-contained HTML report with a score from
    0 to 100, a grade from A to F and how to fix every failed check.

    HardenScope never changes the computer. It works without administrator
    rights; a few checks give more detail when run as administrator.

.PARAMETER FactsPath
    Evaluates facts saved earlier (a HardenScope JSON record or a demo file)
    instead of reading this computer.

.PARAMETER FailOn
    Exit with code 2 when a check of this severity or higher fails. Useful in
    scheduled tasks or pipelines: -FailOn high.

.EXAMPLE
    .\HardenScope.ps1 -Open
    Audits this computer and opens the HTML report.

.EXAMPLE
    .\HardenScope.ps1 -FactsPath .\demo\WS-SALES-07.json -Language es
    Builds the report of a fictitious demo computer.
#>
[CmdletBinding()]
param(
    [string] $OutputPath,
    [string] $BaselinePath,
    [string] $FactsPath,
    [ValidateSet('en', 'es')] [string] $Language = $(if ((Get-Culture).TwoLetterISOLanguageName -eq 'es') { 'es' } else { 'en' }),
    [ValidateSet('none', 'low', 'medium', 'high', 'critical')] [string] $FailOn = 'none',
    [switch] $Open,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in parameter defaults under 'powershell -File', so the defaults go here
$here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
if (-not $OutputPath) { $OutputPath = Join-Path -Path $here -ChildPath 'output' }
if (-not $BaselinePath) { $BaselinePath = Join-Path -Path $here -ChildPath 'config\baseline.json' }
foreach ($file in 'Facts', 'Rules', 'Report') { . (Join-Path -Path $here -ChildPath "src\$file.ps1") }

$baseline = Import-HSBaseline -Path $BaselinePath
$errors = @()
if ($FactsPath) {
    $saved = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $FactsPath).ProviderPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $saved.facts) { throw "$FactsPath has no 'facts' object" }
    $facts = $saved.facts
    $computerName = if ($saved.device.name) { $saved.device.name } elseif ($saved.computerName) { $saved.computerName } else { 'UNKNOWN' }
}
else {
    if (-not $Quiet) { Write-Host 'Reading the security settings of this computer...' -ForegroundColor DarkGray }
    $collected = Get-HSFact
    $facts = $collected.Facts
    $errors = $collected.Errors
    $computerName = $env:COMPUTERNAME
}

$results = @(Invoke-HSAssessment -Facts $facts -Baseline $baseline)
$score = Get-HSScore -Results $results
$record = New-HSRecord -ComputerName $computerName -Facts $facts -Baseline $baseline -Results $results -Score $score -Errors $errors

# .NET resolves relative paths against the process folder, not the PowerShell location
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path -Path $OutputPath -ChildPath "$computerName-$stamp.json"
$htmlPath = Join-Path -Path $OutputPath -ChildPath "$computerName-$stamp.html"
Save-HSRecord -Record $record -Path $jsonPath
Save-HSHtmlReport -Record $record -Path $htmlPath

if (-not $Quiet) {
    $text = @{
        en = @{ score = 'Hardening score'; grade = 'grade'; failed = 'Failed checks'; none = 'No failed checks.'; unknown = 'could not be read'; report = 'Report' }
        es = @{ score = 'Nota de bastionado'; grade = 'nota'; failed = 'Comprobaciones con fallo'; none = 'Ninguna comprobación ha fallado.'; unknown = 'no se pudieron leer'; report = 'Informe' }
    }[$Language]
    $colors = @{ A = 'Green'; B = 'Green'; C = 'Yellow'; D = 'DarkYellow'; F = 'Red' }
    $severityColors = @{ critical = 'Red'; high = 'DarkYellow'; medium = 'Yellow'; low = 'Cyan' }
    Write-Host ''
    Write-Host ("  {0}  {1}: {2}/100 ({3} {4})" -f $computerName, $text.score, $score.Score, $text.grade, $score.Grade) -ForegroundColor $colors[[string] $score.Grade]
    Write-Host ''
    $failed = @($results | Where-Object { $_.Status -eq 'Fail' } |
            Sort-Object -Property @{ Expression = { @('critical', 'high', 'medium', 'low').IndexOf($_.Severity) } }, Id)
    if ($failed.Count -eq 0) { Write-Host "  $($text.none)" -ForegroundColor Green }
    else {
        Write-Host "  $($text.failed):"
        foreach ($item in $failed) {
            Write-Host ('  {0,-9}' -f $item.Severity.ToUpperInvariant()) -ForegroundColor $severityColors[$item.Severity] -NoNewline
            Write-Host (' {0,-11} {1}' -f $item.Id, $item.Title.$Language)
        }
    }
    if ($score.Unknown -gt 0) { Write-Host ("`n  {0} {1}" -f $score.Unknown, $text.unknown) -ForegroundColor DarkGray }
    foreach ($message in $errors) { Write-Host "  ! $message" -ForegroundColor DarkGray }
    Write-Host "`n  $($text.report): $htmlPath`n"
}

if ($Open) { Start-Process -FilePath $htmlPath }
if ($PassThru) { [pscustomobject] @{ Record = $record; JsonPath = $jsonPath; HtmlPath = $htmlPath } }

if ($FailOn -ne 'none') {
    $levels = @('low', 'medium', 'high', 'critical')
    $threshold = $levels.IndexOf($FailOn)
    $blocking = @($results | Where-Object { $_.Status -eq 'Fail' -and $levels.IndexOf($_.Severity) -ge $threshold })
    if ($blocking.Count -gt 0) { exit 2 }
}
