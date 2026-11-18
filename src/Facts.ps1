#Requires -Version 5.1
# Fact collection. Every function here only READS the computer: HardenScope never
# changes a setting. Each collector returns a hashtable of flat fact names
# (e.g. 'firewall.public') to plain values; a fact that cannot be read is $null
# and the rules that use it end up as Unknown instead of failing.

function Get-HSRegistryValue {
    # Reads one registry value, or returns $Default when the key or value is missing
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $Default }
    return $item.$Name
}

function Test-HSRegistryKey {
    param([Parameter(Mandatory)] [string] $Path)
    return [bool] (Test-Path -Path $Path)
}

function Invoke-HSNetAccount {
    # Wrapper so the tests can replace the output of 'net accounts'
    return @(& net.exe accounts 2>$null)
}

function ConvertFrom-HSNetAccount {
    # 'net accounts' is translated into the Windows language, so the values are
    # read by position: 4th line = minimum length, 6th line = lockout threshold.
    # Words such as Never / Nunca / None mean 0.
    param([string[]] $Lines)
    $values = @($Lines | Where-Object { $_ -match ':\s*\S' } | ForEach-Object {
            $text = ($_ -split ':')[-1].Trim()
            if ($text -match '^\d+$') { [int] $text } else { 0 }
        })
    if ($values.Count -lt 6) { return @{ 'policy.minPasswordLength' = $null; 'policy.lockoutThreshold' = $null } }
    return @{ 'policy.minPasswordLength' = $values[3]; 'policy.lockoutThreshold' = $values[5] }
}

function ConvertFrom-HSProductState {
    # Windows Security Center productState: byte 2 = 0x10/0x11 when real-time
    # protection is on, byte 1 = 0x00 when the signatures are up to date
    param([Parameter(Mandatory)] [int] $State)
    $engine = ($State -shr 8) -band 0xFF
    $signatures = $State -band 0xFF
    return [pscustomobject] @{
        Enabled  = ($engine -eq 0x10 -or $engine -eq 0x11)
        UpToDate = ($signatures -eq 0x00)
    }
}

function Get-HSSystemFact {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $build = [int] $os.BuildNumber
    $hotfixDates = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | ForEach-Object { [datetime] $_.InstalledOn })
    $days = $null
    if ($hotfixDates.Count -gt 0) {
        $latest = ($hotfixDates | Sort-Object -Descending)[0]
        $days = [int] [Math]::Floor(((Get-Date) - $latest).TotalDays)
    }
    $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $secureBoot = Get-HSRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled'
    return @{
        'os.caption'                  = [string] $os.Caption
        'os.build'                    = $build
        'os.ltsc'                     = ([string] $os.Caption -match 'LTSC|LTSB')
        'updates.daysSinceLastUpdate' = $days
        'reboot.pending'              = ((Test-HSRegistryKey -Path $cbs) -or (Test-HSRegistryKey -Path $wu))
        'secureboot.enabled'          = $(if ($null -eq $secureBoot) { $null } else { [int] $secureBoot -eq 1 })
    }
}

function Get-HSBitLockerFact {
    # The shell property works without administrator rights (Get-BitLockerVolume
    # does not). 1 = on, 3 = encrypting, 6 = on and locked; 2/5 = off/suspended.
    $drive = "$env:SystemDrive\"
    $shell = New-Object -ComObject Shell.Application
    $value = $shell.NameSpace($drive).Self.ExtendedProperty('System.Volume.BitLockerProtection')
    if ($null -eq $value) { return @{ 'bitlocker.systemDrive' = $null } }
    return @{ 'bitlocker.systemDrive' = (@(1, 3, 6) -contains [int] $value) }
}

function Get-HSDefenseFact {
    $facts = @{
        'antivirus.active'         = $null
        'antivirus.upToDate'       = $null
        'defender.active'          = $null
        'defender.tamperProtected' = $null
    }
    $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
    if ($products.Count -gt 0) {
        $states = @($products | ForEach-Object { ConvertFrom-HSProductState -State ([int] $_.productState) })
        $active = @($states | Where-Object { $_.Enabled })
        $facts['antivirus.active'] = ($active.Count -gt 0)
        if ($active.Count -gt 0) { $facts['antivirus.upToDate'] = (@($active | Where-Object { $_.UpToDate }).Count -gt 0) }
    }
    $mp = $null
    try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { $mp = $null }
    if ($null -ne $mp) {
        $defenderOn = ([bool] $mp.RealTimeProtectionEnabled -and [string] $mp.AMRunningMode -notmatch 'Passive')
        $facts['defender.active'] = $defenderOn
        $facts['defender.tamperProtected'] = [bool] $mp.IsTamperProtected
        if ($defenderOn) {
            $facts['antivirus.active'] = $true
            $facts['antivirus.upToDate'] = ([int] $mp.AntivirusSignatureAge -le 7)
        }
    }
    $policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $explorer = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $facts['uac.enabled'] = ([int] (Get-HSRegistryValue -Path $policy -Name 'EnableLUA' -Default 1) -eq 1)
    $facts['uac.consentPromptBehaviorAdmin'] = [int] (Get-HSRegistryValue -Path $policy -Name 'ConsentPromptBehaviorAdmin' -Default 5)
    $facts['autorun.disabledAllDrives'] = ([int] (Get-HSRegistryValue -Path $explorer -Name 'NoDriveTypeAutoRun' -Default 0) -eq 255)
    $facts['powershell.v2Present'] = (Test-HSRegistryKey -Path 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\PowerShellEngine')
    return $facts
}

function Get-HSNetworkFact {
    $facts = @{}
    $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    foreach ($name in 'Domain', 'Private', 'Public') {
        $fwProfile = $profiles | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        $facts["firewall.$($name.ToLowerInvariant())"] = $(if ($fwProfile) { [string] $fwProfile.Enabled -eq 'True' } else { $null })
    }
    # NotConfigured means the Windows default, which is Block
    $facts['firewall.inboundBlocked'] = (@($profiles | Where-Object { [string] $_.DefaultInboundAction -eq 'Allow' }).Count -eq 0)

    $smb1Client = Get-HSRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' -Name 'Start'
    $smb1Server = Get-HSRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'SMB1'
    $facts['smb.v1Enabled'] = ((($null -ne $smb1Client) -and ([int] $smb1Client -ne 4)) -or ([int] $smb1Server -eq 1))
    # The effective setting: Windows 11 24H2 requires signing by default without
    # writing it to the registry, so the registry is only the fallback
    $smbClient = $null
    try { $smbClient = Get-SmbClientConfiguration -ErrorAction Stop } catch { $smbClient = $null }
    if ($null -ne $smbClient) { $facts['smb.signingRequired'] = [bool] $smbClient.RequireSecuritySignature }
    else {
        $signing = Get-HSRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' -Name 'RequireSecuritySignature'
        $facts['smb.signingRequired'] = ([int] $signing -eq 1)
    }

    $multicast = Get-HSRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast'
    $facts['llmnr.disabled'] = (($null -ne $multicast) -and ([int] $multicast -eq 0))

    $deny = Get-HSRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Default 1
    $facts['rdp.enabled'] = ([int] $deny -eq 0)
    $nla = Get-HSRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Default 1
    $facts['rdp.nla'] = ([int] $nla -eq 1)

    $service = Get-Service -Name 'RemoteRegistry' -ErrorAction SilentlyContinue
    $facts['services.remoteRegistry'] = $(if ($service) { [string] $service.StartType } else { 'Disabled' })
    return $facts
}

function Get-HSAccountFact {
    $users = @(Get-LocalUser -ErrorAction Stop)
    $guest = $users | Where-Object { $_.SID.Value -like '*-501' } | Select-Object -First 1
    $admin = $users | Where-Object { $_.SID.Value -like '*-500' } | Select-Object -First 1
    $facts = @{
        'accounts.guestEnabled'        = $(if ($guest) { [bool] $guest.Enabled } else { $false })
        'accounts.builtinAdminEnabled' = $(if ($admin) { [bool] $admin.Enabled } else { $false })
        'accounts.localAdminCount'     = $null
    }
    try { $facts['accounts.localAdminCount'] = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop).Count }
    catch { $facts['accounts.localAdminCount'] = $null }
    $policy = ConvertFrom-HSNetAccount -Lines (Invoke-HSNetAccount)
    foreach ($key in $policy.Keys) { $facts[$key] = $policy[$key] }
    # Not configured counts as 0, which fails the rule: Windows does not lock by itself
    $facts['screen.lockTimeoutSecs'] = [int] (Get-HSRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'InactivityTimeoutSecs' -Default 0)
    return $facts
}

function Get-HSCredentialFact {
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $autoLogon = [string] (Get-HSRegistryValue -Path $winlogon -Name 'AutoAdminLogon' -Default '0')
    $ppl = [int] (Get-HSRegistryValue -Path $lsa -Name 'RunAsPPL' -Default 0)
    return @{
        'winlogon.autoLogon'       = ($autoLogon.Trim() -eq '1')
        'wdigest.cleartext'        = ([int] (Get-HSRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name 'UseLogonCredential' -Default 0) -eq 1)
        'lsa.protected'            = ($ppl -eq 1 -or $ppl -eq 2)
        # Not configured behaves as level 3 on current Windows
        'ntlm.level'               = [int] (Get-HSRegistryValue -Path $lsa -Name 'LmCompatibilityLevel' -Default 3)
        'lsa.restrictAnonymousSam' = ([int] (Get-HSRegistryValue -Path $lsa -Name 'RestrictAnonymousSAM' -Default 1) -eq 1)
    }
}

function Get-HSFact {
    <#
    .SYNOPSIS
        Collects every fact of the local computer. Returns @{ Facts; Errors }.
    #>
    $facts = [ordered] @{}
    $errors = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($collector in 'Get-HSSystemFact', 'Get-HSBitLockerFact', 'Get-HSDefenseFact', 'Get-HSNetworkFact',
        'Get-HSAccountFact', 'Get-HSCredentialFact') {
        try {
            $part = & $collector
            foreach ($key in ($part.Keys | Sort-Object)) { $facts[$key] = $part[$key] }
        }
        catch {
            $errors.Add("${collector}: $($_.Exception.Message)")
        }
    }
    return [pscustomobject] @{ Facts = $facts; Errors = $errors.ToArray() }
}
