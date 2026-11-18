#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $site = Join-Path $TestDrive 'site'
    $pages = @(& (Join-Path $repoRoot 'tools\Build-Demo.ps1') -OutputPath $site)
    $index = [IO.File]::ReadAllText((Join-Path $site 'index.html'))
}

Describe 'tools\Build-Demo.ps1' {
    It 'writes the tour, the fleet report and one report per demo computer' {
        $computers = @(Get-ChildItem (Join-Path $repoRoot 'demo') -Filter '*.json').Count
        Test-Path (Join-Path $site 'index.html') | Should -BeTrue
        Test-Path (Join-Path $site 'reports\fleet.html') | Should -BeTrue
        Test-Path (Join-Path $site 'data\fleet.json') | Should -BeTrue
        @(Get-ChildItem (Join-Path $site 'reports') -Filter '*.html').Count | Should -Be ($computers + 1)
        $pages.Count | Should -Be ($computers + 3)
    }

    It 'fills every placeholder of the tour' {
        $index | Should -Not -Match '\{\{\w+\}\}'
        $index | Should -Match ([regex]::Escape("HardenScope $($script:HSVersion)"))
    }

    It 'links every computer of the fleet report to a page that exists' {
        $fleet = [IO.File]::ReadAllText((Join-Path $site 'data\fleet.json')) | ConvertFrom-Json
        foreach ($computer in $fleet.computers) {
            $computer.report | Should -Be "$($computer.name).html"
            Test-Path (Join-Path $site "reports\$($computer.report)") | Should -BeTrue
        }
        foreach ($link in [regex]::Matches($index, 'href="(reports/[^"?]+)"')) {
            Test-Path (Join-Path $site $link.Groups[1].Value.Replace('/', '\')) | Should -BeTrue -Because $link.Value
        }
    }

    It 'compares today with an audit of a month ago' {
        $fleet = [IO.File]::ReadAllText((Join-Path $site 'data\fleet.json')) | ConvertFrom-Json
        $fleet.summary.compared | Should -Be $fleet.summary.computers
        $record = [IO.File]::ReadAllText((Join-Path $site 'reports\WS-SALES-07.html'))
        $previous = [regex]::Match($record, '"previousAt":"([^"]+)"').Groups[1].Value
        ((Get-Date) - ([datetimeoffset] $previous).LocalDateTime).TotalDays | Should -BeGreaterThan 29
    }

    It 'has a dark mode, a theme button and both languages' {
        $index | Should -Match 'prefers-color-scheme: dark'
        $index | Should -Match 'id="themeBtn"'
        $index | Should -Match 'class="en"'
        $index | Should -Match 'class="es"'
    }

    It 'loads nothing from the internet' {
        $index | Should -Not -Match '<(script|link|img)[^>]+(src|href)="https?:'
    }

    It 'contains no detail of the computer that built it' {
        foreach ($file in Get-ChildItem $site -Recurse -File) {
            $text = [IO.File]::ReadAllText($file.FullName)
            $text.IndexOf($env:COMPUTERNAME, [StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because $file.Name
        }
    }
}
