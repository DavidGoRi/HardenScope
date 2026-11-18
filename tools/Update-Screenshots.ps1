#Requires -Version 5.1
<#
.SYNOPSIS
    Regenerates the pictures of the README from the live demo.

.DESCRIPTION
    Builds the demo (tools/Build-Demo.ps1, fictitious data only) in a
    temporary folder and writes to docs/:
      report.png, fleet.png          English, light theme
      es/report.png, es/fleet.png    Spanish, dark theme
      social-preview.png             from tools/demo/social.html (1280x640,
                                     for the repository settings on GitHub)

    Needs Microsoft Edge (headless screenshots); it is a maintenance script,
    not part of HardenScope.

.EXAMPLE
    .\tools\Update-Screenshots.ps1
#>
[CmdletBinding()]
param([string] $EdgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$docs = Join-Path $root 'docs'
if (-not (Test-Path -LiteralPath $EdgePath)) { throw "Microsoft Edge not found: $EdgePath" }
$work = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('hardenscope-shots-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$site = Join-Path $work 'site'
[void] (& (Join-Path $PSScriptRoot 'Build-Demo.ps1') -OutputPath $site)
[void] [IO.Directory]::CreateDirectory((Join-Path $docs 'es'))

function Save-Screenshot([string] $Page, [string] $Png, [int] $Width, [int] $Height) {
    # A fresh profile each time: Edge keeps the old one locked for a while
    $userData = Join-Path $work ('edge-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    if (Test-Path -LiteralPath $Png) { Remove-Item -LiteralPath $Png -Force }
    $arguments = @('--headless=new', '--disable-gpu', '--hide-scrollbars', "--user-data-dir=$userData",
        "--window-size=$Width,$Height", "--screenshot=$Png", "`"$Page`"")
    Start-Process -FilePath $EdgePath -ArgumentList $arguments -Wait -WindowStyle Hidden
    if (-not (Test-Path -LiteralPath $Png)) { throw "No screenshot of $Page" }
}
function ConvertTo-FileUri([string] $Path) { return ([Uri] $Path).AbsoluteUri }

$report = ConvertTo-FileUri (Join-Path $site 'reports\WS-SALES-07.html')
$fleet = ConvertTo-FileUri (Join-Path $site 'reports\fleet.html')
Save-Screenshot "$report`?lang=en&theme=light" (Join-Path $docs 'report.png') 1200 1300
Save-Screenshot "$report`?lang=es&theme=dark" (Join-Path $docs 'es\report.png') 1200 1300
Save-Screenshot "$fleet`?lang=en&theme=light" (Join-Path $docs 'fleet.png') 1200 1250
Save-Screenshot "$fleet`?lang=es&theme=dark" (Join-Path $docs 'es\fleet.png') 1200 1250
Save-Screenshot (ConvertTo-FileUri (Join-Path $PSScriptRoot 'demo\social.html')) (Join-Path $docs 'social-preview.png') 1280 640

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $docs -Recurse -Filter '*.png' | ForEach-Object { [pscustomobject] @{ File = $_.FullName.Substring($root.Length + 1); KB = [Math]::Round($_.Length / 1KB) } }
