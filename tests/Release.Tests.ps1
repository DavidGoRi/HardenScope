#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

Describe 'Version and changelog' {
    It 'CHANGELOG.md has a section for the current version' {
        [IO.File]::ReadAllText((Join-Path $repoRoot 'CHANGELOG.md')) | Should -Match ('(?m)^## \[' + [regex]::Escape($script:HSVersion) + '\] - \d{4}-\d{2}-\d{2}\r?$')  # CRLF on CI checkouts
    }

    It 'the Release workflow checks the tag against src\Report.ps1' {
        $workflow = [IO.File]::ReadAllText((Join-Path $repoRoot '.github\workflows\release.yml'))
        $workflow | Should -Match 'tags: \[''v\*''\]'
        $workflow | Should -Match 'Build-Release\.ps1'
        $workflow | Should -Not -Match 'ADFlow'
    }
}

Describe 'tools\Build-Release.ps1' {
    BeforeAll {
        $build = & (Join-Path $repoRoot 'tools\Build-Release.ps1') -OutputPath (Join-Path $TestDrive 'dist')
        $zip = [IO.Compression.ZipFile]::OpenRead($build.Zip)
        $entries = @($zip.Entries | ForEach-Object { $_.FullName })
        $zip.Dispose()
    }

    It 'names the zip after the version' {
        $build.Version | Should -Be $script:HSVersion
        Split-Path $build.Zip -Leaf | Should -Be "HardenScope-$($script:HSVersion).zip"
    }

    It 'writes a matching SHA-256 file' {
        $line = [IO.File]::ReadAllText("$($build.Zip).sha256").Trim()
        $line | Should -Be "$($build.Sha256)  HardenScope-$($script:HSVersion).zip"
        (Get-FileHash -Path $build.Zip -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $build.Sha256
    }

    It 'contains everything needed to run, with forward slashes' {
        $prefix = "HardenScope-$($script:HSVersion)/"
        foreach ($file in 'HardenScope.ps1', 'LICENSE', 'README.md', 'README.es.md', 'CHANGELOG.md', 'config/baseline.json',
            'src/Facts.ps1', 'src/Rules.ps1', 'src/Report.ps1', 'src/Remote.ps1', 'src/Fleet.ps1', 'src/Compare.ps1',
            'src/Integrations.ps1', 'src/report-template.html', 'src/fleet-template.html', 'demo/WS-SALES-07.json',
            'demo/previous/WS-SALES-07.json') {
            $entries | Should -Contain ($prefix + $file)
        }
        $entries | Where-Object { $_ -match '\\' } | Should -BeNullOrEmpty
    }

    It 'leaves out the tests, tools, screenshots and any audit output' {
        $entries | Where-Object { $_ -match '/(tests|tools|docs|output|\.github)/' } | Should -BeNullOrEmpty
    }

    It 'runs from the extracted zip' {
        $extract = Join-Path $TestDrive 'extract'
        [IO.Compression.ZipFile]::ExtractToDirectory($build.Zip, $extract)
        $entry = Join-Path $extract "HardenScope-$($script:HSVersion)\HardenScope.ps1"
        $run = & $entry -FactsPath (Join-Path (Split-Path $entry) 'demo\WS-FIN-014.json') -OutputPath (Join-Path $TestDrive 'zip-out') -Quiet -PassThru
        $run.Record.score.grade | Should -Be 'A'
    }
}
