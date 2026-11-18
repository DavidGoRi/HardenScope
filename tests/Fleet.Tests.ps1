#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Fictitious demo computer names')]
param()

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSetup.ps1')
    . (Join-Path -Path $repoRoot -ChildPath 'src\Fleet.ps1')
    $baseline = Import-HSBaseline -Path $baselinePath

    function Save-TestRecord([string] $Name, [string] $Folder, [datetime] $When = (Get-Date), [string] $Demo = $Name) {
        $facts = Get-TestDemoFact -Name $Demo
        $results = @(Invoke-HSAssessment -Facts $facts -Baseline $baseline)
        $record = New-HSRecord -ComputerName $Name -Facts $facts -Baseline $baseline -Results $results -Score (Get-HSScore -Results $results) -GeneratedAt $When
        if (-not (Test-Path $Folder)) { New-Item -ItemType Directory -Path $Folder | Out-Null }
        $path = Join-Path $Folder ("$Name-{0:yyyyMMddHHmmss}.json" -f $When)
        Save-HSRecord -Record $record -Path $path
        return $path
    }
}

Describe 'New-HSFleetRecord' {
    BeforeAll {
        $folder = Join-Path $TestDrive 'fleet'
        $records = foreach ($name in 'WS-FIN-014', 'WS-SALES-07', 'LT-OPS-22') { Read-HSRecord -Path (Save-TestRecord -Name $name -Folder $folder) }
        $fleet = New-HSFleetRecord -Records $records -Unreachable @([pscustomobject] @{ ComputerName = 'PC99'; Message = 'No response' })
    }

    It 'summarises the computers' {
        $fleet.summary.computers | Should -Be 3
        $fleet.summary.unreachable | Should -Be 1
        $fleet.summary.grades.A | Should -Be 1
        $fleet.summary.grades.C | Should -Be 1
        $fleet.summary.grades.F | Should -Be 1
        $fleet.summary.withCriticalFailures | Should -Be 2
        $fleet.summary.averageScore | Should -Be ([int] [Math]::Round((@($records.score.score) | Measure-Object -Average).Average))
    }

    It 'lists the worst computer first and links its report' {
        $fleet.computers[0].name | Should -Be 'LT-OPS-22'
        $fleet.computers[0].report | Should -BeLike 'LT-OPS-22-*.html'
    }

    It 'orders the failures by the number of computers they affect' {
        $counts = @($fleet.failing | ForEach-Object { $_.failedCount })
        $counts | Should -Be @($counts | Sort-Object -Descending)
        $smb1 = $fleet.failing | Where-Object { $_.id -eq 'HS-NET-05' }
        $smb1.failedOn | Should -Be @('LT-OPS-22', 'WS-SALES-07')
        $smb1.failedCount | Should -Be 2
    }

    It 'keeps the unreachable computers with their reason' {
        $fleet.unreachable[0].name | Should -Be 'PC99'
        $fleet.unreachable[0].message | Should -Be 'No response'
    }

    It 'works with no records at all' {
        $empty = New-HSFleetRecord -Records @()
        $empty.summary.computers | Should -Be 0
        $empty.summary.averageScore | Should -BeNullOrEmpty
    }
}

Describe 'Get-HSLatestRecord' {
    It 'keeps only the newest record of every computer and ignores other JSON files' {
        $folder = Join-Path $TestDrive 'history'
        Save-TestRecord -Name 'PC01' -Folder $folder -When (Get-Date).AddDays(-3) -Demo 'LT-OPS-22' | Out-Null
        Save-TestRecord -Name 'PC01' -Folder $folder -When (Get-Date) -Demo 'WS-FIN-014' | Out-Null
        Save-TestRecord -Name 'PC02' -Folder $folder -Demo 'WS-SALES-07' | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder 'other.json'), '{"name":"not a record"}')
        $latest = @(Get-HSLatestRecord -Path $folder)
        $latest | Should -HaveCount 2
        ($latest | Where-Object { $_.device.name -eq 'PC01' }).score.grade | Should -Be 'A'
    }
}

Describe 'Save-HSFleetReport' {
    It 'writes the JSON and the HTML with the data embedded' {
        $folder = Join-Path $TestDrive 'save'
        $records = @(Read-HSRecord -Path (Save-TestRecord -Name 'WS-SALES-07' -Folder $folder))
        $html = Save-HSFleetReport -Fleet (New-HSFleetRecord -Records $records) -OutputPath $folder -Stamp 'test'
        Test-Path (Join-Path $folder 'fleet-test.json') | Should -BeTrue
        $text = [IO.File]::ReadAllText($html)
        $text | Should -Match '"kind":"fleet"'
        $text | Should -Not -Match ([regex]::Escape('/*__DATA__*/null'))
    }

    It 'loads nothing from the internet' {
        [IO.File]::ReadAllText((Join-Path $repoRoot 'src\fleet-template.html')) | Should -Not -Match '<(script|link)[^>]+(src|href)="https?:'
    }
}
