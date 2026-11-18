#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the release zip: HardenScope-<version>.zip plus its SHA-256 checksum.

.DESCRIPTION
    The zip contains what is needed to use HardenScope (the entry script,
    src, the baseline, the fictitious demo computers and the documentation),
    not the tests, the tools or the screenshots. The version is read from
    src\Report.ps1. Used by the Release workflow and can be run locally.

.EXAMPLE
    .\tools\Build-Release.ps1 -OutputPath .\dist
#>
[CmdletBinding()]
param([string] $OutputPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'dist'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent

$match = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'src\Report.ps1')), "HSVersion = '(\d+\.\d+\.\d+)'")
if (-not $match.Success) { throw 'Version not found in src\Report.ps1' }
$version = $match.Groups[1].Value

$OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
$staging = Join-Path $OutputPath "HardenScope-$version"
if (Test-Path -Path $staging) { Remove-Item -Path $staging -Recurse -Force }
foreach ($folder in 'src', 'config', 'demo\previous') {
    New-Item -ItemType Directory -Path (Join-Path $staging $folder) -Force | Out-Null
}
foreach ($file in 'HardenScope.ps1', 'LICENSE', 'README.md', 'README.es.md', 'CHANGELOG.md') {
    Copy-Item -Path (Join-Path $root $file) -Destination (Join-Path $staging $file)
}
foreach ($folder in 'src', 'config', 'demo', 'demo\previous') {
    Copy-Item -Path (Join-Path $root "$folder\*") -Destination (Join-Path $staging $folder) -Exclude 'previous'
}

$zip = Join-Path $OutputPath "HardenScope-$version.zip"
if (Test-Path -Path $zip) { Remove-Item -Path $zip -Force }
# Compress-Archive (and ZipFile.CreateFromDirectory, under the compatibility
# settings of powershell.exe) write "\" inside zip paths, which breaks other
# tools. Adding each entry with an explicit "/" name avoids it.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in Get-ChildItem -Path $staging -Recurse -File) {
        $entry = "HardenScope-$version/" + $item.FullName.Substring($staging.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $item.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally { $archive.Dispose() }
Remove-Item -Path $staging -Recurse -Force

$hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$hash  HardenScope-$version.zip`n", (New-Object Text.UTF8Encoding($false)))

[pscustomobject] @{ Version = $version; Zip = $zip; Sha256 = $hash }
