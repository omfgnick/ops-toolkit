<#
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
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$FolderPath,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$DaysToKeep = 30,

    # Contrato do toolkit: todo script sabe falar JSON
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
    throw "Folder not found: $FolderPath"
}

$cutoff = (Get-Date).AddDays(-$DaysToKeep)

# 1) Delete old .zip archives FIRST, so freshly created archives (below) are
#    never immediately eligible for deletion in the same run.
$oldZips = Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Filter '*.zip' |
    Where-Object { $_.LastWriteTime -lt $cutoff }

foreach ($zip in $oldZips) {
    if ($PSCmdlet.ShouldProcess($zip.FullName, 'Remove old archive')) {
        Remove-Item -LiteralPath $zip.FullName -Force
        Write-Verbose "Removed old archive: $($zip.FullName)"
    }
}

# 2) Compress old, non-zip files and remove the originals.
$oldFiles = Get-ChildItem -LiteralPath $FolderPath -Recurse -File |
    Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Extension -ne '.zip' }

foreach ($file in $oldFiles) {
    $zipPath = "$($file.FullName).zip"
    if ($PSCmdlet.ShouldProcess($file.FullName, "Compress to $zipPath and delete original")) {
        try {
            Compress-Archive -LiteralPath $file.FullName -DestinationPath $zipPath -Force
            Remove-Item -LiteralPath $file.FullName -Force
            Write-Verbose "Archived: $($file.FullName)"
        }
        catch {
            Write-Warning "Failed to archive '$($file.FullName)': $($_.Exception.Message)"
        }
    }
}

if ($AsJson) {
    [pscustomobject]@{
        script       = 'backup_retention'
        kind         = 'backup_retention'
        hostname     = $env:COMPUTERNAME
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        archived     = @($oldFiles).Count
        removed      = @($oldZips).Count
    } | ConvertTo-Json -Depth 6
    return
}

Write-Host "Retention complete. Archived $($oldFiles.Count) file(s); removed $($oldZips.Count) old archive(s)."
