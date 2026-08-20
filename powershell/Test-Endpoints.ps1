<#
.SYNOPSIS
    Health-checks a list of endpoints (TCP host:port and/or HTTP/HTTPS URLs) and
    reports reachability, status and latency.

.DESCRIPTION
    Each target is checked as follows:
      * "host:port"           -> TCP connect test (Test-NetConnection).
      * "http(s)://..."       -> HTTP request; reports the returned status code.
    Round-trip time is measured for every target. Results are returned as objects
    and can optionally be exported to CSV.

.PARAMETER Target
    One or more targets. Accepts pipeline input. Examples:
      "example.com:443", "https://example.com", "10.0.0.5:22"

.PARAMETER InputFile
    Path to a text file with one target per line (alternative to -Target).

.PARAMETER TimeoutSeconds
    Per-request timeout for HTTP checks. Default: 10.

.PARAMETER CsvPath
    If provided, writes the results to this CSV file.

.EXAMPLE
    .\Test-Endpoints.ps1 -Target "example.com:443","https://example.com"

.EXAMPLE
    .\Test-Endpoints.ps1 -InputFile .\endpoints.txt -CsvPath .\health.csv
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Position = 0)]
    [string[]]$Target,

    [string]$InputFile,

    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 10,

    [string]$CsvPath,

    # Contrato do toolkit: todo relatorio sabe falar JSON
    [switch]$AsJson
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $targets = [System.Collections.Generic.List[string]]::new()
    if ($InputFile) {
        if (-not (Test-Path -LiteralPath $InputFile)) { throw "File not found: $InputFile" }
        Get-Content -LiteralPath $InputFile |
            Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
            ForEach-Object { $targets.Add($_.Trim()) }
    }
    $results = [System.Collections.Generic.List[object]]::new()
}

process {
    if ($Target) { $Target | ForEach-Object { $targets.Add($_) } }
}

end {
    if ($targets.Count -eq 0) { throw "No targets provided. Use -Target or -InputFile." }

    foreach ($t in $targets) {
        $ok = $false
        $detail = ''
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            if ($t -match '^https?://') {
                $resp = Invoke-WebRequest -Uri $t -TimeoutSec $TimeoutSeconds -UseBasicParsing
                $ok = $true
                $detail = "HTTP $($resp.StatusCode)"
            }
            elseif ($t -match '^(?<host>[^:]+):(?<port>\d+)$') {
                $tnc = Test-NetConnection -ComputerName $Matches.host -Port ([int]$Matches.port) `
                    -WarningAction SilentlyContinue
                $ok = [bool]$tnc.TcpTestSucceeded
                $detail = if ($ok) { "TCP open" } else { "TCP closed/filtered" }
            }
            else {
                $detail = "Unrecognised target format"
            }
        }
        catch {
            # Invoke-WebRequest throws on non-2xx/timeout; capture status if present.
            $status = $null
            if ($_.Exception.PSObject.Properties.Match('Response').Count -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            $detail = if ($status) { "HTTP $status" } else { $_.Exception.Message }
        }
        finally {
            $sw.Stop()
        }

        $results.Add([pscustomobject]@{
            Target    = $t
            Reachable = $ok
            Detail    = $detail
            LatencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
        })
    }

    if ($CsvPath) {
        $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Verbose "CSV written to $CsvPath"
    }

    # JSON com envelope: o mesmo formato em todos os scripts, e assim
    # quem consome nao precisa adivinhar se veio objeto ou lista. Um
    # ConvertTo-Json direto colapsaria lista de um item em objeto.
    if ($AsJson) {
        [pscustomobject]@{
            script       = 'Test-Endpoints'
            kind         = 'endpoints'
            hostname     = $env:COMPUTERNAME
            generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            count        = @($results).Count
            items        = @($results)
        } | ConvertTo-Json -Depth 6
        return
    }
    $results
}
