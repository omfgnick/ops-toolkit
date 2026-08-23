<#
.SYNOPSIS
    Runs endpoint health checks and produces a consolidated HTML availability
    report.

.DESCRIPTION
    Checks each target (TCP "host:port" or "http(s)://" URL) for reachability and
    latency, then writes a self-contained HTML report with a summary banner and a
    colour-coded results table. Reuses Test-Endpoints.ps1 from the same folder
    when available; otherwise falls back to a built-in check.

.PARAMETER Target
    One or more targets. Accepts pipeline input.

.PARAMETER InputFile
    Text file with one target per line (alternative to -Target).

.PARAMETER OutputPath
    Path of the HTML report to write. Default: .\uptime-report.html.

.PARAMETER TimeoutSeconds
    Per-request timeout. Default: 10.

.EXAMPLE
    .\New-UptimeReport.ps1 -Target "example.com:443","https://example.com"

.EXAMPLE
    .\New-UptimeReport.ps1 -InputFile .\endpoints.txt -OutputPath .\status.html

.NOTES
    Category: Network
    Ask: -Target | Host to check
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Position = 0)]
    [string[]]$Target,

    [string]$InputFile,

    [string]$OutputPath = '.\uptime-report.html',

    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 10,

    # Contrato do toolkit: todo relatorio sabe falar JSON
    [switch]$AsJson
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $allTargets = [System.Collections.Generic.List[string]]::new()
}

process {
    if ($Target) { $Target | ForEach-Object { $allTargets.Add($_) } }
}

end {
    if ($InputFile) {
        if (-not (Test-Path -LiteralPath $InputFile)) { throw "File not found: $InputFile" }
        Get-Content -LiteralPath $InputFile |
            Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } |
            ForEach-Object { $allTargets.Add($_.Trim()) }
    }
    if ($allTargets.Count -eq 0) { throw "No targets provided. Use -Target or -InputFile." }

    # Prefer the sibling Test-Endpoints.ps1 for the actual checks (DRY).
    $checker = Join-Path $PSScriptRoot 'Test-Endpoints.ps1'
    if (Test-Path -LiteralPath $checker) {
        $results = & $checker -Target $allTargets -TimeoutSeconds $TimeoutSeconds
    }
    else {
        Write-Verbose "Test-Endpoints.ps1 not found; using built-in checker."
        $results = foreach ($t in $allTargets) {
            $ok = $false; $detail = ''
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if ($t -match '^https?://') {
                    $r = Invoke-WebRequest -Uri $t -TimeoutSec $TimeoutSeconds -UseBasicParsing
                    $ok = $true; $detail = "HTTP $($r.StatusCode)"
                }
                elseif ($t -match '^(?<host>[^:]+):(?<port>\d+)$') {
                    $tnc = Test-NetConnection -ComputerName $Matches.host -Port ([int]$Matches.port) -WarningAction SilentlyContinue
                    $ok = [bool]$tnc.TcpTestSucceeded
                    $detail = if ($ok) { 'TCP open' } else { 'TCP closed/filtered' }
                }
                else { $detail = 'Unrecognised target format' }
            }
            catch { $detail = $_.Exception.Message }
            finally { $sw.Stop() }
            [pscustomobject]@{
                Target = $t; Reachable = $ok; Detail = $detail
                LatencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
            }
        }
    }

    $total = @($results).Count
    $up    = @($results | Where-Object { $_.Reachable }).Count
    $down  = $total - $up
    $pct   = if ($total -gt 0) { [math]::Round(($up / $total) * 100, 1) } else { 0 }
    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    Add-Type -AssemblyName System.Web
    $rows = ($results | ForEach-Object {
        $cls = if ($_.Reachable) { 'up' } else { 'down' }
        $state = if ($_.Reachable) { 'UP' } else { 'DOWN' }
        @"
      <tr class="$cls">
        <td>$([System.Web.HttpUtility]::HtmlEncode($_.Target))</td>
        <td class="state">$state</td>
        <td>$([System.Web.HttpUtility]::HtmlEncode([string]$_.Detail))</td>
        <td class="num">$($_.LatencyMs)</td>
      </tr>
"@
    }) -join "`n"

    $bannerClass = if ($down -eq 0) { 'all-up' } else { 'has-down' }

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Uptime Report</title>
<style>
  body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f3f2ef;color:#0f172a}
  .wrap{max-width:900px;margin:0 auto;padding:24px}
  h1{font-size:20px;margin:0 0 4px}
  .meta{color:#475569;font-size:13px;margin-bottom:16px}
  .banner{padding:14px 18px;border-radius:12px;font-weight:700;margin-bottom:18px}
  .all-up{background:#dcfce7;color:#166534}
  .has-down{background:#fee2e2;color:#991b1b}
  table{width:100%;border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 8px 24px rgba(15,23,42,.08)}
  th,td{padding:10px 14px;text-align:left;border-bottom:1px solid #e2e8f0}
  th{background:#0a66c2;color:#fff;font-size:13px}
  td.num,td.state{text-align:center;font-variant-numeric:tabular-nums}
  tr.up .state{color:#166534;font-weight:700}
  tr.down .state{color:#991b1b;font-weight:700}
</style>
</head>
<body>
  <div class="wrap">
    <h1>Uptime Report</h1>
    <div class="meta">Generated $generated</div>
    <div class="banner $bannerClass">$up / $total endpoints up ($pct%) &middot; $down down</div>
    <table>
      <thead><tr><th>Target</th><th>State</th><th>Detail</th><th>Latency (ms)</th></tr></thead>
      <tbody>
$rows
      </tbody>
    </table>
  </div>
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Host "Report written to $OutputPath ($up/$total up, $down down)."
    # JSON com envelope: o mesmo formato em todos os scripts, e assim
    # quem consome nao precisa adivinhar se veio objeto ou lista. Um
    # ConvertTo-Json direto colapsaria lista de um item em objeto.
    if ($AsJson) {
        [pscustomobject]@{
            script       = 'New-UptimeReport'
            kind         = 'uptime'
            hostname     = $env:COMPUTERNAME
            generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            count        = @($results).Count
            items        = @($results)
        } | ConvertTo-Json -Depth 6
        return
    }
    $results
}
