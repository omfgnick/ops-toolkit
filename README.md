# PowerShell Scripts

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

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- `Send-MailMessage` (optional; only for e-mail notifications)

## Usage

```powershell
# Preview any script safely before running it for real:
.\backup_retention.ps1 -FolderPath "C:\Logs" -WhatIf -Verbose
```
