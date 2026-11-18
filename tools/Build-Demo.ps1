#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the live demo: a static site with real HardenScope reports of the
    12 fictitious demo computers.

.DESCRIPTION
    Runs HardenScope twice in a temporary folder, exactly as a scheduled task
    would: first on demo\previous (the same fleet, dated 30 days earlier) and
    then on demo\*.json (today), so the reports show the changes between both
    audits. Writes to -OutputPath:
      index.html            the guided tour, in English and Spanish
      reports/fleet.html    the fleet report
      reports/<NAME>.html   the report of every computer (linked from the fleet)
      data/fleet.json       the fleet record, as DeskScope receives it

    The build fails if the name of this computer or its user appears in any
    page. The Demo workflow publishes the site to GitHub Pages;
    tools/Update-Screenshots.ps1 takes the README pictures from it.

.EXAMPLE
    .\tools\Build-Demo.ps1 -OutputPath .\_site
#>
[CmdletBinding()]
param([string] $OutputPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) '_site'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$entryPoint = Join-Path $root 'HardenScope.ps1'
. (Join-Path $root 'src\Report.ps1')   # $script:HSVersion

$OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
$work = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('hardenscope-demo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$previousFacts = Join-Path $work 'previous'
$runs = Join-Path $work 'runs'
[void] [IO.Directory]::CreateDirectory($previousFacts)
$utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

# The previous audit is always "a month ago", whenever the site is rebuilt
$previousAt = ([datetimeoffset] (Get-Date)).AddDays(-30).ToString('yyyy-MM-ddT09:30:00zzz')
foreach ($file in Get-ChildItem -Path (Join-Path $root 'demo\previous') -Filter '*.json') {
    $data = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $data.generatedAt = $previousAt
    [IO.File]::WriteAllText((Join-Path $previousFacts $file.Name), ($data | ConvertTo-Json -Depth 5), $utf8)
}
& $entryPoint -FactsPath (Join-Path $previousFacts '*.json') -OutputPath $runs -Quiet | Out-Null
$today = & $entryPoint -FactsPath (Join-Path $root 'demo\*.json') -OutputPath $runs -Quiet -PassThru
$fleet = $today.Fleet

# Site: stable file names, so links from the README keep working
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force }
$reports = Join-Path $OutputPath 'reports'
foreach ($folder in $reports, (Join-Path $OutputPath 'data')) { [void] [IO.Directory]::CreateDirectory($folder) }
$renames = @{}
foreach ($computer in $today.Computers) {
    $name = $computer.Record.device.name
    $renames[[IO.Path]::GetFileName($computer.HtmlPath)] = "$name.html"
    Copy-Item -LiteralPath $computer.HtmlPath -Destination (Join-Path $reports "$name.html")
}
$fleetHtml = [IO.File]::ReadAllText($today.FleetPath, [Text.Encoding]::UTF8)
foreach ($old in $renames.Keys) { $fleetHtml = $fleetHtml.Replace("`"$old`"", "`"$($renames[$old])`"") }
[IO.File]::WriteAllText((Join-Path $reports 'fleet.html'), $fleetHtml, $utf8)
$fleetJson = [IO.File]::ReadAllText([IO.Path]::ChangeExtension($today.FleetPath, '.json'), [Text.Encoding]::UTF8)
foreach ($old in $renames.Keys) { $fleetJson = $fleetJson.Replace("`"$old`"", "`"$($renames[$old])`"") }
[IO.File]::WriteAllText((Join-Path $OutputPath 'data\fleet.json'), $fleetJson, $utf8)

# The console output of the fleet run, as HardenScope.ps1 prints it
function ConvertTo-DemoHtml([string] $Text) { return [Net.WebUtility]::HtmlEncode($Text) }
$gradeClass = @{ A = 'ok'; B = 'ok'; C = 'warn'; D = 'bad'; F = 'bad' }
$lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
$lines.Add('<span class="prompt">PS&gt;</span> ' + (ConvertTo-DemoHtml '.\HardenScope.ps1 -ComputerListPath .\computers.txt -Credential $cred'))
$lines.Add('')
$lines.Add('<span class="dim">' + (ConvertTo-DemoHtml ('  {0,-20} {1,5}  {2}  {3}' -f 'Computer', 'Score', ' ', 'Critical / high')) + '</span>')
foreach ($computer in $fleet.computers) {
    $text = '  {0,-20} {1,5}  {2}  {3} / {4}' -f $computer.name, $computer.score, $computer.grade, $computer.failedBySeverity.critical, $computer.failedBySeverity.high
    if ($computer.change) { $text += '    {0}{1}' -f $(if ($computer.change.scoreDelta -gt 0) { '+' } else { '' }), $computer.change.scoreDelta }
    $lines.Add(('<span class="{0}">{1}</span>' -f $gradeClass[[string] $computer.grade], (ConvertTo-DemoHtml $text)))
}
$lines.Add('')
$lines.Add((ConvertTo-DemoHtml "  Average score: $($fleet.summary.averageScore)"))
$lines.Add((ConvertTo-DemoHtml '  Most common failures:'))
foreach ($item in @($fleet.failing | Select-Object -First 4)) {
    $lines.Add(('  <span class="sev-{0}">{1}</span> {2}' -f $item.severity, (ConvertTo-DemoHtml ('{0,-9}' -f $item.severity.ToUpperInvariant())),
            (ConvertTo-DemoHtml ('{0,-11} {1}/{2}  {3}' -f $item.id, $item.failedCount, $fleet.summary.computers, $item.title.en))))
}

$baseline = [IO.File]::ReadAllText((Join-Path $root 'config\baseline.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$values = @{
    Version      = ConvertTo-DemoHtml $script:HSVersion
    Generated    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    Computers    = $fleet.summary.computers
    Average      = $fleet.summary.averageScore
    Checks       = @($baseline.rules).Count
    Regressions  = $fleet.summary.regressions
    Improved     = $fleet.summary.improved
    Console      = $lines -join "`n"
}
$page = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'demo\index.html'), [Text.Encoding]::UTF8)
foreach ($key in $values.Keys) { $page = $page.Replace("{{$key}}", [string] $values[$key]) }
if ($page -match '\{\{\w+\}\}') { throw "Unfilled placeholder in tools\demo\index.html: $($Matches[0])" }
[IO.File]::WriteAllText((Join-Path $OutputPath 'index.html'), $page, $utf8)

# Nothing about the computer that built the site may leak into it
$local = @($env:COMPUTERNAME, $env:USERNAME, $work) | Where-Object { $_ -and $_.Length -ge 4 }
foreach ($file in Get-ChildItem -LiteralPath $OutputPath -Recurse -File) {
    $content = [IO.File]::ReadAllText($file.FullName)
    foreach ($value in $local) {
        if ($content.IndexOf($value, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "$($file.Name) contains a local detail: $value" }
    }
}
Remove-Item -LiteralPath $work -Recurse -Force

Get-ChildItem -LiteralPath $OutputPath -Recurse -File | ForEach-Object {
    [pscustomobject] @{ Page = $_.FullName.Substring($OutputPath.Length + 1).Replace('\', '/'); KB = [Math]::Round($_.Length / 1KB, 1) }
}
