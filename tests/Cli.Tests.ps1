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
