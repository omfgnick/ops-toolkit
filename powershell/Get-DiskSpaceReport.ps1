<#
.SYNOPSIS
    Reports fixed-disk usage for one or more machines and flags volumes below a
    free-space threshold.

.DESCRIPTION
    Queries fixed local disks (DriveType 3) via CIM and returns size, free space
    and percentage free for each volume. Volumes at or below -ThresholdPercent
    are marked as LOW. Optionally exports the result to CSV or HTML.

.PARAMETER ComputerName
    One or more computers to query. Default: the local machine.

.PARAMETER ThresholdPercent
    Free-space percentage at or below which a volume is flagged LOW. Default: 15.

.PARAMETER CsvPath
    If provided, writes the report to this CSV file.

.PARAMETER HtmlPath
    If provided, writes the report to this HTML file.

.EXAMPLE
    .\Get-DiskSpaceReport.ps1

.EXAMPLE
    .\Get-DiskSpaceReport.ps1 -ComputerName SRV01,SRV02 -ThresholdPercent 10 -HtmlPath .\disk.html
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [ValidateRange(1, 99)]
    [int]$ThresholdPercent = 15,

    [string]$CsvPath,
    [string]$HtmlPath,

    # Contrato do toolkit: todo relatorio sabe falar JSON
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$localNames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1', '.', '::1')

$report = foreach ($computer in $ComputerName) {
    try {
        # For the local machine, query without -ComputerName so CIM uses a local
        # session (DCOM) instead of requiring WinRM/WS-Man to be configured.
        if ($localNames -contains $computer) {
            $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3'
        }
        else {
            $disks = Get-CimInstance -ClassName Win32_LogicalDisk `
                -Filter 'DriveType=3' -ComputerName $computer
        }
    }
    catch {
        Write-Warning "Could not query '$computer': $($_.Exception.Message)"
        continue
    }

    foreach ($disk in $disks) {
        $pctFree = if ($disk.Size -gt 0) {
            [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
        } else { 0 }

        [pscustomobject]@{
            Computer   = $computer
            Drive      = $disk.DeviceID
            SizeGB     = [math]::Round($disk.Size / 1GB, 1)
            FreeGB     = [math]::Round($disk.FreeSpace / 1GB, 1)
            PercentFree = $pctFree
            Status     = if ($pctFree -le $ThresholdPercent) { 'LOW' } else { 'OK' }
        }
    }
}

if (-not $report) {
    Write-Warning "No fixed disks reported."
    return
}

if ($CsvPath) {
    $report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Verbose "CSV written to $CsvPath"
}

if ($HtmlPath) {
    $style = '<style>body{font-family:Segoe UI,Arial}table{border-collapse:collapse}' +
             'th,td{border:1px solid #ccc;padding:6px 10px}th{background:#0a66c2;color:#fff}</style>'
    $report | ConvertTo-Html -Title 'Disk Space Report' -Head $style |
        Out-File -FilePath $HtmlPath -Encoding UTF8
    Write-Verbose "HTML written to $HtmlPath"
}

# JSON com envelope: o mesmo formato em todos os scripts, e assim
# quem consome nao precisa adivinhar se veio objeto ou lista. Um
# ConvertTo-Json direto colapsaria lista de um item em objeto.
if ($AsJson) {
    [pscustomobject]@{
        script       = 'Get-DiskSpaceReport'
        kind         = 'disk_space'
        hostname     = $env:COMPUTERNAME
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        count        = @($report).Count
        items        = @($report)
    } | ConvertTo-Json -Depth 6
    return
}
$report
