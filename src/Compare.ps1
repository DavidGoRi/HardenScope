#Requires -Version 5.1
# Changes between two audits of the same computer: what got fixed, what broke
# (a regression: a check that passed and now fails) and how the score moved.

function Get-HSPreviousRecord {
    <#
    .SYNOPSIS
        The newest record of a computer in a folder that is older than -Before.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [datetimeoffset] $Before
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    $prefix = ($ComputerName -replace '[^\w.-]', '_') + '-'
    $candidates = foreach ($file in Get-ChildItem -LiteralPath $Path -Filter "$prefix*.json" -File) {
        $record = Read-HSRecord -Path $file.FullName
        if ($record -and $record.device.name -eq $ComputerName -and [datetimeoffset] $record.generatedAt -lt $Before) { $record }
    }
    return @($candidates | Sort-Object -Property { [datetimeoffset] $_.generatedAt } -Descending | Select-Object -First 1)[0]
}

function Compare-HSResult {
    <#
    .SYNOPSIS
        Compares the results of the current audit with an earlier record.
        Only Pass <-> Fail transitions count; a check that could not be read
        in one of the two audits is not a change.
    #>
    param(
        [Parameter(Mandatory)] $Previous,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results,
        [Parameter(Mandatory)] $Score
    )
    $before = @{}
    foreach ($item in @($Previous.results)) { $before[[string] $item.id] = [string] $item.status }
    $fixed = New-Object -TypeName System.Collections.Generic.List[string]
    $regressed = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($result in $Results) {
        # Property names are case-insensitive: this reads both the objects of
        # Invoke-HSAssessment (Id) and the records read back from JSON (id)
        $id = [string] $result.Id
        $now = [string] $result.Status
        if (-not $before.ContainsKey($id)) { continue }
        if ($before[$id] -eq 'Fail' -and $now -eq 'Pass') { $fixed.Add($id) }
        elseif ($before[$id] -eq 'Pass' -and $now -eq 'Fail') { $regressed.Add($id) }
    }
    $delta = $null
    if ($null -ne $Score.Score -and $null -ne $Previous.score.score) { $delta = [int] $Score.Score - [int] $Previous.score.score }
    return [ordered] @{
        previousAt    = [string] $Previous.generatedAt
        previousScore = $Previous.score.score
        previousGrade = $Previous.score.grade
        scoreDelta    = $delta
        fixed         = @($fixed)
        regressed     = @($regressed)
    }
}
