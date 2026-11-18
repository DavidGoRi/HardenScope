#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Fictitious computer names')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $powershell = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
    $utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true

    function New-TestFleet {
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        (& $entryPoint -FactsPath (Join-Path $repoRoot 'demo\*.json') -OutputPath $out -Quiet -PassThru -NoCompare).Fleet
    }
}

Describe 'Get-HSPCScopeComputer' {
    It 'reads the computers of a PCScope data folder and ignores its history' {
        $data = Join-Path $TestDrive 'data'
        New-Item -ItemType Directory -Path (Join-Path $data 'history\OFFICE-PC01') -Force | Out-Null
        foreach ($name in 'OFFICE-PC01', 'SALES-LT07') {
            [IO.File]::WriteAllText((Join-Path $data "$name.json"), "{`"schemaVersion`":1,`"computerName`":`"$name`"}", $utf8Bom)
        }
        [IO.File]::WriteAllText((Join-Path $data 'history\OFFICE-PC01\old.json'), '{"schemaVersion":1,"computerName":"OLD-PC"}')
        [IO.File]::WriteAllText((Join-Path $data 'alerts-state.json'), '{"sent":[]}')
        Get-HSPCScopeComputer -Path $data | Should -Be @('OFFICE-PC01', 'SALES-LT07')
    }

    It 'reads devices.csv with <Name> as delimiter' -TestCases @(@{ Name = 'comma'; Delimiter = ',' }, @{ Name = 'semicolon'; Delimiter = ';' }) {
        $csv = Join-Path $TestDrive "devices-$Name.csv"
        $lines = @('"Device"{0}"Status"{0}"Model"', '"FIN-LT03"{0}"warning"{0}"ProBook"', '"OPS-PC04"{0}"ok"{0}"OptiDesk"') | ForEach-Object { $_ -f $Delimiter }
        [IO.File]::WriteAllLines($csv, [string[]] $lines, $utf8Bom)
        Get-HSPCScopeComputer -Path $csv | Should -Be @('FIN-LT03', 'OPS-PC04')
    }

    It 'fails when the inventory has no computers' {
        $empty = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        { Get-HSPCScopeComputer -Path $empty } | Should -Throw '*No computers*'
        { Get-HSPCScopeComputer -Path (Join-Path $TestDrive 'missing') } | Should -Throw '*not found*'
    }
}

Describe 'Send-HSDeskScope' {
    BeforeAll {
        $fleet = New-TestFleet
    }

    It 'posts the fleet to the HardenScope import with the token' {
        Mock Invoke-HSDeskScopeRequest { [pscustomobject] @{ created = @(1, 2); updated = @(); resolved = @() } }
        $result = Send-HSDeskScope -Fleet $fleet -Url 'https://desk.corp.example.com/' -Severity 'critical', 'high' -Language 'es' -Token 'dsk_test'
        @($result.created).Count | Should -Be 2
        Should -Invoke Invoke-HSDeskScopeRequest -Times 1 -ParameterFilter {
            $Parameters.Uri -eq 'https://desk.corp.example.com/api/v1/import/hardenscope?lang=es&severities=critical%2Chigh' -and
            $Parameters.Method -eq 'Post' -and $Parameters.Headers.Authorization -eq 'Bearer dsk_test'
        }
    }

    It 'sends the fleet summary but not the raw facts or local paths' {
        $script:sent = $null
        Mock Invoke-HSDeskScopeRequest { $script:sent = [Text.Encoding]::UTF8.GetString($Parameters.Body); [pscustomobject] @{} }
        Send-HSDeskScope -Fleet $fleet -Url 'http://localhost:8770' -Token 'dsk_test' | Out-Null
        $payload = $script:sent | ConvertFrom-Json
        $payload.tool | Should -Be 'HardenScope'
        $payload.kind | Should -Be 'fleet'
        @($payload.computers).Count | Should -Be @($fleet.computers).Count
        $payload.failing[0].failedOn | Should -Not -BeNullOrEmpty
        $payload.failing[0].risk.es | Should -Not -BeNullOrEmpty
        $script:sent | Should -Not -Match '"facts"|"report"'
    }

    It 'needs a token and an http(s) URL' {
        { Send-HSDeskScope -Fleet $fleet -Url 'http://localhost:8770' -Token '' } | Should -Throw '*DESKSCOPE_TOKEN*'
        { Send-HSDeskScope -Fleet $fleet -Url 'desk.corp.example.com' -Token 'dsk_test' } | Should -Throw '*http*'
    }
}

Describe 'HardenScope.ps1 -DeskScopeUrl' {
    It 'keeps the reports and exits with code 4 when DeskScope cannot be reached' {
        $out = Join-Path $TestDrive 'unreachable'
        $env:DESKSCOPE_TOKEN = 'dsk_test'
        try {
            # Port 9 (discard) is closed on a normal computer: the connection is refused at once
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $entryPoint -FactsPath (Join-Path $repoRoot 'demo\WS-SALES-07.json') -OutputPath $out -Quiet -DeskScopeUrl 'http://127.0.0.1:9' 2>$null
            $LASTEXITCODE | Should -Be 4
        }
        finally { Remove-Item -Path Env:\DESKSCOPE_TOKEN -ErrorAction SilentlyContinue }
        @(Get-ChildItem $out -Filter 'fleet-*.json').Count | Should -Be 1
        @(Get-ChildItem $out -Filter 'WS-SALES-07-*.html').Count | Should -Be 1
    }
}
