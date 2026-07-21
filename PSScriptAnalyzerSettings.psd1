@{
    # Run every default rule...
    IncludeDefaultRules = $true

    # ...except the ones below.
    ExcludeRules = @(
        # These scripts return objects on the success pipeline and print
        # human-facing status/summary lines with Write-Host on purpose, so the
        # status text does not pollute the object output (which would break
        # `... | Export-Csv`, `... | Where-Object`, etc.). Write-Host is the
        # correct tool for that here, so this rule is intentionally disabled.
        'PSAvoidUsingWriteHost'
    )
}
