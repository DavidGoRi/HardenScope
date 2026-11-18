#Requires -Version 5.1
# Baseline evaluation: compares the collected facts with the rules in
# config\baseline.json and computes the hardening score.

$script:HSOperators = @('eq', 'ne', 'ge', 'le', 'in', 'between')
$script:HSSeverities = @('critical', 'high', 'medium', 'low')

function Import-HSBaseline {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Baseline not found: $Path" }
    $baseline = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $ids = @{}
    foreach ($rule in @($baseline.rules)) {
        foreach ($field in 'id', 'category', 'severity', 'fact', 'op', 'title', 'risk', 'fix') {
            if ($null -eq $rule.$field) { throw "Rule $($rule.id) has no '$field'" }
        }
        if ($ids.ContainsKey($rule.id)) { throw "Duplicate rule id: $($rule.id)" }
        $ids[$rule.id] = $true
        if ($script:HSSeverities -notcontains $rule.severity) { throw "Rule $($rule.id): unknown severity '$($rule.severity)'" }
        foreach ($condition in @($rule, $rule.when) | Where-Object { $_ }) {
            if ($script:HSOperators -notcontains $condition.op) { throw "Rule $($rule.id): unknown operator '$($condition.op)'" }
        }
        if ($rule.op -eq 'between' -and @($rule.value).Count -ne 2) { throw "Rule $($rule.id): 'between' needs [min, max]" }
    }
    return $baseline
}

function Get-HSFactValue {
    # Works with the hashtable from Get-HSFact and with the object read back from JSON
    param([Parameter(Mandatory)] $Facts, [Parameter(Mandatory)] [string] $Name)
    if ($Facts -is [Collections.IDictionary]) {
        if ($Facts.Contains($Name)) { return , $Facts[$Name] }
        return $null
    }
    $property = $Facts.PSObject.Properties[$Name]
    if ($property) { return , $property.Value }
    return $null
}

function Test-HSCondition {
    # $true / $false, or $null when the fact is unknown
    param($Actual, [Parameter(Mandatory)] [string] $Op, $Expected)
    if ($null -eq $Actual) { return $null }
    switch ($Op) {
        'eq' { return ($Actual -eq $Expected) }
        'ne' { return ($Actual -ne $Expected) }
        'ge' { return ([double] $Actual -ge [double] $Expected) }
        'le' { return ([double] $Actual -le [double] $Expected) }
        'in' { return (@($Expected) -contains $Actual) }
        'between' {
            $range = @($Expected)
            return ([double] $Actual -ge [double] $range[0] -and [double] $Actual -le [double] $range[1])
        }
        default { throw "Unknown operator: $Op" }
    }
}

function Format-HSExpected {
    param([Parameter(Mandatory)] [string] $Op, $Value)
    $text = { param($v) if ($v -is [bool]) { $v.ToString().ToLowerInvariant() } else { [string] $v } }
    switch ($Op) {
        'eq' { return (& $text $Value) }
        'ne' { return "not $(& $text $Value)" }
        'ge' { return ">= $Value" }
        'le' { return "<= $Value" }
        'in' { return "one of $(@($Value) -join ', ')" }
        'between' { return "$(@($Value)[0]) - $(@($Value)[1])" }
    }
}

function Invoke-HSAssessment {
    <#
    .SYNOPSIS
        Evaluates every rule. Status is Pass, Fail, Unknown (fact not readable)
        or NotApplicable (its 'when' condition is false).
    #>
    param([Parameter(Mandatory)] $Facts, [Parameter(Mandatory)] $Baseline)
    foreach ($rule in @($Baseline.rules)) {
        $actual = Get-HSFactValue -Facts $Facts -Name $rule.fact
        $status = 'Unknown'
        $applies = $true
        if ($rule.when) {
            $applies = Test-HSCondition -Actual (Get-HSFactValue -Facts $Facts -Name $rule.when.fact) -Op $rule.when.op -Expected $rule.when.value
        }
        if ($applies -eq $false) { $status = 'NotApplicable' }
        elseif ($null -ne $applies) {
            $ok = Test-HSCondition -Actual $actual -Op $rule.op -Expected $rule.value
            if ($ok -eq $true) { $status = 'Pass' } elseif ($ok -eq $false) { $status = 'Fail' }
        }
        [pscustomobject] @{
            Id        = $rule.id
            Category  = $rule.category
            Severity  = $rule.severity
            Status    = $status
            Fact      = $rule.fact
            Actual    = $actual
            Op        = $rule.op
            Value     = $rule.value
            Expected  =(Format-HSExpected -Op $rule.op -Value $rule.value)
            Weight    = [int] $Baseline.weights.($rule.severity)
            Title     = $rule.title
            Risk      = $rule.risk
            Fix       = $rule.fix
            Command   = $rule.command
            Reference = $rule.reference
        }
    }
}

function Get-HSScore {
    <#
    .SYNOPSIS
        Weighted score from 0 to 100 over the rules that could be evaluated.
        A failed critical rule caps the grade at C, whatever the score.
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results)
    $evaluated = @($Results | Where-Object { $_.Status -eq 'Pass' -or $_.Status -eq 'Fail' })
    $failed = @($evaluated | Where-Object { $_.Status -eq 'Fail' })
    $total = ($evaluated | Measure-Object -Property Weight -Sum).Sum
    $lost = ($failed | Measure-Object -Property Weight -Sum).Sum
    $score = $null
    $grade = $null
    if ($total -gt 0) {
        $score = [int] [Math]::Round(100.0 * ($total - $lost) / $total)
        $grade = if ($score -ge 90) { 'A' } elseif ($score -ge 75) { 'B' } elseif ($score -ge 60) { 'C' } elseif ($score -ge 40) { 'D' } else { 'F' }
        $criticalFailed = @($failed | Where-Object { $_.Severity -eq 'critical' }).Count -gt 0
        if ($criticalFailed -and @('A', 'B') -contains $grade) { $grade = 'C' }
    }
    $count = { param($status) @($Results | Where-Object { $_.Status -eq $status }).Count }
    $failedBySeverity = [ordered] @{}
    foreach ($severity in $script:HSSeverities) { $failedBySeverity[$severity] = @($failed | Where-Object { $_.Severity -eq $severity }).Count }
    return [pscustomobject] @{
        Score            = $score
        Grade            = $grade
        Passed           = (& $count 'Pass')
        Failed           = (& $count 'Fail')
        Unknown          = (& $count 'Unknown')
        NotApplicable    = (& $count 'NotApplicable')
        FailedBySeverity = $failedBySeverity
    }
}
