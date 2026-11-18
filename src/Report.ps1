#Requires -Version 5.1
# Assessment record (JSON) and the self-contained HTML report.

$script:HSVersion = '0.4.0'

function New-HSRecord {
    <#
    .SYNOPSIS
        Builds the record saved as JSON and embedded in the HTML report.
    #>
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] $Facts,
        [Parameter(Mandatory)] $Baseline,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results,
        [Parameter(Mandatory)] $Score,
        [string[]] $Errors = @(),
        [datetimeoffset] $GeneratedAt = (Get-Date),
        # From Compare-HSResult: changes since the previous audit, or $null
        $Changes = $null
    )
    $osCaption = Get-HSFactValue -Facts $Facts -Name 'os.caption'
    $osBuild = Get-HSFactValue -Facts $Facts -Name 'os.build'
    $severities = [ordered] @{}
    foreach ($key in $Score.FailedBySeverity.Keys) { $severities[$key] = $Score.FailedBySeverity[$key] }
    return [ordered] @{
        tool        = 'HardenScope'
        version     = $script:HSVersion
        generatedAt = $GeneratedAt.ToString('yyyy-MM-ddTHH:mm:sszzz')
        device      = [ordered] @{ name = $ComputerName; os = ("$osCaption (build $osBuild)").Trim() }
        baseline    = [ordered] @{ name = $Baseline.name; version = $Baseline.version }
        score       = [ordered] @{
            score = $Score.Score; grade = $Score.Grade; passed = $Score.Passed; failed = $Score.Failed
            unknown = $Score.Unknown; notApplicable = $Score.NotApplicable; failedBySeverity = $severities
        }
        results     = @($Results | ForEach-Object {
                [ordered] @{
                    id = $_.Id; category = $_.Category; severity = $_.Severity; status = $_.Status
                    fact = $_.Fact; actual = $_.Actual; op = $_.Op; value = $_.Value; expected = $_.Expected; weight = $_.Weight
                    title = $_.Title; risk = $_.Risk; fix = $_.Fix; command = $_.Command; reference = $_.Reference
                }
            })
        changes     = $Changes
        errors      = @($Errors)
        facts       = $Facts
    }
}

function Save-HSRecord {
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)] [string] $Path)
    $json = $Record | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
}

function ConvertTo-HSHtml {
    <#
    .SYNOPSIS
        Returns the HTML report with the record embedded as JSON.
    #>
    param([Parameter(Mandatory)] $Record, [string] $TemplatePath = (Join-Path -Path $PSScriptRoot -ChildPath 'report-template.html'))
    $template = [IO.File]::ReadAllText($TemplatePath, [Text.Encoding]::UTF8)
    # '</' would close the <script> element early if a value contained '</script>'
    $json = ($Record | ConvertTo-Json -Depth 8 -Compress) -replace '</', '<\/'
    $marker = '/*__DATA__*/null'
    if ($template.IndexOf($marker) -lt 0) { throw "The report template has no data marker" }
    return $template.Replace($marker, $json)
}

function Save-HSHtmlReport {
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)] [string] $Path)
    $html = ConvertTo-HSHtml -Record $Record
    [IO.File]::WriteAllText($Path, $html, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
}
