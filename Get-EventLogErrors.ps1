<#
.SYNOPSIS
    Collects Error/Warning events from Windows event logs over a recent time
    window and summarises them by source.

.DESCRIPTION
    Queries the given logs (System, Application by default) for events at the
    chosen severity levels within the last -Hours hours, then returns a summary
    grouped by log/source/level. Use -Detailed to return the individual events
    instead of the summary. Optionally exports to CSV.

.PARAMETER LogName
    One or more event logs to query. Default: System, Application.

.PARAMETER Hours
    Look-back window in hours. Default: 24.

.PARAMETER Level
    Severity levels to include: Error, Warning, or both. Default: both.

.PARAMETER Detailed
    Return individual events (time, source, id, message) instead of the summary.

.PARAMETER CsvPath
    If provided, writes the output to this CSV file.

.EXAMPLE
    .\Get-EventLogErrors.ps1 -Hours 12

.EXAMPLE
    .\Get-EventLogErrors.ps1 -LogName System -Level Error -Detailed -CsvPath .\errors.csv
#>
[CmdletBinding()]
param(
    [string[]]$LogName = @('System', 'Application'),

    [ValidateRange(1, 8760)]
    [int]$Hours = 24,

    [ValidateSet('Error', 'Warning')]
    [string[]]$Level = @('Error', 'Warning'),

    [switch]$Detailed,

    [string]$CsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# FilterHashtable uses numeric levels: 2 = Error, 3 = Warning.
$levelMap = @{ Error = 2; Warning = 3 }
$levelNumbers = $Level | ForEach-Object { $levelMap[$_] }
$startTime = (Get-Date).AddHours(-$Hours)

$events = [System.Collections.Generic.List[object]]::new()
foreach ($log in $LogName) {
    try {
        Get-WinEvent -FilterHashtable @{
            LogName   = $log
            Level     = $levelNumbers
            StartTime = $startTime
        } -ErrorAction Stop | ForEach-Object { $events.Add($_) }
    }
    catch [System.Exception] {
        # "No events were found" is expected and not an error worth surfacing.
        if ($_.Exception.Message -notmatch 'No events were found') {
            Write-Warning "Could not read log '$log': $($_.Exception.Message)"
        }
    }
}

if ($events.Count -eq 0) {
    Write-Host "No matching events in the last $Hours hour(s)."
    return
}

if ($Detailed) {
    $output = $events | Sort-Object TimeCreated -Descending | ForEach-Object {
        [pscustomobject]@{
            Time    = $_.TimeCreated
            Log     = $_.LogName
            Level   = $_.LevelDisplayName
            Source  = $_.ProviderName
            EventId = $_.Id
            Message = ($_.Message -replace '\s+', ' ').Trim()
        }
    }
}
else {
    $output = $events |
        Group-Object LogName, ProviderName, LevelDisplayName |
        ForEach-Object {
            [pscustomobject]@{
                Log     = $_.Group[0].LogName
                Source  = $_.Group[0].ProviderName
                Level   = $_.Group[0].LevelDisplayName
                Count   = $_.Count
                LastSeen = ($_.Group | Sort-Object TimeCreated -Descending)[0].TimeCreated
            }
        } | Sort-Object Count -Descending
}

if ($CsvPath) {
    $output | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Verbose "CSV written to $CsvPath"
}

$output
