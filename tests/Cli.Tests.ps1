#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    $powershell = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
    if (-not (Test-Path $powershell)) { $powershell = (Get-Process -Id $PID).Path }
}

Describe 'HardenScope.ps1 with saved facts' {
    It 'writes the JSON and HTML reports of a demo computer' {
        $out = Join-Path $TestDrive 'out'
        $run = & $entryPoint -FactsPath (Join-Path $repoRoot 'demo\LT-OPS-22.json') -OutputPath $out -Quiet -PassThru
        Test-Path $run.JsonPath | Should -BeTrue
        Test-Path $run.HtmlPath | Should -BeTrue
        $run.Record.device.name | Should -Be 'LT-OPS-22'
        $run.Record.score.grade | Should -Be 'F'
    }

    It 'resolves a relative -OutputPath against the current location' {
        Push-Location -Path $TestDrive
        try { $run = & $entryPoint -FactsPath (Join-Path $repoRoot 'demo\WS-FIN-014.json') -OutputPath 'relative' -Quiet -PassThru }
        finally { Pop-Location }
        $run.JsonPath | Should -BeLike "$TestDrive*relative*"
        Test-Path $run.JsonPath | Should -BeTrue
    }

    It 'builds a fleet report when -FactsPath matches several files' {
        $run = & $entryPoint -FactsPath (Join-Path $repoRoot 'demo\*.json') -OutputPath (Join-Path $TestDrive 'fleet') -Quiet -PassThru
        $demoCount = @(Get-ChildItem (Join-Path $repoRoot 'demo') -Filter '*.json').Count
        $run.Computers | Should -HaveCount $demoCount
        $run.Fleet.summary.computers | Should -Be $demoCount
        Test-Path $run.FleetPath | Should -BeTrue
        @(Get-ChildItem (Join-Path $TestDrive 'fleet') -Filter '*.html').Count | Should -Be ($demoCount + 1)
    }

    It 'rebuilds the fleet report from a folder with -FleetFrom' {
        $folder = Join-Path $TestDrive 'again'
        & $entryPoint -FactsPath (Join-Path $repoRoot 'demo\WS-*.json') -OutputPath $folder -Quiet | Out-Null
        $run = & $entryPoint -FleetFrom $folder -Quiet -PassThru
        $run.Fleet.summary.computers | Should -Be @(Get-ChildItem (Join-Path $repoRoot 'demo') -Filter 'WS-*.json').Count
        Split-Path $run.FleetPath -Parent | Should -Be $folder
    }

    It 'checks -FailOn on every computer of a fleet' {
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $entryPoint -FactsPath (Join-Path $repoRoot 'demo\W*.json') -OutputPath (Join-Path $TestDrive 'fail') -Quiet -FailOn critical
        $LASTEXITCODE | Should -Be 2
    }

    It 'exits with code 2 when -FailOn finds a failed check' {
        $out = Join-Path $TestDrive 'out2'
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $entryPoint -FactsPath (Join-Path $repoRoot 'demo\WS-SALES-07.json') -OutputPath $out -Quiet -FailOn critical
        $LASTEXITCODE | Should -Be 2
    }

    It 'exits with code 0 when nothing reaches the -FailOn level' {
        $out = Join-Path $TestDrive 'out3'
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $entryPoint -FactsPath (Join-Path $repoRoot 'demo\WS-FIN-014.json') -OutputPath $out -Quiet -FailOn medium
        $LASTEXITCODE | Should -Be 0
    }
}
