#Requires -Version 5.1
<#
.SYNOPSIS
    HardenScope: read-only security hardening audit for Windows workstations.

.DESCRIPTION
    Reads the security settings of a computer (firewall, antivirus, BitLocker,
    updates, SMB, UAC, accounts, password policy, credential protection...),
    compares them with the rules in config\baseline.json and writes a JSON
    record and a self-contained HTML report with a score from 0 to 100, a
    grade from A to F and how to fix every failed check.

    With -ComputerName or -ComputerListPath it audits several computers over
    WinRM at the same time and also writes a fleet report: every computer,
    its score, and the checks that fail on most of them.

    HardenScope never changes any computer. Locally it works without
    administrator rights.

.PARAMETER ComputerName
    Computers to audit over WinRM. localhost, . and this computer's name are
    audited locally, without WinRM.

.PARAMETER ComputerListPath
    Text file with one computer name per line (# starts a comment).

.PARAMETER FactsPath
    Evaluates facts saved earlier (HardenScope JSON records or demo files)
    instead of reading a computer. Accepts wildcards: .\demo\*.json

.PARAMETER FleetFrom
    Builds the fleet report again from the newest record of every computer
    in a folder of earlier runs.

.PARAMETER FailOn
    Exit with code 2 when a check of this severity or higher fails on any
    computer. Useful in scheduled tasks or pipelines: -FailOn high.

.EXAMPLE
    .\HardenScope.ps1 -Open
    Audits this computer and opens the HTML report.

.EXAMPLE
    .\HardenScope.ps1 -ComputerListPath .\computers.txt -Credential (Get-Credential CORP\it.admin) -Open
    Audits every computer in the list and opens the fleet report.

.EXAMPLE
    .\HardenScope.ps1 -FactsPath .\demo\*.json -Language es -Open
    Builds the fleet report of the fictitious demo computers.
#>
[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [Parameter(ParameterSetName = 'Remote', Mandatory)] [string[]] $ComputerName,
    [Parameter(ParameterSetName = 'List', Mandatory)] [string] $ComputerListPath,
    [Parameter(ParameterSetName = 'Remote')] [Parameter(ParameterSetName = 'List')] [pscredential] $Credential,
    [Parameter(ParameterSetName = 'Remote')] [Parameter(ParameterSetName = 'List')] [ValidateRange(1, 256)] [int] $ThrottleLimit = 32,
    [Parameter(ParameterSetName = 'Facts', Mandatory)] [string[]] $FactsPath,
    [Parameter(ParameterSetName = 'Fleet', Mandatory)] [string] $FleetFrom,
    [string] $OutputPath,
    [string] $BaselinePath,
    [ValidateSet('en', 'es')] [string] $Language = $(if ((Get-Culture).TwoLetterISOLanguageName -eq 'es') { 'es' } else { 'en' }),
    [ValidateSet('none', 'low', 'medium', 'high', 'critical')] [string] $FailOn = 'none',
    [string] $CompareWith,
    [switch] $NoCompare,
    [switch] $FailOnRegression,
    [switch] $Open,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in parameter defaults under 'powershell -File', so the defaults go here
$here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
foreach ($file in 'Facts', 'Rules', 'Report', 'Remote', 'Fleet', 'Compare') { . (Join-Path -Path $here -ChildPath "src\$file.ps1") }
$resolve = { param($path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path) }

if (-not $BaselinePath) { $BaselinePath = Join-Path -Path $here -ChildPath 'config\baseline.json' }
if (-not $OutputPath) { $OutputPath = if ($FleetFrom) { $FleetFrom } else { Join-Path -Path $here -ChildPath 'output' } }
# .NET resolves relative paths against the process folder, not the PowerShell location
$OutputPath = & $resolve $OutputPath
if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$text = @{
    en = @{
        reading = 'Reading the security settings...'; score = 'Hardening score'; grade = 'grade'; failed = 'Failed checks'
        none = 'No failed checks.'; unknown = 'could not be read'; report = 'Report'; fleet = 'Fleet report'
        since = 'Since the audit of'; fixedN = 'fixed'; regressedN = 'new failures'; first = 'First audit of this computer: nothing to compare.'
        computer = 'Computer'; scoreShort = 'Score'; critHigh = 'Critical / high'; unreachable = 'Not audited'; average = 'Average score'; top = 'Most common failures'
    }
    es = @{
        reading = 'Leyendo la configuración de seguridad...'; score = 'Nota de bastionado'; grade = 'nota'; failed = 'Comprobaciones con fallo'
        none = 'Ninguna comprobación ha fallado.'; unknown = 'no se pudieron leer'; report = 'Informe'; fleet = 'Informe de la flota'
        since = 'Desde la auditoría del'; fixedN = 'arreglados'; regressedN = 'fallos nuevos'; first = 'Primera auditoría de este equipo: no hay con qué comparar.'
        computer = 'Equipo'; scoreShort = 'Nota'; critHigh = 'Críticos / altos'; unreachable = 'Sin auditar'; average = 'Nota media'; top = 'Fallos más repetidos'
    }
}[$Language]
$severityOrder = @('critical', 'high', 'medium', 'low')
$severityColors = @{ critical = 'Red'; high = 'DarkYellow'; medium = 'Yellow'; low = 'Cyan' }
$gradeColors = @{ A = 'Green'; B = 'Green'; C = 'Yellow'; D = 'DarkYellow'; F = 'Red' }

# 1. Collect: one target per computer, with its facts or why it failed
$targets = @()
$fleetMode = $PSCmdlet.ParameterSetName -ne 'Local'
switch ($PSCmdlet.ParameterSetName) {
    'Local' {
        if (-not $Quiet) { Write-Host $text.reading -ForegroundColor DarkGray }
        $collected = Get-HSFact
        $targets += New-HSCollectionResult -ComputerName $env:COMPUTERNAME -Status 'OK' -Facts $collected.Facts -Errors $collected.Errors
    }
    'Facts' {
        $files = @(foreach ($pattern in $FactsPath) { Resolve-Path -Path $pattern | ForEach-Object { $_.ProviderPath } }) | Select-Object -Unique
        foreach ($path in $files) {
            $saved = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if (-not $saved.facts) { throw "$path has no 'facts' object" }
            $name = if ($saved.device.name) { $saved.device.name } elseif ($saved.computerName) { $saved.computerName } else { [IO.Path]::GetFileNameWithoutExtension($path) }
            $target = New-HSCollectionResult -ComputerName $name -Status 'OK' -Facts $saved.facts -Errors @($saved.errors | Where-Object { $_ })
            # Saved facts keep the date they were collected on
            if ($saved.generatedAt) { $target | Add-Member -NotePropertyName GeneratedAt -NotePropertyValue ([datetimeoffset] $saved.generatedAt) }
            $targets += $target
        }
        $fleetMode = $files.Count -gt 1
    }
    { $_ -in 'Remote', 'List' } {
        $names = if ($ComputerListPath) { Get-HSComputerList -Path $ComputerListPath } else { @($ComputerName | Select-Object -Unique) }
        $isLocal = { param($n) @('localhost', '.', '127.0.0.1', $env:COMPUTERNAME) -contains $n }
        $remoteNames = @($names | Where-Object { -not (& $isLocal $_) })
        if (-not $Quiet) { Write-Host "$($text.reading) ($(@($names).Count))" -ForegroundColor DarkGray }
        $remote = @{}
        if ($remoteNames.Count -gt 0) {
            $remoteParameters = @{ ComputerName = $remoteNames; ThrottleLimit = $ThrottleLimit }
            if ($Credential) { $remoteParameters.Credential = $Credential }
            $index = 0
            foreach ($result in @(Invoke-HSRemoteCollection @remoteParameters)) { $remote[$remoteNames[$index]] = $result; $index++ }
        }
        foreach ($name in $names) {
            if (& $isLocal $name) {
                $collected = Get-HSFact
                $targets += New-HSCollectionResult -ComputerName $env:COMPUTERNAME -Status 'OK' -Facts $collected.Facts -Errors $collected.Errors
            }
            else { $targets += $remote[$name] }
        }
    }
}

$baseline = Import-HSBaseline -Path $BaselinePath
$audited = @()
$unreachable = @($targets | Where-Object { $_.Status -ne 'OK' })

# 2. Evaluate and save one report per computer (the fleet view reads them back)
if ($PSCmdlet.ParameterSetName -eq 'Fleet') {
    $records = @(Get-HSLatestRecord -Path (& $resolve $FleetFrom))
    $fleetMode = $true
}
else {
    $okTargets = @($targets | Where-Object { $_.Status -eq 'OK' })
    if ($CompareWith -and $okTargets.Count -ne 1) { throw '-CompareWith works with a single computer' }
    foreach ($target in $okTargets) {
        # A date with its own offset: the record keeps the time zone it was collected in
        $when = if ($target.PSObject.Properties['GeneratedAt']) { $target.GeneratedAt } else { [datetimeoffset] (Get-Date) }
        $results = @(Invoke-HSAssessment -Facts $target.Facts -Baseline $baseline)
        $score = Get-HSScore -Results $results
        $previous = $null
        if ($CompareWith) {
            $previous = Read-HSRecord -Path (& $resolve $CompareWith)
            if (-not $previous) { throw "$CompareWith is not a HardenScope record" }
        }
        elseif (-not $NoCompare) { $previous = Get-HSPreviousRecord -Path $OutputPath -ComputerName $target.ComputerName -Before $when }
        $changes = if ($previous) { Compare-HSResult -Previous $previous -Results $results -Score $score } else { $null }
        $record = New-HSRecord -ComputerName $target.ComputerName -Facts $target.Facts -Baseline $baseline -Results $results -Score $score -Errors $target.Errors -GeneratedAt $when -Changes $changes
        $safeName = $target.ComputerName -replace '[^\w.-]', '_'
        $fileStamp = $when.ToString('yyyyMMdd-HHmmss')
        $jsonPath = Join-Path -Path $OutputPath -ChildPath "$safeName-$fileStamp.json"
        $htmlPath = Join-Path -Path $OutputPath -ChildPath "$safeName-$fileStamp.html"
        Save-HSRecord -Record $record -Path $jsonPath
        Save-HSHtmlReport -Record $record -Path $htmlPath
        $audited += [pscustomobject] @{ Record = $record; Results = $results; Errors = $target.Errors; JsonPath = $jsonPath; HtmlPath = $htmlPath }
    }
    $records = @($audited | ForEach-Object { Read-HSRecord -Path $_.JsonPath })
}

$fleetPath = $null
if ($fleetMode) {
    $fleet = New-HSFleetRecord -Records $records -Unreachable $unreachable
    $fleetPath = Save-HSFleetReport -Fleet $fleet -OutputPath $OutputPath -Stamp $stamp
}

# 3. Console summary
if (-not $Quiet) {
    Write-Host ''
    if ($fleetMode) {
        Write-Host ('  {0,-20} {1,5}  {2}  {3}' -f $text.computer, $text.scoreShort, ' ', $text.critHigh) -ForegroundColor DarkGray
        foreach ($computer in $fleet.computers) {
            $line = '  {0,-20} {1,5}  {2}  {3} / {4}' -f $computer.name, $computer.score, $computer.grade, $computer.failedBySeverity.critical, $computer.failedBySeverity.high
            if ($computer.change) {
                $line += '    {0}{1}' -f $(if ($computer.change.scoreDelta -gt 0) { '+' } else { '' }), $computer.change.scoreDelta
                if ($computer.change.regressed -gt 0) { $line += " (+$($computer.change.regressed) $($text.regressedN))" }
            }
            Write-Host $line -ForegroundColor $(if ($computer.grade) { $gradeColors[[string] $computer.grade] } else { 'Gray' })
        }
        foreach ($item in $fleet.unreachable) {
            # WinRM errors are very long: the full text is in the fleet report
            $reason = if ($item.message.Length -gt 90) { $item.message.Substring(0, 90) + '...' } else { $item.message }
            Write-Host ('  {0,-20} {1}: {2}' -f $item.name, $text.unreachable, $reason) -ForegroundColor DarkGray
        }
        Write-Host ("`n  {0}: {1}" -f $text.average, $fleet.summary.averageScore)
        if ($fleet.failing.Count -gt 0) {
            Write-Host "  $($text.top):"
            foreach ($item in @($fleet.failing | Select-Object -First 5)) {
                Write-Host ('  {0,-9}' -f $item.severity.ToUpperInvariant()) -ForegroundColor $severityColors[$item.severity] -NoNewline
                Write-Host (' {0,-11} {1}/{2}  {3}' -f $item.id, $item.failedCount, $fleet.summary.computers, $item.title.$Language)
            }
        }
        Write-Host "`n  $($text.fleet): $fleetPath`n"
    }
    elseif ($audited.Count -eq 1) {
        $one = $audited[0]
        $score = $one.Record.score
        Write-Host ("  {0}  {1}: {2}/100 ({3} {4})" -f $one.Record.device.name, $text.score, $score.score, $text.grade, $score.grade) -ForegroundColor $gradeColors[[string] $score.grade]
        Write-Host ''
        $failed = @($one.Results | Where-Object { $_.Status -eq 'Fail' } | Sort-Object -Property @{ Expression = { $severityOrder.IndexOf($_.Severity) } }, Id)
        if ($failed.Count -eq 0) { Write-Host "  $($text.none)" -ForegroundColor Green }
        else {
            Write-Host "  $($text.failed):"
            foreach ($item in $failed) {
                Write-Host ('  {0,-9}' -f $item.Severity.ToUpperInvariant()) -ForegroundColor $severityColors[$item.Severity] -NoNewline
                Write-Host (' {0,-11} {1}' -f $item.Id, $item.Title.$Language)
            }
        }
        if ($score.unknown -gt 0) { Write-Host ("`n  {0} {1}" -f $score.unknown, $text.unknown) -ForegroundColor DarkGray }
        $change = $one.Record.changes
        if ($change) {
            $delta = if ($null -eq $change.scoreDelta) { '' } elseif ($change.scoreDelta -ge 0) { "+$($change.scoreDelta)" } else { [string] $change.scoreDelta }
            $deltaColor = if ($change.scoreDelta -gt 0) { 'Green' } elseif ($change.scoreDelta -lt 0) { 'Red' } else { 'Gray' }
            Write-Host ("`n  {0} {1:yyyy-MM-dd HH:mm}: {2} -> {3} ({4}); {5} {6}, {7} {8}" -f $text.since, ([datetimeoffset] $change.previousAt), $change.previousScore, $score.score, $delta,
                    @($change.fixed).Count, $text.fixedN, @($change.regressed).Count, $text.regressedN) -ForegroundColor $deltaColor
            foreach ($id in @($change.regressed)) {
                $item = $one.Results | Where-Object { $_.Id -eq $id }
                Write-Host ('  + {0,-11} {1}' -f $id, $item.Title.$Language) -ForegroundColor Red
            }
            foreach ($id in @($change.fixed)) {
                $item = $one.Results | Where-Object { $_.Id -eq $id }
                Write-Host ('  - {0,-11} {1}' -f $id, $item.Title.$Language) -ForegroundColor Green
            }
        }
        elseif (-not $NoCompare) { Write-Host "`n  $($text.first)" -ForegroundColor DarkGray }
        foreach ($message in $one.Errors) { Write-Host "  ! $message" -ForegroundColor DarkGray }
        Write-Host "`n  $($text.report): $($one.HtmlPath)`n"
    }
}

$mainReport = if ($fleetPath) { $fleetPath } elseif ($audited.Count -gt 0) { $audited[0].HtmlPath } else { $null }
if ($Open -and $mainReport) { Start-Process -FilePath $mainReport }
if ($PassThru) {
    [pscustomobject] @{
        Record      = $(if ($audited.Count -gt 0) { $audited[0].Record } else { $null })
        JsonPath    = $(if ($audited.Count -gt 0) { $audited[0].JsonPath } else { $null })
        HtmlPath    = $(if ($audited.Count -gt 0) { $audited[0].HtmlPath } else { $null })
        Computers   = $audited
        Unreachable = $unreachable
        Fleet       = $(if ($fleetMode) { $fleet } else { $null })
        FleetPath   = $fleetPath
    }
}

if ($FailOnRegression) {
    $regressions = @($records | Where-Object { $_.changes -and @($_.changes.regressed).Count -gt 0 })
    if ($regressions.Count -gt 0) { exit 3 }
}
if ($FailOn -ne 'none') {
    $threshold = $severityOrder.IndexOf($FailOn)
    $blocking = @($records | ForEach-Object { $_.results } | Where-Object { $_.status -eq 'Fail' -and $severityOrder.IndexOf($_.severity) -le $threshold })
    if ($blocking.Count -gt 0) { exit 2 }
}
