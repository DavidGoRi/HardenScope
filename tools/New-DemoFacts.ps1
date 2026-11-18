#Requires -Version 5.1
<#
.SYNOPSIS
    Writes the fictitious demo computers in demo\. No real data is used:
    every value comes from this script.
#>
[CmdletBinding()]
param([string] $OutputPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'demo'))

$ErrorActionPreference = 'Stop'

# A well hardened Windows 11 24H2 workstation: every rule passes
$hardened = [ordered] @{
    'os.caption' = 'Microsoft Windows 11 Enterprise'; 'os.build' = 26100; 'os.ltsc' = $false
    'updates.daysSinceLastUpdate' = 9; 'reboot.pending' = $false; 'secureboot.enabled' = $true; 'bitlocker.systemDrive' = $true
    'antivirus.active' = $true; 'antivirus.upToDate' = $true; 'defender.active' = $true; 'defender.tamperProtected' = $true
    'uac.enabled' = $true; 'uac.consentPromptBehaviorAdmin' = 2; 'autorun.disabledAllDrives' = $true; 'powershell.v2Present' = $false
    'firewall.domain' = $true; 'firewall.private' = $true; 'firewall.public' = $true; 'firewall.inboundBlocked' = $true
    'smb.v1Enabled' = $false; 'smb.signingRequired' = $true; 'llmnr.disabled' = $true
    'rdp.enabled' = $true; 'rdp.nla' = $true; 'services.remoteRegistry' = 'Disabled'
    'accounts.guestEnabled' = $false; 'accounts.builtinAdminEnabled' = $false; 'accounts.localAdminCount' = 2
    'policy.minPasswordLength' = 14; 'policy.lockoutThreshold' = 5; 'screen.lockTimeoutSecs' = 900
    'winlogon.autoLogon' = $false; 'wdigest.cleartext' = $false; 'lsa.protected' = $true; 'ntlm.level' = 5; 'lsa.restrictAnonymousSam' = $true
}

$devices = [ordered] @{
    'WS-FIN-014'  = @{ 'updates.daysSinceLastUpdate' = 12; 'screen.lockTimeoutSecs' = 1200 }
    'WS-SALES-07' = @{
        'os.caption' = 'Microsoft Windows 11 Pro'; 'updates.daysSinceLastUpdate' = 63; 'reboot.pending' = $true
        'bitlocker.systemDrive' = $false; 'smb.v1Enabled' = $true; 'llmnr.disabled' = $false; 'smb.signingRequired' = $false
        'accounts.localAdminCount' = 4; 'policy.minPasswordLength' = 8; 'policy.lockoutThreshold' = 0
        'lsa.protected' = $false; 'ntlm.level' = 3; 'autorun.disabledAllDrives' = $false; 'uac.consentPromptBehaviorAdmin' = 5
    }
    'LT-OPS-22'   = @{
        'os.caption' = 'Microsoft Windows 10 Pro'; 'os.build' = 19045; 'updates.daysSinceLastUpdate' = 214
        'secureboot.enabled' = $false; 'bitlocker.systemDrive' = $false; 'defender.active' = $true; 'antivirus.upToDate' = $false
        'defender.tamperProtected' = $false; 'firewall.public' = $false; 'firewall.inboundBlocked' = $false; 'smb.v1Enabled' = $true
        'smb.signingRequired' = $false; 'llmnr.disabled' = $false; 'rdp.nla' = $false; 'services.remoteRegistry' = 'Automatic'
        'accounts.guestEnabled' = $true; 'accounts.builtinAdminEnabled' = $true; 'accounts.localAdminCount' = 6
        'policy.minPasswordLength' = 0; 'policy.lockoutThreshold' = 0; 'screen.lockTimeoutSecs' = 0
        'winlogon.autoLogon' = $true; 'wdigest.cleartext' = $true; 'lsa.protected' = $false; 'ntlm.level' = 2
        'powershell.v2Present' = $true; 'autorun.disabledAllDrives' = $false; 'uac.consentPromptBehaviorAdmin' = 0
    }
}

# Nine more computers with random gaps, always the same thanks to the fixed seed.
# Each one gets a "hygiene" level: the chance that each setting is wrong.
$random = New-Object -TypeName System.Random -ArgumentList 2026
$gaps = [ordered] @{
    'updates.daysSinceLastUpdate' = { $random.Next(50, 160) }; 'reboot.pending' = { $true }; 'secureboot.enabled' = { $false }
    'bitlocker.systemDrive' = { $false }; 'antivirus.upToDate' = { $false }; 'defender.tamperProtected' = { $false }
    'autorun.disabledAllDrives' = { $false }; 'powershell.v2Present' = { $true }; 'firewall.inboundBlocked' = { $false }
    'smb.signingRequired' = { $false }; 'llmnr.disabled' = { $false }; 'services.remoteRegistry' = { 'Manual' }
    'accounts.localAdminCount' = { $random.Next(3, 7) }; 'policy.minPasswordLength' = { 8 }; 'policy.lockoutThreshold' = { 0 }
    'screen.lockTimeoutSecs' = { 0 }; 'lsa.protected' = { $false }; 'ntlm.level' = { 3 }
}
# Serious gaps are rarer
$rareGaps = [ordered] @{
    'firewall.public' = { $false }; 'smb.v1Enabled' = { $true }; 'rdp.nla' = { $false }; 'accounts.guestEnabled' = { $true }
    'accounts.builtinAdminEnabled' = { $true }; 'wdigest.cleartext' = { $true }; 'winlogon.autoLogon' = { $true }
}
$names = 'WS-FIN-021', 'WS-HR-003', 'WS-HR-011', 'LT-SALES-04', 'LT-SALES-15', 'WS-ENG-102', 'WS-ENG-117', 'LT-MGMT-02', 'WS-RECEP-01'
foreach ($name in $names) {
    $hygiene = 0.05 + $random.NextDouble() * 0.45
    $overrides = @{}
    foreach ($key in $gaps.Keys) { if ($random.NextDouble() -lt $hygiene) { $overrides[$key] = & $gaps[$key] } }
    foreach ($key in $rareGaps.Keys) { if ($random.NextDouble() -lt ($hygiene / 3)) { $overrides[$key] = & $rareGaps[$key] } }
    if ($name -like 'LT-*') { $overrides['os.caption'] = 'Microsoft Windows 11 Pro' }
    $devices[$name] = $overrides
}

if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
foreach ($name in $devices.Keys) {
    $facts = [ordered] @{}
    foreach ($key in $hardened.Keys) { $facts[$key] = $hardened[$key] }
    foreach ($key in $devices[$name].Keys) { $facts[$key] = $devices[$name][$key] }
    $json = [ordered] @{ computerName = $name; demo = $true; facts = $facts } | ConvertTo-Json -Depth 4
    $path = Join-Path -Path $OutputPath -ChildPath "$name.json"
    [IO.File]::WriteAllText($path, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    Write-Verbose "Wrote $path"
}
