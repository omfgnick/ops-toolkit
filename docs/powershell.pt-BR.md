# PowerShell Scripts

**Português (BR)** · [English](powershell.en.md)

Cada entrada abaixo é a ajuda do próprio script — a mesma que o `Get-Help` mostra, em inglês — para que esta página não possa descrever um script de forma diferente do script. Gerada por [`tools/gen-docs.sh`](../tools/gen-docs.sh); edite o cabeçalho do script, não este arquivo.

## Scripts

### `Audit-LocalUsers.ps1`

Audits local user accounts for common hardening findings.

```
.SYNOPSIS
Audits local user accounts for common hardening findings.

.DESCRIPTION
Lists local users with their enabled state, password-expiry setting and last
logon, and highlights potential issues: enabled accounts whose password
never expires, members of the local Administrators group, and accounts that
have never logged on. Also lists the current Administrators membership.
Read-only. Optionally exports the user table to CSV.

.PARAMETER CsvPath
If provided, writes the user table to this CSV file.

.EXAMPLE
.\Audit-LocalUsers.ps1

.EXAMPLE
.\Audit-LocalUsers.ps1 -CsvPath .\localusers.csv -Verbose
```

### `Cleanup-TempFiles.ps1`

Cleans temporary files and reports how much disk space was reclaimed.

```
.SYNOPSIS
Cleans temporary files and reports how much disk space was reclaimed.

.DESCRIPTION
Removes files older than -OlderThanDays from a set of temporary locations
(user TEMP, Windows Temp, and per-user Internet cache by default). Measures
the space freed. Defaults to a preview: nothing is deleted unless -Execute
is supplied. Honours -WhatIf and -Confirm.

.PARAMETER Path
One or more folders to clean. If omitted, a safe default set is used:
$env:TEMP, C:\Windows\Temp, and the Internet cache.

.PARAMETER OlderThanDays
Only remove files last modified more than this many days ago. Default: 7.

.PARAMETER Execute
Actually delete files. Without it, the script only reports what WOULD be
removed (dry run).

.EXAMPLE
.\Cleanup-TempFiles.ps1                 # dry run against default locations

.EXAMPLE
.\Cleanup-TempFiles.ps1 -OlderThanDays 3 -Execute
```

### `Get-DiskSpaceReport.ps1`

Reports fixed-disk usage for one or more machines and flags volumes below a free-space threshold.

```
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
```

### `Get-EventLogErrors.ps1`

Collects Error/Warning events from Windows event logs over a recent time window and summarises them by source.

```
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
```

### `Get-IncidentTriage.ps1`

Single-shot snapshot of a Windows machine's state, meant to be the first command you run when a ticket lands.

```
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
```

### `Get-OpenPorts.ps1`

Lists local TCP ports together with the owning process.

```
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
```

### `Get-PendingUpdate.ps1`

Reports pending Windows updates, pending winget upgrades and whether the machine is waiting for a reboot.

```
.SYNOPSIS
Reports pending Windows updates, pending winget upgrades and whether the
machine is waiting for a reboot.

.DESCRIPTION
Read-only. This script never installs, downloads or applies anything: it
only asks Windows Update what it would offer.

The value here is not the count of updates. It is the two things that make
a machine look healthy while it is not:

  - a reboot that never happened, so patches are installed but not active
  - a Windows Update service that has not talked to its source in weeks,
    so "0 pending" means "nobody asked", not "nothing missing"

Both are reported explicitly instead of being folded into a single number.

The search talks to whatever source the machine is configured to use
(Microsoft Update or an internal WSUS), takes a while on the first run of
the day, and needs the network. When it cannot run, the script says so and
still reports the reboot state, which is local and always available.

.PARAMETER IncludeHidden
Also count updates an administrator hid. Hidden updates are excluded by
default because someone decided they should not be offered.

.PARAMETER SkipWindowsUpdate
Skip the Windows Update query and report only the reboot state and winget.
Useful on a machine with no network, where the search would just hang.

.PARAMETER StaleDays
Consider the last successful search stale after this many days. Default 7.

.PARAMETER AsJson
Emit JSON instead of the readable report.

.EXAMPLE
.\Get-PendingUpdate.ps1

Prints the readable report.

.EXAMPLE
.\Get-PendingUpdate.ps1 -AsJson | ConvertFrom-Json | Select-Object -Expand pendingCount

Feeds a monitoring system.

.EXAMPLE
.\Get-PendingUpdate.ps1 -SkipWindowsUpdate

Answers "is this machine waiting for a reboot" without touching the network.

.NOTES
Part of ops-toolkit. Exit codes: 0 nothing pending, 1 updates or a reboot
pending, 2 the update search could not run.
```

### `Get-SecurityAudit.ps1`

Read-only security review of a Windows host: local accounts, administrators, password policy, firewall profiles, SMBv1, RDP exposure and listening ports.

```
.SYNOPSIS
Read-only security review of a Windows host: local accounts, administrators,
password policy, firewall profiles, SMBv1, RDP exposure and listening ports.

.DESCRIPTION
Windows counterpart of bash/audit-hardening.sh. Reports only - it never
changes a setting, so it is safe to run in production.

Findings are advisory and carry a severity: review each one in context
before acting. Only 'high' and 'medium' change the exit code; 'info'
entries are notes, including checks that were skipped for lack of
privilege.

This is not a CIS benchmark. It flags the handful of things that most often
explain an incident, and says clearly what it could not inspect.

.PARAMETER AsJson
Emit JSON instead of the readable report.

.PARAMETER OutFile
Also write the output to this file.

.EXAMPLE
.\Get-SecurityAudit.ps1

.EXAMPLE
.\Get-SecurityAudit.ps1 -AsJson | ConvertFrom-Json | Select-Object -ExpandProperty findings
```

### `Get-TLSCertExpiry.ps1`

Checks the TLS certificate of one or more hosts and reports how many days remain until expiry, flagging those expiring soon.

```
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
```

### `New-UptimeReport.ps1`

Runs endpoint health checks and produces a consolidated HTML availability report.

```
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
```

### `Repair-CommonIssues.ps1`

Applies the repairs a support desk performs most often: print spooler, Windows Update components, network stack and user caches.

```
.SYNOPSIS
Applies the repairs a support desk performs most often: print spooler,
Windows Update components, network stack and user caches.

.DESCRIPTION
These are the fixes that get repeated every week, each one a sequence of
commands that is easy to get wrong under pressure. Grouping them means the
same steps run the same way every time, and the report says what actually
changed.

Nothing runs unless asked for: pick the repairs with -Repair, and see what
would happen first with -WhatIf. Every action goes through ShouldProcess, so
-WhatIf and -Confirm behave as expected.

Needs administrator rights for everything except UserCache.

.PARAMETER Repair
Which repairs to run:
  Spooler       - clears the stuck print queue and restarts the spooler
  WindowsUpdate - stops the services, renames SoftwareDistribution, restarts
  Network       - flushes DNS, renews the lease, resets winsock
  UserCache     - clears Teams and Outlook caches for the current user
  All           - every one of the above

.PARAMETER AsJson
Emit JSON instead of the readable report.

.EXAMPLE
.\Repair-CommonIssues.ps1 -Repair Spooler -WhatIf

.EXAMPLE
.\Repair-CommonIssues.ps1 -Repair Spooler, Network

.EXAMPLE
.\Repair-CommonIssues.ps1 -Repair All -Confirm:$false
```

### `Rotate-Logs.ps1`

Rotates log files: compresses logs older than a threshold and deletes archives past a retention period.

```
.SYNOPSIS
Rotates log files: compresses logs older than a threshold and deletes
archives past a retention period.

.DESCRIPTION
Finds files under -Path matching -Filter whose LastWriteTime is older than
-CompressAfterDays, compresses each into "<name>.zip" and removes the
original. Existing .zip archives older than -DeleteAfterDays are removed.
Old archives are pruned BEFORE new ones are created, so a freshly written
archive is never deleted in the same run. Supports -WhatIf.

.PARAMETER Path
Root folder containing the logs (processed recursively).

.PARAMETER Filter
Wildcard filter for log files to rotate. Default: *.log.

.PARAMETER CompressAfterDays
Compress logs older than this many days. Default: 7.

.PARAMETER DeleteAfterDays
Delete .zip archives older than this many days. Default: 90.

.EXAMPLE
.\Rotate-Logs.ps1 -Path C:\inetpub\logs -CompressAfterDays 7 -DeleteAfterDays 60

.EXAMPLE
.\Rotate-Logs.ps1 -Path C:\Logs -Filter *.txt -WhatIf
```

### `Test-Endpoints.ps1`

Health-checks a list of endpoints (TCP host:port and/or HTTP/HTTPS URLs) and reports reachability, status and latency.

```
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
```

### `Test-NetworkPath.ps1`

Measures reachability and latency to a set of hosts and optionally checks TCP ports, flagging loss or latency above a threshold.

```
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
```

### `Test-ServiceHealth.ps1`

Checks a list of Windows services and optionally restarts the ones that are not running.

```
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
```

### `backup-folder.ps1`

Compressed backup of a folder with integrity check and optional e-mail notification.

```
.SYNOPSIS
Compressed backup of a folder with integrity check and optional e-mail
notification. PowerShell port of the Bash backup-folder script.

.PARAMETER SourcePath
Directory to back up.

.PARAMETER DestinationPath
Directory where the .zip backup is written (created if missing).

.PARAMETER SmtpServer
SMTP server for notification. If omitted, e-mail is skipped.

.PARAMETER MailTo
Recipient of the status e-mail.

.PARAMETER MailFrom
Sender address for the status e-mail.

.EXAMPLE
.\backup-folder.ps1 -SourcePath "C:\Data" -DestinationPath "D:\Backups"

.EXAMPLE
.\backup-folder.ps1 -SourcePath "C:\Data" -DestinationPath "D:\Backups" `
    -SmtpServer smtp.example.com -MailTo ops@example.com -MailFrom backup@example.com
```

### `backup_retention.ps1`

Archives files older than a retention window into per-file .

```
.SYNOPSIS
Archives files older than a retention window into per-file .zip files and
removes archives that are past the retention period.

.DESCRIPTION
For every file under -FolderPath whose LastWriteTime is older than
-DaysToKeep, the file is compressed to "<name>.zip" and the original is
removed. Previously created .zip archives that are themselves older than the
retention window are deleted.

.PARAMETER FolderPath
Root folder to process (recursively).

.PARAMETER DaysToKeep
Age in days. Files/archives older than this are acted upon. Default: 30.

.EXAMPLE
.\backup_retention.ps1 -FolderPath "C:\Logs" -DaysToKeep 30

.EXAMPLE
.\backup_retention.ps1 -FolderPath "C:\Logs" -WhatIf
```

