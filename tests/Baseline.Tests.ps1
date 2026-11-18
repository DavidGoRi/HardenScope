#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeDiscovery {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $json = [IO.File]::ReadAllText((Join-Path $root 'config\baseline.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $rules = @($json.rules | ForEach-Object { @{ Id = $_.id; Rule = $_ } })
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $baseline = Import-HSBaseline -Path $baselinePath
    $demoFacts = Get-TestDemoFact -Name 'WS-FIN-014'
}

Describe 'config\baseline.json' {
    It 'loads' {
        @($baseline.rules).Count | Should -BeGreaterThan 25
    }

    It '<Id> has English and Spanish texts' -TestCases $rules {
        foreach ($field in 'title', 'risk', 'fix') {
            $Rule.$field.en | Should -Not -BeNullOrEmpty
            $Rule.$field.es | Should -Not -BeNullOrEmpty
        }
    }

    It '<Id> uses a fact the demo computers have' -TestCases $rules {
        $demoFacts.ContainsKey($Rule.fact) | Should -BeTrue
        if ($Rule.when) { $demoFacts.ContainsKey($Rule.when.fact) | Should -BeTrue }
    }

    It '<Id> has a valid id and reference' -TestCases $rules {
        $Rule.id | Should -Match '^HS-[A-Z]+-\d{2}$'
        $Rule.reference | Should -Not -BeNullOrEmpty
    }

    It 'passes every rule on the hardened demo computer except the known gaps' {
        $results = @(Invoke-HSAssessment -Facts (Get-TestDemoFact -Name 'WS-FIN-014') -Baseline $baseline)
        @($results | Where-Object Status -EQ 'Unknown') | Should -HaveCount 0
        @($results | Where-Object Status -EQ 'Fail').Id | Should -Be @('HS-ACC-06')
    }

    It 'grades the demo computers A, C and F' {
        $grades = foreach ($name in 'WS-FIN-014', 'WS-SALES-07', 'LT-OPS-22') {
            (Get-HSScore -Results @(Invoke-HSAssessment -Facts (Get-TestDemoFact -Name $name) -Baseline $baseline)).Grade
        }
        $grades | Should -Be @('A', 'C', 'F')
    }
}
