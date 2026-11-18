#Requires -Version 5.1
# Loaded by every test file in BeforeAll: the HardenScope functions and paths.

$script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
foreach ($file in 'Facts', 'Rules', 'Report', 'Remote', 'Fleet', 'Compare', 'Integrations') {
    . (Join-Path -Path $script:repoRoot -ChildPath "src\$file.ps1")
}
$script:baselinePath = Join-Path -Path $script:repoRoot -ChildPath 'config\baseline.json'
$script:entryPoint = Join-Path -Path $script:repoRoot -ChildPath 'HardenScope.ps1'

function Get-TestDemoFact {
    # Facts of one demo computer as a hashtable
    param([string] $Name = 'WS-FIN-014')
    $path = Join-Path -Path $script:repoRoot -ChildPath "demo\$Name.json"
    $saved = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $facts = @{}
    foreach ($property in $saved.facts.PSObject.Properties) { $facts[$property.Name] = $property.Value }
    return $facts
}

function New-TestRule {
    # A minimal rule for evaluation tests
    param([string] $Fact = 'x', [string] $Op = 'eq', $Value = $true, $When = $null, [string] $Severity = 'high', [string] $Id = 'T-1')
    $rule = [pscustomobject] @{
        id = $Id; category = 'System'; severity = $Severity; fact = $Fact; op = $Op; value = $Value
        title = @{ en = 'title'; es = 'título' }; risk = @{ en = 'r'; es = 'r' }; fix = @{ en = 'f'; es = 'f' }
    }
    if ($When) { $rule | Add-Member -NotePropertyName when -NotePropertyValue $When }
    return $rule
}

function New-TestBaseline {
    param([object[]] $Rules)
    return [pscustomobject] @{
        name = 'test'; version = '1'; rules = $Rules
        weights = [pscustomobject] @{ critical = 10; high = 6; medium = 3; low = 1 }
    }
}
