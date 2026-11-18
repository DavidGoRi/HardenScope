#Requires -Version 5.1
# Fleet view: one summary of many computer records, with the checks that fail
# on most computers first (the fixes worth rolling out by Group Policy).

function Read-HSRecord {
    # Reads one HardenScope JSON record, or $null when the file is something else
    param([Parameter(Mandatory)] [string] $Path)
    try { $record = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
    if ($record.tool -ne 'HardenScope' -or -not $record.device -or -not $record.results) { return $null }
    $record | Add-Member -NotePropertyName '_path' -NotePropertyValue $Path -Force
    return $record
}

function Get-HSLatestRecord {
    <#
    .SYNOPSIS
        The newest record of every computer in a folder.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path" }
    $records = foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.json' -File) {
        $record = Read-HSRecord -Path $file.FullName
        if ($record) { $record }
    }
    @($records | Group-Object -Property { $_.device.name } | ForEach-Object {
            $_.Group | Sort-Object -Property { [datetimeoffset] $_.generatedAt } -Descending | Select-Object -First 1
        })
}

function New-HSFleetRecord {
    <#
    .SYNOPSIS
        Builds the fleet summary from computer records. -Unreachable lists the
        computers that could not be audited (objects with ComputerName and Message).
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records,
        [object[]] $Unreachable = @(),
        [datetimeoffset] $GeneratedAt = (Get-Date)
    )
    $computers = @($Records | Sort-Object -Property @{ Expression = { if ($null -eq $_.score.score) { 999 } else { $_.score.score } } }, @{ Expression = { $_.device.name } } | ForEach-Object {
            $report = $null
            if ($_._path) { $report = [IO.Path]::ChangeExtension([IO.Path]::GetFileName($_._path), '.html') }
            $change = $null
            if ($_.changes) {
                $change = [ordered] @{ scoreDelta = $_.changes.scoreDelta; fixed = @($_.changes.fixed).Count; regressed = @($_.changes.regressed).Count }
            }
            [ordered] @{
                name             = $_.device.name
                os               = $_.device.os
                generatedAt      = $_.generatedAt
                score            = $_.score.score
                grade            = $_.score.grade
                failed           = $_.score.failed
                unknown          = $_.score.unknown
                failedBySeverity = $_.score.failedBySeverity
                report           = $report
                change           = $change
            }
        })

    $rules = [ordered] @{}
    foreach ($record in $Records) {
        foreach ($result in @($record.results)) {
            if (-not $rules.Contains($result.id)) {
                $rules[$result.id] = [ordered] @{
                    id = $result.id; category = $result.category; severity = $result.severity; title = $result.title
                    risk = $result.risk; fix = $result.fix; command = $result.command; failedOn = New-Object -TypeName System.Collections.Generic.List[string]
                }
            }
            if ($result.status -eq 'Fail') { $rules[$result.id].failedOn.Add([string] $record.device.name) }
        }
    }
    $order = @('critical', 'high', 'medium', 'low')
    $failing = @($rules.Values | Where-Object { $_.failedOn.Count -gt 0 } |
            Sort-Object -Property @{ Expression = { $_.failedOn.Count }; Descending = $true }, @{ Expression = { $order.IndexOf($_.severity) } }, @{ Expression = { $_.id } } |
            ForEach-Object {
                $item = $_
                $item.failedCount = $item.failedOn.Count
                $item.failedOn = @($item.failedOn | Sort-Object)
                $item
            })

    $scores = @($computers | Where-Object { $null -ne $_.score } | ForEach-Object { $_.score })
    $average = $null
    if ($scores.Count -gt 0) { $average = [int] [Math]::Round(($scores | Measure-Object -Average).Average) }
    $grades = [ordered] @{ A = 0; B = 0; C = 0; D = 0; F = 0 }
    foreach ($computer in $computers) { if ($computer.grade -and $grades.Contains([string] $computer.grade)) { $grades[[string] $computer.grade]++ } }
    $withCritical = @($computers | Where-Object { [int] $_.failedBySeverity.critical -gt 0 }).Count
    $compared = @($computers | Where-Object { $_.change })
    $regressions = ($compared | ForEach-Object { $_.change.regressed } | Measure-Object -Sum).Sum

    $baseline = $null
    if ($Records.Count -gt 0) { $baseline = $Records[0].baseline }
    return [ordered] @{
        tool        = 'HardenScope'
        kind        = 'fleet'
        version     = $script:HSVersion
        generatedAt = $GeneratedAt.ToString('yyyy-MM-ddTHH:mm:sszzz')
        baseline    = $baseline
        summary     = [ordered] @{
            computers = $computers.Count; unreachable = @($Unreachable).Count; averageScore = $average
            grades = $grades; withCriticalFailures = $withCritical
            compared = $compared.Count; regressions = [int] $regressions
            improved = @($compared | Where-Object { $_.change.scoreDelta -gt 0 }).Count
            worsened = @($compared | Where-Object { $_.change.scoreDelta -lt 0 }).Count
        }
        computers   = $computers
        failing     = $failing
        unreachable = @($Unreachable | ForEach-Object { [ordered] @{ name = [string] $_.ComputerName; message = [string] $_.Message } })
    }
}

function Save-HSFleetReport {
    <#
    .SYNOPSIS
        Writes fleet-<stamp>.json and fleet-<stamp>.html. Returns the HTML path.
    #>
    param([Parameter(Mandatory)] $Fleet, [Parameter(Mandatory)] [string] $OutputPath, [Parameter(Mandatory)] [string] $Stamp)
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $jsonPath = Join-Path -Path $OutputPath -ChildPath "fleet-$Stamp.json"
    $htmlPath = Join-Path -Path $OutputPath -ChildPath "fleet-$Stamp.html"
    [IO.File]::WriteAllText($jsonPath, ($Fleet | ConvertTo-Json -Depth 8), $utf8)
    $html = ConvertTo-HSHtml -Record $Fleet -TemplatePath (Join-Path -Path $PSScriptRoot -ChildPath 'fleet-template.html')
    [IO.File]::WriteAllText($htmlPath, $html, $utf8)
    return $htmlPath
}
