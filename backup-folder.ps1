<#
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
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [string]$SmtpServer,
    [string]$MailTo,
    [string]$MailFrom = "backup@localhost"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$log = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $log.Add($line)
    Write-Host $line
}

function Send-StatusEmail {
    # Mail settings are passed in explicitly (see call sites) so the function is
    # self-contained and does not rely on implicit parent-scope capture.
    param(
        [string]$Status,
        [string]$Server,
        [string]$To,
        [string]$From,
        [string[]]$Body
    )
    if (-not $Server -or -not $To) { return }
    try {
        Send-MailMessage -SmtpServer $Server -To $To -From $From `
            -Subject "Backup Status - $Status" -Body ($Body -join [Environment]::NewLine)
    }
    catch {
        Write-Warning "Failed to send notification e-mail: $($_.Exception.Message)"
    }
}

try {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "Source directory does not exist: $SourcePath"
    }
    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $stamp      = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $backupFile = Join-Path $DestinationPath "backup-$stamp.zip"

    Write-Log "Creating backup of '$SourcePath' -> '$backupFile'..."
    if ($PSCmdlet.ShouldProcess($backupFile, 'Create backup archive')) {
        Compress-Archive -Path (Join-Path $SourcePath '*') -DestinationPath $backupFile -Force

        # Integrity check: the archive must open and enumerate its entries.
        Write-Log "Verifying archive integrity..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($backupFile)
        try {
            $entryCount = $zip.Entries.Count
        }
        finally {
            $zip.Dispose()
        }
        Write-Log "Backup completed successfully ($entryCount entries): $backupFile"
        Send-StatusEmail -Status "Success" -Server $SmtpServer -To $MailTo -From $MailFrom -Body $log
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Send-StatusEmail -Status "Failed" -Server $SmtpServer -To $MailTo -From $MailFrom -Body $log
    throw
}
