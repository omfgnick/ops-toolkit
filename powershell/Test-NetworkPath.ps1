<#
.SYNOPSIS
    Measures reachability and latency to a set of hosts and optionally checks
    TCP ports, flagging loss or latency above a threshold.

.DESCRIPTION
    Built for link and carrier monitoring in a NOC routine: pings each host,
    reports packet loss and average round-trip time, and can also test whether
    specific TCP ports answer. Windows counterpart of bash/net-monitor.sh.

    Read-only: this script never changes anything.

    Exit code is 1 when any host loses packets, exceeds the latency threshold or
    has a closed port, 0 otherwise.

.PARAMETER Target
    One or more hosts (name or IP). Accepts pipeline input.

.PARAMETER InputFile
    Text file with one host per line; '#' starts a comment.

.PARAMETER Count
    Pings per host. Default: 4.

.PARAMETER LatencyMs
    Average round-trip time, in milliseconds, above which a host is flagged.
    Default: 150.

.PARAMETER Port
    One or more TCP ports to test on every host.

.PARAMETER AsJson
    Emit JSON instead of a table.

.EXAMPLE
    .\Test-NetworkPath.ps1 -Target 8.8.8.8, 1.1.1.1

.EXAMPLE
    .\Test-NetworkPath.ps1 -InputFile .\links.txt -LatencyMs 80 -Port 443

.EXAMPLE
    .\Test-NetworkPath.ps1 -Target gateway.local -AsJson | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, Position = 0)]
    [string[]]$Target,

    [string]$InputFile,

    [ValidateRange(1, 100)]
    [int]$Count = 4,

    [ValidateRange(1, 60000)]
    [int]$LatencyMs = 150,

    [int[]]$Port,

    [switch]$AsJson
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $hosts = [System.Collections.Generic.List[string]]::new()
}

process {
    foreach ($t in $Target) { if ($t) { $hosts.Add($t) } }
}

end {
    if ($InputFile) {
        if (-not (Test-Path -LiteralPath $InputFile)) { throw "Input file not found: $InputFile" }
        Get-Content -LiteralPath $InputFile | ForEach-Object {
            $line = ($_ -split '#')[0].Trim()
            if ($line) { $hosts.Add($line) }
        }
    }

    if ($hosts.Count -eq 0) { throw 'No target given. Use -Target or -InputFile.' }

    $problems = 0
    $results = foreach ($h in $hosts) {
        $replies = @()
        try {
            $replies = @(Test-Connection -ComputerName $h -Count $Count -ErrorAction Stop)
        }
        catch {
            Write-Verbose "Ping failed for ${h}: $($_.Exception.Message)"
        }

        $received = $replies.Count
        $loss = [int]((($Count - $received) / $Count) * 100)

        # The latency property differs between Windows PowerShell (CIM object)
        # and PowerShell 7 (PingReply), so try both rather than assume.
        $avg = $null
        if ($received -gt 0) {
            $times = $replies | ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'ResponseTime') { $_.ResponseTime }
                elseif ($_.PSObject.Properties.Name -contains 'Latency') { $_.Latency }
                else { $null }
            } | Where-Object { $null -ne $_ }
            if ($times) { $avg = [math]::Round(($times | Measure-Object -Average).Average, 1) }
        }

        $status = 'ok'
        if ($loss -ge 100) { $status = 'unreachable' }
        elseif ($loss -gt 0) { $status = 'packet-loss' }
        elseif ($null -ne $avg -and $avg -gt $LatencyMs) { $status = 'high-latency' }
        if ($status -ne 'ok') { $problems++ }

        [pscustomobject]@{
            Host        = $h
            LossPercent = $loss
            AvgMs       = $avg
            Status      = $status
        }
    }

    $portResults = @()
    if ($Port) {
        $portResults = foreach ($h in $hosts) {
            foreach ($p in $Port) {
                $open = $false
                try {
                    $open = (Test-NetConnection -ComputerName $h -Port $p -WarningAction SilentlyContinue -ErrorAction Stop).TcpTestSucceeded
                }
                catch {
                    Write-Verbose "Port test failed for ${h}:${p}: $($_.Exception.Message)"
                }
                if (-not $open) { $problems++ }
                [pscustomobject]@{
                    Host  = $h
                    Port  = $p
                    State = if ($open) { 'open' } else { 'closed' }
                }
            }
        }
    }

    if ($AsJson) {
        [pscustomobject]@{
            pings                = $Count
            latency_threshold_ms = $LatencyMs
            problems             = $problems
            hosts                = @($results)
            ports                = @($portResults)
        } | ConvertTo-Json -Depth 4
    }
    else {
        $results | Format-Table -AutoSize Host, LossPercent, AvgMs, Status | Out-String | Write-Output
        if ($portResults) {
            $portResults | Format-Table -AutoSize Host, Port, State | Out-String | Write-Output
        }
        Write-Output "Checked $($hosts.Count) host(s); $problems problem(s)."
    }

    if ($problems -gt 0) { exit 1 }
    exit 0
}
