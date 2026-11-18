#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
}

Describe 'ConvertFrom-HSNetAccount' {
    It 'reads the English output' {
        $lines = @(
            'Force user logoff how long after time expires?:       Never'
            'Minimum password age (days):                          1'
            'Maximum password age (days):                          42'
            'Minimum password length:                              14'
            'Length of password history maintained:                24'
            'Lockout threshold:                                    5'
            'Lockout duration (minutes):                           15'
            'Lockout observation window (minutes):                 15'
            'Computer role:                                        WORKSTATION'
            'The command completed successfully.'
        )
        $policy = ConvertFrom-HSNetAccount -Lines $lines
        $policy['policy.minPasswordLength'] | Should -Be 14
        $policy['policy.lockoutThreshold'] | Should -Be 5
    }

    It 'reads the Spanish output and treats words as 0' {
        $lines = @(
            'Tiempo antes del cierre forzado:                  Nunca'
            'Duración mín. de contraseña (días):               0'
            'Duración máx. de contraseña (días):               Ilimitado'
            'Longitud mínima de contraseña:                    0'
            'Duración del historial de contraseñas:            Ninguna'
            'Umbral de bloqueo:                                Nunca'
            'Duración de bloqueo (minutos):                    30'
            'Ventana de obs. de bloqueo (minutos):             30'
            'Rol del servidor:                                 ESTACION DE TRABAJO'
            'Se ha completado el comando correctamente.'
        )
        $policy = ConvertFrom-HSNetAccount -Lines $lines
        $policy['policy.minPasswordLength'] | Should -Be 0
        $policy['policy.lockoutThreshold'] | Should -Be 0
    }

    It 'returns unknown values when the output is incomplete' {
        $policy = ConvertFrom-HSNetAccount -Lines @('System error 5 has occurred.')
        $policy['policy.minPasswordLength'] | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-HSProductState' {
    It 'decodes <State>' -TestCases @(
        @{ State = 0x061100; Enabled = $true; UpToDate = $true }
        @{ State = 0x041000; Enabled = $true; UpToDate = $true }
        @{ State = 0x060100; Enabled = $false; UpToDate = $true }
        @{ State = 0x061110; Enabled = $true; UpToDate = $false }
    ) {
        $decoded = ConvertFrom-HSProductState -State $State
        $decoded.Enabled | Should -Be $Enabled
        $decoded.UpToDate | Should -Be $UpToDate
    }
}

Describe 'Collectors with defaults' {
    It 'treats missing credential settings as the Windows defaults' {
        Mock Get-HSRegistryValue { $Default }
        $facts = Get-HSCredentialFact
        $facts['winlogon.autoLogon'] | Should -BeFalse
        $facts['wdigest.cleartext'] | Should -BeFalse
        $facts['lsa.protected'] | Should -BeFalse
        $facts['ntlm.level'] | Should -Be 3
        $facts['lsa.restrictAnonymousSam'] | Should -BeTrue
    }

    It 'detects automatic logon and WDigest' {
        Mock Get-HSRegistryValue { '1' } -ParameterFilter { $Name -eq 'AutoAdminLogon' }
        Mock Get-HSRegistryValue { 1 } -ParameterFilter { $Name -eq 'UseLogonCredential' }
        Mock Get-HSRegistryValue { $Default } -ParameterFilter { $Name -notin 'AutoAdminLogon', 'UseLogonCredential' }
        $facts = Get-HSCredentialFact
        $facts['winlogon.autoLogon'] | Should -BeTrue
        $facts['wdigest.cleartext'] | Should -BeTrue
    }

    It 'reads the firewall profiles' {
        Mock Get-NetFirewallProfile {
            @([pscustomobject] @{ Name = 'Domain'; Enabled = 'True'; DefaultInboundAction = 'NotConfigured' }
                [pscustomobject] @{ Name = 'Private'; Enabled = 'True'; DefaultInboundAction = 'Block' }
                [pscustomobject] @{ Name = 'Public'; Enabled = 'False'; DefaultInboundAction = 'Allow' })
        }
        Mock Get-SmbClientConfiguration { [pscustomobject] @{ RequireSecuritySignature = $true } }
        Mock Get-Service { [pscustomobject] @{ StartType = 'Manual' } }
        Mock Get-HSRegistryValue { $Default }
        $facts = Get-HSNetworkFact
        $facts['firewall.domain'] | Should -BeTrue
        $facts['firewall.public'] | Should -BeFalse
        $facts['firewall.inboundBlocked'] | Should -BeFalse
        $facts['smb.signingRequired'] | Should -BeTrue
        $facts['smb.v1Enabled'] | Should -BeFalse
        $facts['llmnr.disabled'] | Should -BeFalse
        $facts['rdp.enabled'] | Should -BeFalse
        $facts['services.remoteRegistry'] | Should -Be 'Manual'
    }

    It 'flags SMBv1 when its client driver is enabled' {
        Mock Get-NetFirewallProfile { @() }
        Mock Get-SmbClientConfiguration { throw 'not available' }
        Mock Get-Service { $null }
        Mock Get-HSRegistryValue { 3 } -ParameterFilter { $Name -eq 'Start' }
        Mock Get-HSRegistryValue { $Default } -ParameterFilter { $Name -ne 'Start' }
        $facts = Get-HSNetworkFact
        $facts['smb.v1Enabled'] | Should -BeTrue
        $facts['smb.signingRequired'] | Should -BeFalse
        $facts['services.remoteRegistry'] | Should -Be 'Disabled'
    }

    It 'prefers Defender data when Defender is the active antivirus' {
        Mock Get-CimInstance { @() } -ParameterFilter { $ClassName -eq 'AntiVirusProduct' }
        Mock Get-MpComputerStatus { [pscustomobject] @{ RealTimeProtectionEnabled = $true; AMRunningMode = 'Normal'; IsTamperProtected = $true; AntivirusSignatureAge = 12 } }
        Mock Get-HSRegistryValue { $Default }
        Mock Test-HSRegistryKey { $false }
        $facts = Get-HSDefenseFact
        $facts['antivirus.active'] | Should -BeTrue
        $facts['antivirus.upToDate'] | Should -BeFalse
        $facts['defender.active'] | Should -BeTrue
        $facts['uac.enabled'] | Should -BeTrue
    }

    It 'uses Security Center when Defender is passive' {
        Mock Get-CimInstance { @([pscustomobject] @{ productState = 0x041000 }) } -ParameterFilter { $ClassName -eq 'AntiVirusProduct' }
        Mock Get-MpComputerStatus { [pscustomobject] @{ RealTimeProtectionEnabled = $false; AMRunningMode = 'Passive Mode'; IsTamperProtected = $true; AntivirusSignatureAge = 0 } }
        Mock Get-HSRegistryValue { $Default }
        Mock Test-HSRegistryKey { $false }
        $facts = Get-HSDefenseFact
        $facts['antivirus.active'] | Should -BeTrue
        $facts['antivirus.upToDate'] | Should -BeTrue
        $facts['defender.active'] | Should -BeFalse
    }
}

Describe 'Get-HSFact on this computer' -Tag 'Live' {
    It 'produces every fact the baseline uses' {
        $collected = Get-HSFact
        $baseline = Import-HSBaseline -Path $baselinePath
        $needed = @($baseline.rules | ForEach-Object { $_.fact; if ($_.when) { $_.when.fact } }) | Sort-Object -Unique
        $missing = @($needed | Where-Object { -not $collected.Facts.Contains($_) })
        $missing | Should -BeNullOrEmpty -Because ($collected.Errors -join '; ')
    }
}

Describe 'Get-HSFact' {
    It 'keeps going when a collector fails and reports the error' {
        Mock Get-HSSystemFact { @{ 'os.build' = 26100 } }
        Mock Get-HSBitLockerFact { throw 'COM error' }
        Mock Get-HSDefenseFact { @{} }
        Mock Get-HSNetworkFact { @{} }
        Mock Get-HSAccountFact { @{} }
        Mock Get-HSCredentialFact { @{} }
        $collected = Get-HSFact
        $collected.Facts['os.build'] | Should -Be 26100
        $collected.Errors | Should -HaveCount 1
        $collected.Errors[0] | Should -Match 'Get-HSBitLockerFact: COM error'
    }

    It 'only uses read-only commands' {
        $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\Facts.ps1'))
        foreach ($verb in 'Set-', 'New-Item', 'Remove-', 'Enable-', 'Disable-', 'Stop-', 'Start-', 'Restart-') {
            $source | Should -Not -Match ([regex]::Escape($verb) + '[A-Za-z]') -Because "$verb would change the computer"
        }
    }
}
