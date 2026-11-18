#Requires -Version 5.1
# The rest of the toolkit:
# - PCScope (inventory): its inventory says which computers exist, so
#   HardenScope can audit exactly those.
# - DeskScope (service desk): receives the fleet report and opens one ticket
#   per computer and failed check, resolving it by itself once it is fixed.

function Get-HSPCScopeComputer {
    <#
    .SYNOPSIS
        Computer names from a PCScope inventory: its data folder (one
        <DEVICE>.json per computer), that folder's devices.csv export, or a
        single devices.csv file.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $Path)

    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) { throw "PCScope inventory not found: $Path" }

    $names = New-Object -TypeName System.Collections.Generic.List[string]
    $csvFiles = @()
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) { $csvFiles = @($fullPath) }
    else {
        # Inventories: <data>\<DEVICE>.json (history snapshots live in subfolders and are ignored)
        foreach ($file in Get-ChildItem -LiteralPath $fullPath -Filter '*.json' -File) {
            try { $inventory = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
            catch { continue }
            if ($inventory.computerName -and $inventory.schemaVersion) { $names.Add([string] $inventory.computerName) }
        }
        $csvFiles = @(Get-ChildItem -LiteralPath $fullPath -Filter 'devices.csv' -File | ForEach-Object { $_.FullName })
    }
    foreach ($csv in $csvFiles) {
        # PowerShell writes ',' or ';' depending on the culture
        $firstLine = (Get-Content -LiteralPath $csv -TotalCount 1 -Encoding UTF8)
        $delimiter = if (($firstLine -split ';').Count -gt ($firstLine -split ',').Count) { ';' } else { ',' }
        foreach ($row in Import-Csv -LiteralPath $csv -Delimiter $delimiter -Encoding UTF8) {
            if ($row.Device) { $names.Add([string] $row.Device) }
        }
    }
    $unique = @($names | Where-Object { $_ } | Sort-Object -Unique)
    if ($unique.Count -eq 0) { throw "No computers found in the PCScope inventory: $Path" }
    return $unique
}

function Invoke-HSDeskScopeRequest {
    # Wrapper so the tests can replace the HTTP call
    param([hashtable] $Parameters)
    Invoke-RestMethod @Parameters
}

function Send-HSDeskScope {
    <#
    .SYNOPSIS
        Sends a fleet report to DeskScope's /api/v1/import/hardenscope.
        The token comes from the DESKSCOPE_TOKEN environment variable and is
        never written to disk or to the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Fleet,
        [Parameter(Mandatory)] [string] $Url,
        [string[]] $Severity = @('critical'),
        [ValidateSet('en', 'es')] [string] $Language = 'en',
        [string] $Token = $env:DESKSCOPE_TOKEN
    )
    if (-not $Token) { throw 'Set the DESKSCOPE_TOKEN environment variable to a DeskScope API token (deskscope token create <user>).' }
    $uri = $Url.TrimEnd('/')
    if ($uri -notmatch '^https?://') { throw "DeskScope URL must start with http:// or https://: $Url" }
    $query = 'lang={0}&severities={1}' -f $Language, [uri]::EscapeDataString((@($Severity) -join ','))
    # Only what DeskScope needs: no facts, no file paths
    $payload = [ordered] @{
        tool = 'HardenScope'; kind = 'fleet'; version = $Fleet.version; generatedAt = $Fleet.generatedAt
        computers = @($Fleet.computers | ForEach-Object { [ordered] @{ name = $_.name; os = $_.os; score = $_.score; grade = $_.grade } })
        failing = @($Fleet.failing)
    }
    $body = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))
    $parameters = @{
        Uri         = "$uri/api/v1/import/hardenscope?$query"
        Method      = 'Post'
        Headers     = @{ Authorization = "Bearer $Token" }
        ContentType = 'application/json; charset=utf-8'
        Body        = $body
        ErrorAction = 'Stop'
    }
    return Invoke-HSDeskScopeRequest -Parameters $parameters
}
