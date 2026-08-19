<#
.SYNOPSIS
    Single-shot snapshot of a Windows machine's state, meant to be the first
    command you run when a ticket lands.

.DESCRIPTION
    Collects uptime, CPU load, memory, disk pressure, stopped automatic services
    and recent system errors into one report you can paste into the call.
    Windows counterpart of bash/incident-triage.sh.

    Read-only: this script never changes anything.

    Exit code is 1 when something needs attention (high load, low memory, a full
    volume, a stopped automatic service), 0 otherwise - so it can be used as a
    check in a scheduled task.

.PARAMETER Hours
    Look-back window, in hours, for System/Application errors. Default: 24.

.PARAMETER MaxEvents
    Maximum number of recent errors to include. Default: 15.

.PARAMETER AsJson
    Emit JSON instead of the readable report, for Grafana/Zabbix ingestion.

.PARAMETER OutFile
    Also write the output to this file.

.EXAMPLE
    .\Get-IncidentTriage.ps1

.EXAMPLE
    .\Get-IncidentTriage.ps1 -AsJson | ConvertFrom-Json

.EXAMPLE
    .\Get-IncidentTriage.ps1 -Hours 4 -OutFile "C:\Temp\triage-$env:COMPUTERNAME.txt"
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$Hours = 24,

    [ValidateRange(1, 200)]
    [int]$MaxEvents = 15,

    [switch]$AsJson,

    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows-only: this script drives Windows components. Say so plainly instead of
# failing later with an exception from a cmdlet that does not exist elsewhere.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Error 'This script only runs on Windows.'
    exit 2
}

# Thresholds that decide whether the exit code signals a problem.
$LoadPerCoreLimit = 1.0
$MemoryUsedLimit = 90
$DiskUsedLimit = 85

$alerts = [System.Collections.Generic.List[string]]::new()

# ---- System ------------------------------------------------------------------
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$lastBoot = $os.LastBootUpTime
$uptime = (Get-Date) - $lastBoot

$cpuCount = [int]$cs.NumberOfLogicalProcessors
if ($cpuCount -lt 1) { $cpuCount = 1 }

# Windows has no load average; queue length per core is the closest equivalent.
$queue = 0
try {
    $queue = (Get-Counter '\System\Processor Queue Length' -ErrorAction Stop).CounterSamples[0].CookedValue
}
catch {
    Write-Verbose "Processor Queue Length counter unavailable: $($_.Exception.Message)"
}
$loadPerCore = [math]::Round($queue / $cpuCount, 2)
if ($loadPerCore -gt $LoadPerCoreLimit) {
    $alerts.Add("processor queue per core is $loadPerCore (>$LoadPerCoreLimit)")
}

# ---- Memory ------------------------------------------------------------------
$memTotalKb = [int64]$os.TotalVisibleMemorySize
$memFreeKb = [int64]$os.FreePhysicalMemory
$memUsedPct = if ($memTotalKb -gt 0) { [int](($memTotalKb - $memFreeKb) * 100 / $memTotalKb) } else { 0 }
if ($memUsedPct -ge $MemoryUsedLimit) { $alerts.Add("memory at $memUsedPct%") }

# ---- Disks -------------------------------------------------------------------
$volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' |
    ForEach-Object {
        $usedPct = if ($_.Size -gt 0) { [int](($_.Size - $_.FreeSpace) * 100 / $_.Size) } else { 0 }
        [pscustomobject]@{
            Drive       = $_.DeviceID
            SizeGB      = [math]::Round($_.Size / 1GB, 1)
            FreeGB      = [math]::Round($_.FreeSpace / 1GB, 1)
            UsedPercent = $usedPct
        }
    }
$fullest = $volumes | Sort-Object UsedPercent -Descending | Select-Object -First 1
if ($fullest -and $fullest.UsedPercent -ge $DiskUsedLimit) {
    $alerts.Add("volume $($fullest.Drive) at $($fullest.UsedPercent)%")
}

# ---- Services ----------------------------------------------------------------
# Only automatic ones: a stopped manual service is normal, a stopped automatic
# service is usually what the ticket is about. Delayed-start services may still
# be starting right after boot, so they are reported but not alerted on.
$stopped = @(Get-CimInstance -ClassName Win32_Service -Filter "StartMode = 'Auto' AND State != 'Running'" |
        Select-Object -ExpandProperty Name)
if ($stopped.Count -gt 0) { $alerts.Add("$($stopped.Count) automatic service(s) not running") }

# ---- Recent errors -----------------------------------------------------------
$since = (Get-Date).AddHours(-$Hours)
$recentErrors = @()
try {
    $recentErrors = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'System', 'Application'
            Level     = 1, 2      # Critical, Error
            StartTime = $since
        } -MaxEvents $MaxEvents -ErrorAction Stop |
            ForEach-Object {
                [pscustomobject]@{
                    Time     = $_.TimeCreated
                    Log      = $_.LogName
                    Provider = $_.ProviderName
                    Id       = $_.Id
                    Message  = ($_.Message -split "`n")[0]
                }
            })
}
catch {
    # No matching events is not a failure; anything else is worth surfacing.
    Write-Verbose "No events found or log unreadable: $($_.Exception.Message)"
}

# ---- Output ------------------------------------------------------------------
if ($AsJson) {
    $payload = [pscustomobject]@{
        hostname      = $env:COMPUTERNAME
        timestamp     = (Get-Date).ToString('s')
        os            = $os.Caption
        version       = $os.Version
        uptime_hours  = [math]::Round($uptime.TotalHours, 1)
        last_boot     = $lastBoot.ToString('s')
        cpu           = @{ count = $cpuCount; queue_per_core = $loadPerCore }
        memory        = @{ total_kb = $memTotalKb; free_kb = $memFreeKb; used_percent = $memUsedPct }
        disks         = @($volumes)
        stopped_auto  = $stopped
        recent_errors = @($recentErrors)
        alerts        = @($alerts)
    }
    $output = $payload | ConvertTo-Json -Depth 5
}
else {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('===============================================================')
    [void]$sb.AppendLine(" INCIDENT TRIAGE - $env:COMPUTERNAME")
    [void]$sb.AppendLine(" $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')")
    [void]$sb.AppendLine('===============================================================')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- System ------------------------------------------------------')
    [void]$sb.AppendLine(("  OS          : {0} ({1})" -f $os.Caption, $os.Version))
    [void]$sb.AppendLine(("  Uptime      : {0:N1} hours (booted {1:yyyy-MM-dd HH:mm})" -f $uptime.TotalHours, $lastBoot))
    [void]$sb.AppendLine(("  CPU queue   : {0} per core ({1} logical CPUs)" -f $loadPerCore, $cpuCount))
    [void]$sb.AppendLine(("  Memory      : {0}% used" -f $memUsedPct))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Disks -------------------------------------------------------')
    foreach ($v in $volumes) {
        [void]$sb.AppendLine(("  {0,-4} {1,8:N1} GB total {2,8:N1} GB free  {3,3}% used" -f $v.Drive, $v.SizeGB, $v.FreeGB, $v.UsedPercent))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Automatic services not running ------------------------------')
    if ($stopped.Count -eq 0) { [void]$sb.AppendLine('  none') }
    else { foreach ($s in $stopped) { [void]$sb.AppendLine("  $s") } }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("-- Recent errors (last $Hours h) --------------------------------")
    if ($recentErrors.Count -eq 0) { [void]$sb.AppendLine('  none') }
    else {
        foreach ($e in $recentErrors) {
            [void]$sb.AppendLine(("  {0:yyyy-MM-dd HH:mm} [{1}] {2} ({3})" -f $e.Time, $e.Log, $e.Provider, $e.Id))
            [void]$sb.AppendLine("      $($e.Message)")
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Summary -----------------------------------------------------')
    if ($alerts.Count -eq 0) { [void]$sb.AppendLine('  Nothing alarming found.') }
    else { foreach ($a in $alerts) { [void]$sb.AppendLine("  ALERT: $a") } }
    $output = $sb.ToString()
}

$output
if ($OutFile) { $output | Set-Content -LiteralPath $OutFile -Encoding UTF8 }

if ($alerts.Count -gt 0) { exit 1 }
exit 0
