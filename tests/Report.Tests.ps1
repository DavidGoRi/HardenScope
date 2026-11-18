#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Fictitious demo computer names')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $baseline = Import-HSBaseline -Path $baselinePath
    $facts = Get-TestDemoFact -Name 'WS-SALES-07'
    $results = @(Invoke-HSAssessment -Facts $facts -Baseline $baseline)
    $score = Get-HSScore -Results $results
    $record = New-HSRecord -ComputerName 'WS-SALES-07' -Facts $facts -Baseline $baseline -Results $results -Score $score
}

Describe 'New-HSRecord' {
    It 'keeps the score, the results and the facts' {
        $record.tool | Should -Be 'HardenScope'
        $record.device.name | Should -Be 'WS-SALES-07'
        $record.score.grade | Should -Be 'C'
        @($record.results).Count | Should -Be @($baseline.rules).Count
        $record.facts['os.build'] | Should -Be 26100
    }

    It 'keeps the time zone of the date it was collected on' {
        # Any offset different from the local one: the CI computers run in UTC
        $when = [datetimeoffset] '2026-10-19T09:30:00+05:00'
        $dated = New-HSRecord -ComputerName 'WS-SALES-07' -Facts $facts -Baseline $baseline -Results $results -Score $score -GeneratedAt $when
        $dated.generatedAt | Should -Be '2026-10-19T09:30:00+05:00'
    }

    It 'round-trips through JSON' {
        $path = Join-Path $TestDrive 'record.json'
        Save-HSRecord -Record $record -Path $path
        $back = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        $back.score.score | Should -Be $record.score.score
        ($back.results | Where-Object id -EQ 'HS-NET-05').status | Should -Be 'Fail'
    }
}

Describe 'ConvertTo-HSHtml' {
    It 'embeds the record in the template' {
        $html = ConvertTo-HSHtml -Record $record
        $html | Should -Not -Match ([regex]::Escape('/*__DATA__*/null'))
        $html | Should -Match '"WS-SALES-07"'
        $html | Should -Match '<title>HardenScope report</title>'
    }

    It 'cannot close the script element from inside the data' {
        $copy = New-HSRecord -ComputerName '</script><b>x' -Facts @{} -Baseline $baseline -Results @() -Score (Get-HSScore -Results @())
        $html = ConvertTo-HSHtml -Record $copy
        # Windows PowerShell already writes < as <; PowerShell 7 does not
        $html.Contains('</script><b>x') | Should -BeFalse
        $html.Contains('x') | Should -BeTrue
    }

    It 'loads nothing from the internet' {
        $template = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\report-template.html'))
        $template | Should -Not -Match '<(script|link)[^>]+(src|href)="https?:'
    }
}

Describe 'HTML templates' {
    It '<_> has a dark mode and a light/dark button' -ForEach @('report-template.html', 'fleet-template.html') {
        $template = [IO.File]::ReadAllText((Join-Path $repoRoot "src\$_"))
        $template | Should -Match 'prefers-color-scheme: dark'
        $template | Should -Match ([regex]::Escape(':root[data-theme="dark"]'))
        $template | Should -Match 'id="themeBtn"'
        $template | Should -Match "localStorage.setItem\('hs-theme'"
    }
}

