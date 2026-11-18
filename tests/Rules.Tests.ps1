#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
}

Describe 'Test-HSCondition' {
    It 'compares with <Op>' -TestCases @(
        @{ Actual = $true; Op = 'eq'; Expected = $true; Result = $true }
        @{ Actual = $false; Op = 'eq'; Expected = $true; Result = $false }
        @{ Actual = 'Disabled'; Op = 'eq'; Expected = 'disabled'; Result = $true }
        @{ Actual = 0; Op = 'ne'; Expected = 0; Result = $false }
        @{ Actual = 14; Op = 'ge'; Expected = 14; Result = $true }
        @{ Actual = 46; Op = 'le'; Expected = 45; Result = $false }
        @{ Actual = 19044; Op = 'in'; Expected = @(17763, 19044); Result = $true }
        @{ Actual = 0; Op = 'between'; Expected = @(1, 5); Result = $false }
        @{ Actual = 5; Op = 'between'; Expected = @(1, 5); Result = $true }
    ) {
        Test-HSCondition -Actual $Actual -Op $Op -Expected $Expected | Should -Be $Result
    }

    It 'returns null when the fact is unknown' {
        Test-HSCondition -Actual $null -Op 'eq' -Expected $true | Should -BeNullOrEmpty
    }

    It 'rejects an unknown operator' {
        { Test-HSCondition -Actual 1 -Op 'like' -Expected 1 } | Should -Throw
    }
}

Describe 'Invoke-HSAssessment' {
    It 'marks a rule as Pass, Fail or Unknown' {
        $baseline = New-TestBaseline -Rules @(
            (New-TestRule -Id 'A' -Fact 'a'), (New-TestRule -Id 'B' -Fact 'b'), (New-TestRule -Id 'C' -Fact 'missing'))
        $results = @(Invoke-HSAssessment -Facts @{ a = $true; b = $false } -Baseline $baseline)
        ($results | Where-Object Id -EQ 'A').Status | Should -Be 'Pass'
        ($results | Where-Object Id -EQ 'B').Status | Should -Be 'Fail'
        ($results | Where-Object Id -EQ 'C').Status | Should -Be 'Unknown'
    }

    It 'skips a rule whose when condition is false' {
        $rule = New-TestRule -Fact 'rdp.nla' -When ([pscustomobject] @{ fact = 'rdp.enabled'; op = 'eq'; value = $true })
        $result = Invoke-HSAssessment -Facts @{ 'rdp.enabled' = $false; 'rdp.nla' = $false } -Baseline (New-TestBaseline -Rules @($rule))
        $result.Status | Should -Be 'NotApplicable'
    }

    It 'evaluates a rule whose when condition is true' {
        $rule = New-TestRule -Fact 'rdp.nla' -When ([pscustomobject] @{ fact = 'rdp.enabled'; op = 'eq'; value = $true })
        $result = Invoke-HSAssessment -Facts @{ 'rdp.enabled' = $true; 'rdp.nla' = $false } -Baseline (New-TestBaseline -Rules @($rule))
        $result.Status | Should -Be 'Fail'
    }

    It 'reads facts loaded from JSON' {
        $facts = '{"a": true}' | ConvertFrom-Json
        (Invoke-HSAssessment -Facts $facts -Baseline (New-TestBaseline -Rules @(New-TestRule -Fact 'a'))).Status | Should -Be 'Pass'
    }
}

Describe 'Get-HSScore' {
    BeforeAll {
        function New-Result([string] $Status, [string] $Severity, [int] $Weight) {
            [pscustomobject] @{ Status = $Status; Severity = $Severity; Weight = $Weight }
        }
    }

    It 'weights the checks by severity' {
        $score = Get-HSScore -Results @((New-Result 'Pass' 'high' 6), (New-Result 'Fail' 'medium' 3), (New-Result 'Pass' 'low' 1))
        $score.Score | Should -Be 70
        $score.Grade | Should -Be 'C'
        $score.FailedBySeverity['medium'] | Should -Be 1
    }

    It 'ignores Unknown and NotApplicable checks' {
        $score = Get-HSScore -Results @((New-Result 'Pass' 'high' 6), (New-Result 'Unknown' 'critical' 10), (New-Result 'NotApplicable' 'high' 6))
        $score.Score | Should -Be 100
        $score.Unknown | Should -Be 1
        $score.NotApplicable | Should -Be 1
    }

    It 'caps the grade at C when a critical check fails' {
        $results = @(1..30 | ForEach-Object { New-Result 'Pass' 'critical' 10 }) + @(New-Result 'Fail' 'critical' 10)
        $score = Get-HSScore -Results $results
        $score.Score | Should -BeGreaterOrEqual 90
        $score.Grade | Should -Be 'C'
    }

    It 'has no score when nothing could be evaluated' {
        $score = Get-HSScore -Results @(New-Result 'Unknown' 'high' 6)
        $score.Score | Should -BeNullOrEmpty
        $score.Grade | Should -BeNullOrEmpty
    }
}

Describe 'Import-HSBaseline' {
    It 'rejects <Case>' -TestCases @(
        @{ Case = 'an unknown operator'; Json = '{"weights":{},"rules":[{"id":"X","category":"c","severity":"high","fact":"f","op":"like","title":{},"risk":{},"fix":{}}]}' }
        @{ Case = 'an unknown severity'; Json = '{"weights":{},"rules":[{"id":"X","category":"c","severity":"huge","fact":"f","op":"eq","title":{},"risk":{},"fix":{}}]}' }
        @{ Case = 'a missing field'; Json = '{"weights":{},"rules":[{"id":"X","category":"c","severity":"high","op":"eq","title":{},"risk":{},"fix":{}}]}' }
        @{ Case = 'a duplicate id'; Json = '{"weights":{},"rules":[{"id":"X","category":"c","severity":"high","fact":"f","op":"eq","title":{},"risk":{},"fix":{}},{"id":"X","category":"c","severity":"high","fact":"f","op":"eq","title":{},"risk":{},"fix":{}}]}' }
        @{ Case = 'a bad range'; Json = '{"weights":{},"rules":[{"id":"X","category":"c","severity":"high","fact":"f","op":"between","value":[1],"title":{},"risk":{},"fix":{}}]}' }
    ) {
        $path = Join-Path -Path $TestDrive -ChildPath 'bad.json'
        [IO.File]::WriteAllText($path, $Json)
        { Import-HSBaseline -Path $path } | Should -Throw
    }
}
