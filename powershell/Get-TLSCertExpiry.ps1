<#
.SYNOPSIS
    Checks the TLS certificate of one or more hosts and reports how many days
    remain until expiry, flagging those expiring soon.

.DESCRIPTION
    Opens a TLS connection to each target, reads the presented server
    certificate, and reports subject, issuer, expiry date and days remaining.
    Certificates expiring within -WarnDays are flagged EXPIRING; already expired
    ones are flagged EXPIRED. Optionally exports to CSV.

.PARAMETER Target
    Host(s) to check as "host" or "host:port". Default port is 443. Accepts
    pipeline input.

.PARAMETER InputFile
    Text file with one target per line (alternative to -Target).

.PARAMETER WarnDays
    Flag certificates expiring within this many days. Default: 30.

.PARAMETER TimeoutSeconds
    Connection timeout per host. Default: 10.

.PARAMETER CsvPath
    If provided, writes the results to this CSV file.

.EXAMPLE
    .\Get-TLSCertExpiry.ps1 -Target github.com,example.com:443

.EXAMPLE
    .\Get-TLSCertExpiry.ps1 -InputFile .\hosts.txt -WarnDays 45 -CsvPath .\certs.csv
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Position = 0)]
    [string[]]$Target,

    [string]$InputFile,

    [ValidateRange(1, 3650)]
    [int]$WarnDays = 30,

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 10,

    [string]$CsvPath
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

    function Get-ServerCertificate {
        param([string]$HostName, [int]$Port, [int]$TimeoutMs)

        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                throw "Connection timed out after $TimeoutMs ms"
            }
            $tcp.EndConnect($iar)

            # Accept any cert here: we are inspecting expiry, not validating trust.
            $ssl = [System.Net.Security.SslStream]::new(
                $tcp.GetStream(), $false, { $true })
            try {
                $ssl.AuthenticateAsClient($HostName)
                return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                    $ssl.RemoteCertificate)
            }
            finally { $ssl.Dispose() }
        }
        finally { $tcp.Dispose() }
    }
}

process {
    if ($Target) { $Target | ForEach-Object { $targets.Add($_) } }
}

end {
    if ($targets.Count -eq 0) { throw "No targets provided. Use -Target or -InputFile." }

    foreach ($t in $targets) {
        $hostName, $portText = $t.Split(':', 2)
        $port = if ($portText) { [int]$portText } else { 443 }

        try {
            $cert = Get-ServerCertificate -HostName $hostName -Port $port `
                -TimeoutMs ($TimeoutSeconds * 1000)
            $daysLeft = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
            $status =
                if ($daysLeft -lt 0)         { 'EXPIRED' }
                elseif ($daysLeft -le $WarnDays) { 'EXPIRING' }
                else                         { 'OK' }

            $results.Add([pscustomobject]@{
                Target    = $t
                Subject   = $cert.Subject
                Issuer    = $cert.Issuer
                NotAfter  = $cert.NotAfter
                DaysLeft  = $daysLeft
                Status    = $status
            })
        }
        catch {
            $results.Add([pscustomobject]@{
                Target    = $t
                Subject   = $null
                Issuer    = $null
                NotAfter  = $null
                DaysLeft  = $null
                Status    = "ERROR: $($_.Exception.Message)"
            })
        }
    }

    if ($CsvPath) {
        $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Verbose "CSV written to $CsvPath"
    }

    $results
}
