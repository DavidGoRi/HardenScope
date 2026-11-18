#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Fictitious demo computer names')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $baseline = Import-HSBaseline -Path $baselinePath
    $powershell = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'

    function New-TestRecordFrom([hashtable] $Facts, [string] $Name = 'PC01', [datetime] $When = (Get-Date)) {
        $results = @(Invoke-HSAssessment -Facts $Facts -Baseline $baseline)
        New-HSRecord -ComputerName $Name -Facts $Facts -Baseline $baseline -Results $results -Score (Get-HSScore -Results $results) -GeneratedAt $When
    }
}

Describe 'Compare-HSResult' {
    BeforeAll {
        $good = Get-TestDemoFact -Name 'WS-FIN-014'
        $before = $good.Clone()
        $before['smb.v1Enabled'] = $true          # fixed since
        $before['llmnr.disabled'] = $false        # fixed since
        $now = $good.Clone()
        $now['bitlocker.systemDrive'] = $false    # broke since
        $now['policy.minPasswordLength'] = $null  # unknown now: not a change
        $before['policy.minPasswordLength'] = 8
        $previous = (New-TestRecordFrom -Facts $before) | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $results = @(Invoke-HSAssessment -Facts $now -Baseline $baseline)
        $score = Get-HSScore -Results $results
        $changes = Compare-HSResult -Previous $previous -Results $results -Score $score
    }

    It 'lists the checks fixed since the previous audit' {
        $changes.fixed | Sort-Object | Should -Be @('HS-NET-05', 'HS-NET-07')
    }

    It 'lists the regressions' {
        $changes.regressed | Should -Be @('HS-SYS-06')
    }

    It 'ignores checks that could not be read' {
        $changes.fixed + $changes.regressed | Should -Not -Contain 'HS-ACC-04'
    }

    It 'computes the score change' {
        $changes.scoreDelta | Should -Be ($score.Score - $previous.score.score)
        $changes.previousGrade | Should -Be $previous.score.grade
    }

    It 'works with records read back from JSON' {
        $current = (New-TestRecordFrom -Facts $now) | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        (Compare-HSResult -Previous $previous -Results @($current.results) -Score $score).regressed | Should -Be @('HS-SYS-06')
    }
}

Describe 'Get-HSPreviousRecord' {
    It 'finds the newest older record of the same computer' {
        $folder = Join-Path $TestDrive 'runs'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $facts = Get-TestDemoFact -Name 'WS-SALES-07'
        foreach ($item in @(@('PC01', -10), @('PC01', -3), @('PC01', 0), @('PC010', -1))) {
            $when = (Get-Date).Date.AddDays($item[1])
            Save-HSRecord -Record (New-TestRecordFrom -Facts $facts -Name $item[0] -When $when) -Path (Join-Path $folder ("{0}-{1:yyyyMMdd-HHmmss}.json" -f $item[0], $when))
        }
        $found = Get-HSPreviousRecord -Path $folder -ComputerName 'PC01' -Before ((Get-Date).Date)
        ([datetimeoffset] $found.generatedAt).Date | Should -Be ((Get-Date).Date.AddDays(-3))
        $found.device.name | Should -Be 'PC01'
    }

    It 'returns nothing for a computer without history' {
        Get-HSPreviousRecord -Path $TestDrive -ComputerName 'NEW-PC' -Before (Get-Date) | Should -BeNullOrEmpty
    }
}

Describe 'HardenScope.ps1 and earlier audits' {
    BeforeAll {
        $demo = Join-Path $repoRoot 'demo'
    }

    It 'compares with the previous audit in the output folder' {
        $out = Join-Path $TestDrive 'auto'
        & $entryPoint -FactsPath (Join-Path $demo 'previous\WS-SALES-07.json') -OutputPath $out -Quiet | Out-Null
        $run = & $entryPoint -FactsPath (Join-Path $demo 'WS-SALES-07.json') -OutputPath $out -Quiet -PassThru
        $run.Record.changes | Should -Not -BeNullOrEmpty
        $run.Record.changes.previousAt | Should -Be '2026-10-19T09:30:00+02:00'
        (@($run.Record.changes.fixed).Count + @($run.Record.changes.regressed).Count) | Should -BeGreaterThan 0
    }

    It 'names the files of saved facts after the date they were collected' {
        $out = Join-Path $TestDrive 'dated'
        $run = & $entryPoint -FactsPath (Join-Path $demo 'previous\WS-HR-003.json') -OutputPath $out -Quiet -PassThru
        Split-Path $run.JsonPath -Leaf | Should -Be 'WS-HR-003-20261019-093000.json'
    }

    It 'skips the comparison with -NoCompare' {
        $out = Join-Path $TestDrive 'nocompare'
        & $entryPoint -FactsPath (Join-Path $demo 'previous\WS-SALES-07.json') -OutputPath $out -Quiet | Out-Null
        $run = & $entryPoint -FactsPath (Join-Path $demo 'WS-SALES-07.json') -OutputPath $out -Quiet -PassThru -NoCompare
        $run.Record.changes | Should -BeNullOrEmpty
    }

    It 'compares with an explicit record with -CompareWith' {
        $old = & $entryPoint -FactsPath (Join-Path $demo 'previous\LT-OPS-22.json') -OutputPath (Join-Path $TestDrive 'old') -Quiet -PassThru
        $run = & $entryPoint -FactsPath (Join-Path $demo 'LT-OPS-22.json') -OutputPath (Join-Path $TestDrive 'new') -Quiet -PassThru -CompareWith $old.JsonPath
        $run.Record.changes.previousScore | Should -Be $old.Record.score.score
    }

    It 'shows the score change of every computer in the fleet report' {
        $out = Join-Path $TestDrive 'fleet'
        & $entryPoint -FactsPath (Join-Path $demo 'previous\*.json') -OutputPath $out -Quiet | Out-Null
        $run = & $entryPoint -FactsPath (Join-Path $demo '*.json') -OutputPath $out -Quiet -PassThru
        $run.Fleet.summary.compared | Should -Be $run.Fleet.summary.computers
        $run.Fleet.summary.improved + $run.Fleet.summary.worsened | Should -BeGreaterThan 0
        @($run.Fleet.computers | Where-Object { $null -eq $_.change }) | Should -HaveCount 0
    }

    It 'exits with code 3 on a regression with -FailOnRegression' {
        $out = Join-Path $TestDrive 'regression'
        & $entryPoint -FactsPath (Join-Path $demo 'previous\WS-HR-003.json') -OutputPath $out -Quiet | Out-Null
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $entryPoint -FactsPath (Join-Path $demo 'WS-HR-003.json') -OutputPath $out -Quiet -FailOnRegression
        $LASTEXITCODE | Should -Be 3
    }
}
