# PowerShell Scripts

**English** · [Português (BR)](README.pt-BR.md)

[![Lint](https://github.com/omfgnick/Powershell-Scripts/actions/workflows/lint.yml/badge.svg)](https://github.com/omfgnick/Powershell-Scripts/actions/workflows/lint.yml)

Small, self-contained PowerShell utilities for Windows infrastructure tasks.

## Scripts

### `backup-folder.ps1`
Creates a compressed (`.zip`) backup of a folder, verifies the archive can be
opened and enumerated, and optionally e-mails a status report.

```powershell
.\backup-folder.ps1 -SourcePath "C:\Data" -DestinationPath "D:\Backups"

.\backup-folder.ps1 -SourcePath "C:\Data" -DestinationPath "D:\Backups" `
    -SmtpServer smtp.example.com -MailTo ops@example.com -MailFrom backup@example.com
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-SourcePath` | Directory to back up (required) | — |
| `-DestinationPath` | Where the `.zip` is written (created if missing, required) | — |
| `-SmtpServer` | SMTP server for notification (omit = no e-mail) | — |
| `-MailTo` | Status e-mail recipient | — |
| `-MailFrom` | Status e-mail sender | `backup@localhost` |

Supports `-WhatIf` / `-Verbose`.

### `backup_retention.ps1`
Applies a retention policy to a folder: files older than the retention window
are compressed into per-file `.zip` archives and the originals removed; `.zip`
archives that are themselves older than the window are deleted.

```powershell
.\backup_retention.ps1 -FolderPath "C:\Logs" -DaysToKeep 30

.\backup_retention.ps1 -FolderPath "C:\Logs" -WhatIf   # preview only
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-FolderPath` | Root folder processed recursively (required) | — |
| `-DaysToKeep` | Age threshold in days | `30` |

Old archives are pruned **before** new ones are created, so a freshly written
archive is never deleted in the same run. Supports `-WhatIf` / `-Verbose`.

### `Get-DiskSpaceReport.ps1`
Reports fixed-disk usage for one or more machines and flags volumes below a
free-space threshold. Can export to CSV/HTML.

```powershell
.\Get-DiskSpaceReport.ps1
.\Get-DiskSpaceReport.ps1 -ComputerName SRV01,SRV02 -ThresholdPercent 10 -HtmlPath .\disk.html
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-ComputerName` | Machines to query | local machine |
| `-ThresholdPercent` | Free-% at/below which a volume is flagged `LOW` | `15` |
| `-CsvPath` / `-HtmlPath` | Optional export paths | — |

The local machine is queried without WinRM (local CIM/DCOM session); remote
machines use WS-Man.

### `Test-ServiceHealth.ps1`
Checks Windows services and optionally restarts the ones that are not running.

```powershell
.\Test-ServiceHealth.ps1 -Name Spooler,W32Time
.\Test-ServiceHealth.ps1 -InputFile .\services.txt -AutoRestart -WhatIf
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Name` | Service name(s); accepts pipeline input | — |
| `-InputFile` | Text file, one service per line (`#` comments allowed) | — |
| `-AutoRestart` | Start any service that is not running | off |

Supports `-WhatIf` / `-Verbose`.

### `Test-Endpoints.ps1`
Health-checks endpoints — `host:port` (TCP) and `http(s)://` (HTTP) — reporting
reachability, status and latency.

```powershell
.\Test-Endpoints.ps1 -Target "example.com:443","https://example.com"
.\Test-Endpoints.ps1 -InputFile .\endpoints.txt -CsvPath .\health.csv
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Target` | Endpoint(s); accepts pipeline input | — |
| `-InputFile` | Text file, one target per line (`#` comments allowed) | — |
| `-TimeoutSeconds` | Per-request HTTP timeout | `10` |
| `-CsvPath` | Optional CSV export path | — |

### `Get-OpenPorts.ps1`
Lists local TCP ports with the owning process — Windows counterpart to the Bash
`portscan-vuln.sh` (local inspection, not a remote scanner).

```powershell
.\Get-OpenPorts.ps1
.\Get-OpenPorts.ps1 -State Established -Port 443,3389 -CsvPath .\ports.csv
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-State` | TCP state(s): `Listen`, `Established`, `TimeWait`, `CloseWait`, `All` | `Listen` |
| `-Port` | Filter to specific local port(s) | all |
| `-CsvPath` | Optional CSV export path | — |

### `Get-EventLogErrors.ps1`
Collects Error/Warning events from Windows event logs over a recent window and
summarises them by source (or returns the individual events with `-Detailed`).

```powershell
.\Get-EventLogErrors.ps1 -Hours 12
.\Get-EventLogErrors.ps1 -LogName System -Level Error -Detailed -CsvPath .\errors.csv
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-LogName` | Logs to query | `System, Application` |
| `-Hours` | Look-back window in hours | `24` |
| `-Level` | `Error`, `Warning`, or both | both |
| `-Detailed` | Return individual events instead of a summary | off |
| `-CsvPath` | Optional CSV export path | — |

### `Get-TLSCertExpiry.ps1`
Checks the TLS certificate of one or more hosts and reports days until expiry,
flagging `EXPIRING` / `EXPIRED`.

```powershell
.\Get-TLSCertExpiry.ps1 -Target github.com,example.com:443
.\Get-TLSCertExpiry.ps1 -InputFile .\hosts.txt -WarnDays 45 -CsvPath .\certs.csv
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Target` | Host(s) as `host` or `host:port`; accepts pipeline input | — |
| `-InputFile` | Text file, one host per line (`#` comments allowed) | — |
| `-WarnDays` | Flag certs expiring within this many days | `30` |
| `-TimeoutSeconds` | Connection timeout per host | `10` |
| `-CsvPath` | Optional CSV export path | — |

Certificate trust is **not** validated — the script only reads the presented
certificate to inspect its expiry date.

### `Audit-LocalUsers.ps1`
Audits local user accounts for common hardening findings: enabled accounts whose
password never expires, accounts with no password required, members of the local
Administrators group, and accounts that have never logged on. Read-only.

```powershell
.\Audit-LocalUsers.ps1
.\Audit-LocalUsers.ps1 -CsvPath .\localusers.csv -Verbose
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-CsvPath` | Optional CSV export path | — |

Administrators membership is resolved by SID (`S-1-5-32-544`), so it works
regardless of system language.

### `Rotate-Logs.ps1`
Rotates log files: compresses logs older than a threshold and deletes archives
past a retention period. Old archives are pruned before new ones are created.

```powershell
.\Rotate-Logs.ps1 -Path C:\inetpub\logs -CompressAfterDays 7 -DeleteAfterDays 60
.\Rotate-Logs.ps1 -Path C:\Logs -Filter *.txt -WhatIf
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Path` | Root folder with the logs (recursive, required) | — |
| `-Filter` | Wildcard for log files to rotate | `*.log` |
| `-CompressAfterDays` | Compress logs older than this | `7` |
| `-DeleteAfterDays` | Delete `.zip` archives older than this | `90` |

Supports `-WhatIf` / `-Verbose`.

### `Cleanup-TempFiles.ps1`
Removes old temporary files and reports how much space was reclaimed. **Dry run
by default** — nothing is deleted unless `-Execute` is given.

```powershell
.\Cleanup-TempFiles.ps1                      # preview default locations
.\Cleanup-TempFiles.ps1 -OlderThanDays 3 -Execute
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Path` | Folders to clean | `%TEMP%`, `Windows\Temp`, INetCache |
| `-OlderThanDays` | Only remove files older than this | `7` |
| `-Execute` | Actually delete (otherwise dry run) | off |

Locked/in-use files are skipped safely. Supports `-WhatIf` / `-Confirm`.

### `New-UptimeReport.ps1`
Runs endpoint health checks and writes a self-contained, colour-coded HTML
availability report. Reuses `Test-Endpoints.ps1` when present.

```powershell
.\New-UptimeReport.ps1 -Target "example.com:443","https://example.com"
.\New-UptimeReport.ps1 -InputFile .\endpoints.txt -OutputPath .\status.html
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Target` | Endpoint(s); accepts pipeline input | — |
| `-InputFile` | Text file, one target per line (`#` comments allowed) | — |
| `-OutputPath` | HTML report path | `.\uptime-report.html` |
| `-TimeoutSeconds` | Per-request timeout | `10` |

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- `Send-MailMessage` (optional; only for e-mail notifications)
- CIM / `Get-NetTCPConnection` / `Get-WinEvent` / `Get-LocalUser` cmdlets
  (built in on modern Windows)
- `Audit-LocalUsers.ps1` reads Administrators membership; run elevated for
  complete results

## Safety notes

Scripts that change or delete data (`backup_retention.ps1`, `Rotate-Logs.ps1`,
`Cleanup-TempFiles.ps1`, `Test-ServiceHealth.ps1 -AutoRestart`) support
`-WhatIf`. Preview first:

```powershell
.\Cleanup-TempFiles.ps1 -WhatIf -Verbose
```

## Usage

```powershell
# Preview any script safely before running it for real:
.\backup_retention.ps1 -FolderPath "C:\Logs" -WhatIf -Verbose
```

## Continuous integration

Every push to `main` and every pull request runs the
[Lint workflow](.github/workflows/lint.yml):

- **PSScriptAnalyzer** against [`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1).
  The build fails on any `Error`/`Warning`. `PSAvoidUsingWriteHost` is
  intentionally disabled (see the settings file for the rationale).
- **Parse check** — every `.ps1` file is parsed to catch syntax errors.

Run the same checks locally before pushing:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```
