@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # HardenScope.ps1 is an interactive entry point: coloured console output is intended
        'PSAvoidUsingWriteHost',
        # New-HSRecord and the test helpers only build objects in memory
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
