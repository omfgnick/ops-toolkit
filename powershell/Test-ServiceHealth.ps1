<#
.SYNOPSIS
    Checks a list of Windows services and optionally restarts the ones that are
    not running.

.DESCRIPTION
    For each service name (given on the command line or read from a file), reports
    the current status. With -AutoRestart, services whose status is not 'Running'
    are started. Supports -WhatIf so restarts can be previewed safely.

.PARAMETER Name
    One or more service names to check. Accepts pipeline input.

.PARAMETER InputFile
    Path to a text file with one service name per line (alternative to -Name).

.PARAMETER AutoRestart
    Attempt to start any service that is not running.

.EXAMPLE
    .\Test-ServiceHealth.ps1 -Name Spooler,W32Time

.EXAMPLE
    .\Test-ServiceHealth.ps1 -InputFile .\services.txt -AutoRestart -WhatIf

.NOTES
    Category: Services
    Ask: -Name | Service name (e.g. W32Time)
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(ValueFromPipeline = $true, Position = 0)]
    [string[]]$Name,

    [string]$InputFile,

    [switch]$AutoRestart,

    # Contrato do toolkit: todo relatorio sabe falar JSON
    [switch]$AsJson
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $names = [System.Collections.Generic.List[string]]::new()
    if ($InputFile) {
        if (-not (Test-Path -LiteralPath $InputFile)) { throw "File not found: $InputFile" }
        Get-Content -LiteralPath $InputFile |
            Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
            ForEach-Object { $names.Add($_.Trim()) }
    }
    $results = [System.Collections.Generic.List[object]]::new()
}

process {
    if ($Name) { $Name | ForEach-Object { $names.Add($_) } }
}

end {
    if ($names.Count -eq 0) { throw "No service names provided. Use -Name or -InputFile." }

    foreach ($svcName in $names) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Warning "Service not found: $svcName"
            $results.Add([pscustomobject]@{ Service = $svcName; Status = 'NotFound'; Action = 'none' })
            continue
        }

        $action = 'none'
        if ($svc.Status -ne 'Running' -and $AutoRestart) {
            if ($PSCmdlet.ShouldProcess($svcName, "Start service (was $($svc.Status))")) {
                try {
                    Start-Service -Name $svcName
                    $svc.Refresh()
                    $action = 'started'
                }
                catch {
                    Write-Warning "Failed to start '$svcName': $($_.Exception.Message)"
                    $action = 'start-failed'
                }
            }
        }

        $results.Add([pscustomobject]@{
            Service = $svcName
            Status  = $svc.Status
            Action  = $action
        })
    }

    # JSON com envelope: o mesmo formato em todos os scripts, e assim
    # quem consome nao precisa adivinhar se veio objeto ou lista. Um
    # ConvertTo-Json direto colapsaria lista de um item em objeto.
    if ($AsJson) {
        [pscustomobject]@{
            script       = 'Test-ServiceHealth'
            kind         = 'service_health'
            hostname     = $env:COMPUTERNAME
            generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            count        = @($results).Count
            items        = @($results)
        } | ConvertTo-Json -Depth 6
        return
    }
    $results
}
