<#
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
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$Filter = '*.log',

    [ValidateRange(0, [int]::MaxValue)]
    [int]$CompressAfterDays = 7,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$DeleteAfterDays = 90,

    # Contrato do toolkit: todo script sabe falar JSON
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Path not found: $Path"
}

$now            = Get-Date
$compressCutoff = $now.AddDays(-$CompressAfterDays)
$deleteCutoff   = $now.AddDays(-$DeleteAfterDays)

# 1) Prune old archives first. @() so .Count is safe for 0 or 1 matches.
$oldZips = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.zip' |
    Where-Object { $_.LastWriteTime -lt $deleteCutoff })

foreach ($zip in $oldZips) {
    if ($PSCmdlet.ShouldProcess($zip.FullName, 'Delete old archive')) {
        Remove-Item -LiteralPath $zip.FullName -Force
        Write-Verbose "Deleted archive: $($zip.FullName)"
    }
}

# 2) Compress old logs matching the filter (never .zip files themselves).
$logs = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter $Filter |
    Where-Object { $_.LastWriteTime -lt $compressCutoff -and $_.Extension -ne '.zip' })

$compressed = 0
foreach ($log in $logs) {
    $zipPath = "$($log.FullName).zip"
    if ($PSCmdlet.ShouldProcess($log.FullName, "Compress to $zipPath and delete original")) {
        try {
            Compress-Archive -LiteralPath $log.FullName -DestinationPath $zipPath -Force
            Remove-Item -LiteralPath $log.FullName -Force
            $compressed++
            Write-Verbose "Rotated: $($log.FullName)"
        }
        catch {
            Write-Warning "Failed to rotate '$($log.FullName)': $($_.Exception.Message)"
        }
    }
}

if ($AsJson) {
    [pscustomobject]@{
        script       = 'Rotate-Logs'
        kind         = 'log_rotation'
        hostname     = $env:COMPUTERNAME
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        compressed   = $compressed
        deleted      = @($oldZips).Count
    } | ConvertTo-Json -Depth 6
    return
}

Write-Host "Rotation complete. Compressed $compressed log(s); deleted $($oldZips.Count) old archive(s)."
