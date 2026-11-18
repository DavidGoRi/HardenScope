#Requires -Version 5.1
<#
.SYNOPSIS
    Audits other computers over PowerShell remoting (WinRM).

.DESCRIPTION
    Nothing is installed on the targets: the source of src\Facts.ps1 travels
    with the request, runs there (read-only, as everywhere else) and only the
    facts come back as JSON. Invoke-Command contacts the computers in parallel.

    Requirements on the targets: PowerShell remoting enabled (Enable-PSRemoting
    or a Group Policy) and an account allowed to connect (local Administrators
    or Remote Management Users).
#>

# Runs on the remote computer. A JSON string travels better than a
# deserialized object: the types of the values arrive unchanged.
$script:HSRemoteScript = {
    param([Parameter(Mandatory)] [string] $CollectorSource)

    . ([scriptblock]::Create($CollectorSource))
    $collected = Get-HSFact
    [ordered] @{ computerName = $env:COMPUTERNAME; facts = $collected.Facts; errors = @($collected.Errors) } | ConvertTo-Json -Depth 4 -Compress
}

function Get-HSComputerList {
    <#
    .SYNOPSIS
        Reads computer names from a text file: one per line; blank lines and
        anything after # are ignored.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $Path)

    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Computer list not found: $Path" }
    $names = foreach ($line in [IO.File]::ReadAllLines($fullPath)) {
        $name = ($line -replace '#.*$', '').Trim()
        if ($name) { $name }
    }
    return @($names | Select-Object -Unique)
}

function Invoke-HSRemoteCommand {
    # Wrapper so the tests can replace the real remoting call. Returns the
    # responses and the errors (one per computer that could not be reached).
    param([hashtable] $Parameters)
    $problems = $null
    $output = @(Invoke-Command @Parameters -ErrorAction SilentlyContinue -ErrorVariable problems)
    [pscustomobject] @{ Output = $output; Errors = @($problems) }
}

function Invoke-HSRemoteCollection {
    <#
    .SYNOPSIS
        Collects the facts of several computers. Returns one object per
        requested computer, in the order requested:
        ComputerName, Status (OK / Failed), Facts, Errors, Message.

    .EXAMPLE
        Invoke-HSRemoteCollection -ComputerName PC01, PC02 -Credential (Get-Credential CORP\it.admin)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ComputerName,
        [pscredential] $Credential,
        [ValidateRange(1, 256)] [int] $ThrottleLimit = 32
    )

    $collectorSource = [IO.File]::ReadAllText((Join-Path -Path $PSScriptRoot -ChildPath 'Facts.ps1'), [Text.Encoding]::UTF8)
    $parameters = @{
        ComputerName  = $ComputerName
        ScriptBlock   = $script:HSRemoteScript
        ArgumentList  = $collectorSource
        ThrottleLimit = $ThrottleLimit
    }
    if ($Credential) { $parameters.Credential = $Credential }
    $call = Invoke-HSRemoteCommand -Parameters $parameters
    $responses = @($call.Output)
    $remoteErrors = @($call.Errors)

    $results = @{}
    foreach ($response in $responses) {
        $target = [string] $response.PSComputerName
        try {
            $data = [string] $response | ConvertFrom-Json -ErrorAction Stop
            if (-not $data.facts) { throw 'no facts in the response' }
            $results[$target] = New-HSCollectionResult -ComputerName ([string] $data.computerName) -Status 'OK' -Facts $data.facts -Errors @($data.errors)
        }
        catch {
            $results[$target] = New-HSCollectionResult -ComputerName $target -Status 'Failed' -Message "Invalid response: $($_.Exception.Message)"
        }
    }
    foreach ($problem in $remoteErrors) {
        $target = if ($problem.OriginInfo) { [string] $problem.OriginInfo.PSComputerName }
        elseif ($problem.TargetObject) { [string] $problem.TargetObject }
        else { '' }
        if (-not $target -or $results.ContainsKey($target)) { continue }
        if (@($ComputerName | Where-Object { $_ -eq $target }).Count -eq 0) { continue }
        $results[$target] = New-HSCollectionResult -ComputerName $target -Status 'Failed' -Message (([string] $problem.Exception.Message -split "`r?`n")[0])
    }
    foreach ($name in $ComputerName) {
        $match = $results.Keys | Where-Object { $_ -eq $name } | Select-Object -First 1
        if ($match) { $results[$match] }
        else { New-HSCollectionResult -ComputerName $name -Status 'Failed' -Message 'No response' }
    }
}

function New-HSCollectionResult {
    param([string] $ComputerName, [string] $Status, $Facts = $null, [string[]] $Errors = @(), [string] $Message = '')
    [pscustomobject] @{ ComputerName = $ComputerName; Status = $Status; Facts = $Facts; Errors = $Errors; Message = $Message }
}
