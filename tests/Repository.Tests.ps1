#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeDiscovery {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $scripts = @(Get-ChildItem -Path $root -Recurse -Include '*.ps1', '*.psd1', '*.psm1' -File |
            Where-Object { $_.FullName -notlike '*\output\*' } |
            ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } })
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
}

Describe 'Script files' {
    # Windows PowerShell 5.1 reads files without a BOM as ANSI and breaks accents
    It '<Name> is UTF-8 with BOM' -TestCases $scripts {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It '<Name> parses without errors' -TestCases $scripts {
        $errors = $null
        [void] [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $errors)
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Demo data' {
    It 'is marked as fictitious' {
        foreach ($file in Get-ChildItem -Path (Join-Path $repoRoot 'demo') -Filter '*.json') {
            ([IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json).demo | Should -BeTrue -Because $file.Name
        }
    }

    It 'is what tools\New-DemoFacts.ps1 writes' {
        $out = Join-Path $TestDrive 'demo'
        & (Join-Path $repoRoot 'tools\New-DemoFacts.ps1') -OutputPath $out
        foreach ($file in Get-ChildItem -Path (Join-Path $repoRoot 'demo') -Filter '*.json') {
            [IO.File]::ReadAllText((Join-Path $out $file.Name)) | Should -BeExactly ([IO.File]::ReadAllText($file.FullName)) -Because $file.Name
        }
    }

    It 'keeps output\ out of git' {
        [IO.File]::ReadAllText((Join-Path $repoRoot '.gitignore')) | Should -Match '(?m)^output/'
    }
}
