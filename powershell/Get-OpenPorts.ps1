<#
.SYNOPSIS
    Lists local TCP ports together with the owning process. Windows counterpart
    to the Bash portscan helper (local inspection, not a remote scanner).

.DESCRIPTION
    Enumerates TCP connections via Get-NetTCPConnection and joins each entry with
    its owning process (name and path). By default only listening sockets are
    shown; use -State to widen the view. Results can be exported to CSV.

.PARAMETER State
    TCP state(s) to include. Default: Listen. Use 'All' for every state.

.PARAMETER Port
    Optional filter: only show these local ports.

.PARAMETER CsvPath
    If provided, writes the results to this CSV file.

.EXAMPLE
    .\Get-OpenPorts.ps1

.EXAMPLE
    .\Get-OpenPorts.ps1 -State Established -Port 443,3389 -CsvPath .\ports.csv
#>
[CmdletBinding()]
param(
    [ValidateSet('Listen', 'Established', 'TimeWait', 'CloseWait', 'All')]
    [string[]]$State = @('Listen'),

    [int[]]$Port,

    [string]$CsvPath,

    # Contrato do toolkit: todo relatorio sabe falar JSON
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$connections = Get-NetTCPConnection
if ($State -notcontains 'All') {
    $connections = $connections | Where-Object { $State -contains $_.State }
}
if ($Port) {
    $connections = $connections | Where-Object { $Port -contains $_.LocalPort }
}

# Cache process lookups so we don't call Get-Process once per connection.
$procCache = @{}
$results = foreach ($conn in $connections) {
    $pidValue = $conn.OwningProcess
    if (-not $procCache.ContainsKey($pidValue)) {
        $procCache[$pidValue] = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    }
    $proc = $procCache[$pidValue]

    [pscustomobject]@{
        LocalAddress  = $conn.LocalAddress
        LocalPort     = $conn.LocalPort
        RemoteAddress = $conn.RemoteAddress
        RemotePort    = $conn.RemotePort
        State         = $conn.State
        PID           = $pidValue
        Process       = if ($proc) { $proc.ProcessName } else { '(unknown)' }
        Path          = if ($proc) { $proc.Path } else { $null }
    }
}

$results = $results | Sort-Object LocalPort

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Verbose "CSV written to $CsvPath"
}

# JSON com envelope: o mesmo formato em todos os scripts, e assim
# quem consome nao precisa adivinhar se veio objeto ou lista. Um
# ConvertTo-Json direto colapsaria lista de um item em objeto.
if ($AsJson) {
    [pscustomobject]@{
        script       = 'Get-OpenPorts'
        kind         = 'open_ports'
        hostname     = $env:COMPUTERNAME
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        count        = @($results).Count
        items        = @($results)
    } | ConvertTo-Json -Depth 6
    return
}
$results
