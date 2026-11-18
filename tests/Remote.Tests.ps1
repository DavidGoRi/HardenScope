#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Fictitious computer names')]
param()

BeforeDiscovery {
    # Real remoting needs WinRM listening on this computer (GitHub's Windows runners have it)
    $winRmAvailable = $false
    try { Test-WSMan -ComputerName localhost -ErrorAction Stop | Out-Null; $winRmAvailable = $true } catch { $winRmAvailable = $false }
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')

    function ConvertTo-RemoteResponse([string] $Name, [string] $Json) {
        # Invoke-Command tags every result with the computer it came from
        return Add-Member -InputObject $Json -NotePropertyName PSComputerName -NotePropertyValue $Name -PassThru
    }
    function New-RemoteError([string] $Name, [string] $Message) {
        $exception = New-Object -TypeName System.Exception -ArgumentList $Message
        return New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList $exception, 'WinRM', 'OpenError', $Name
    }
}

Describe 'Get-HSComputerList' {
    It 'skips blank lines, comments and duplicates' {
        $path = Join-Path $TestDrive 'computers.txt'
        [IO.File]::WriteAllLines($path, [string[]] @('# office', 'PC01', '', 'PC02  # reception', 'PC01'))
        Get-HSComputerList -Path $path | Should -Be @('PC01', 'PC02')
    }

    It 'fails when the file does not exist' {
        { Get-HSComputerList -Path (Join-Path $TestDrive 'missing.txt') } | Should -Throw
    }
}

Describe 'Invoke-HSRemoteCollection' {
    It 'returns the facts of every computer that answered, in the order requested' {
        Mock Invoke-HSRemoteCommand {
            [pscustomobject] @{
                Output = @(
                    (ConvertTo-RemoteResponse 'PC02' '{"computerName":"PC02","facts":{"os.build":26100},"errors":[]}'),
                    (ConvertTo-RemoteResponse 'PC01' '{"computerName":"PC01","facts":{"os.build":19045},"errors":["Get-HSBitLockerFact: denied"]}'))
                Errors = @()
            }
        }
        $results = @(Invoke-HSRemoteCollection -ComputerName 'PC01', 'PC02')
        $results.ComputerName | Should -Be @('PC01', 'PC02')
        $results[0].Status | Should -Be 'OK'
        $results[0].Facts.'os.build' | Should -Be 19045
        $results[0].Errors | Should -Be @('Get-HSBitLockerFact: denied')
    }

    It 'sends the collector source and the credential' {
        Mock Invoke-HSRemoteCommand { [pscustomobject] @{ Output = @(); Errors = @() } }
        $credential = New-Object -TypeName pscredential -ArgumentList 'CORP\it.admin', (New-Object -TypeName securestring)
        Invoke-HSRemoteCollection -ComputerName 'PC01' -Credential $credential -ThrottleLimit 8 | Out-Null
        Should -Invoke Invoke-HSRemoteCommand -Times 1 -ParameterFilter {
            $Parameters.ArgumentList -match 'function Get-HSFact' -and $Parameters.Credential.UserName -eq 'CORP\it.admin' -and $Parameters.ThrottleLimit -eq 8
        }
    }

    It 'reports the computers that could not be reached' {
        Mock Invoke-HSRemoteCommand {
            [pscustomobject] @{
                Output = @(ConvertTo-RemoteResponse 'PC01' '{"computerName":"PC01","facts":{"a":true},"errors":[]}')
                Errors = @(New-RemoteError 'PC02' "WinRM cannot complete the operation.`r`nMore details")
            }
        }
        $results = @(Invoke-HSRemoteCollection -ComputerName 'PC01', 'PC02', 'PC03')
        $results[1].Status | Should -Be 'Failed'
        $results[1].Message | Should -Be 'WinRM cannot complete the operation.'
        $results[2].Message | Should -Be 'No response'
    }

    It 'rejects a response without facts' {
        Mock Invoke-HSRemoteCommand { [pscustomobject] @{ Output = @(ConvertTo-RemoteResponse 'PC01' 'not json'); Errors = @() } }
        $result = Invoke-HSRemoteCollection -ComputerName 'PC01'
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'Invalid response'
    }
}

Describe 'HardenScope.ps1 -ComputerName' {
    It 'audits localhost locally, without WinRM' {
        $run = & $entryPoint -ComputerName 'localhost' -OutputPath (Join-Path $TestDrive 'local') -Quiet -PassThru
        $run.Computers | Should -HaveCount 1
        $run.Record.device.name | Should -Be $env:COMPUTERNAME
        Test-Path $run.FleetPath | Should -BeTrue
    }
}

Describe 'Real remoting against this computer' -Tag 'Remoting' -Skip:(-not $winRmAvailable) {
    It 'collects every fact the baseline uses over WinRM' {
        $result = Invoke-HSRemoteCollection -ComputerName 'localhost'
        $result.Status | Should -Be 'OK' -Because $result.Message
        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $baseline = Import-HSBaseline -Path $baselinePath
        foreach ($rule in $baseline.rules) {
            $result.Facts.PSObject.Properties.Name | Should -Contain $rule.fact
        }
    }
}
