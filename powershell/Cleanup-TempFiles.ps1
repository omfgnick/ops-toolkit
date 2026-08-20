<#
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
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$Path,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$OlderThanDays = 7,

    [switch]$Execute,

    # Contrato do toolkit: todo script sabe falar JSON
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Path) {
    $Path = @(
        $env:TEMP
        Join-Path $env:SystemRoot 'Temp'
        Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

$cutoff       = (Get-Date).AddDays(-$OlderThanDays)
$totalBytes   = 0L
$totalFiles   = 0
$perLocation  = [System.Collections.Generic.List[object]]::new()

foreach ($location in $Path) {
    if (-not (Test-Path -LiteralPath $location -PathType Container)) {
        Write-Warning "Skipping (not found): $location"
        continue
    }

    $locBytes = 0L
    $locFiles = 0

    # -ErrorAction SilentlyContinue: some temp files are locked/in use; skip them.
    Get-ChildItem -LiteralPath $location -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            $file = $_
            if ($Execute) {
                if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete temp file')) {
                    try {
                        $size = $file.Length
                        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                        $locBytes += $size; $locFiles++
                    }
                    catch {
                        Write-Verbose "Locked/skipped: $($file.FullName)"
                    }
                }
            }
            else {
                $locBytes += $file.Length; $locFiles++
            }
        }

    $totalBytes += $locBytes
    $totalFiles += $locFiles
    $perLocation.Add([pscustomobject]@{
        Location = $location
        Files    = $locFiles
        FreedMB  = [math]::Round($locBytes / 1MB, 1)
    })
}

# Com -AsJson a saida e SO o JSON: tabela e aviso iriam junto pelo mesmo
# stream e quebrariam qualquer 'ConvertFrom-Json' do outro lado.
if ($AsJson) {
    [pscustomobject]@{
        script       = 'Cleanup-TempFiles'
        kind         = 'temp_cleanup'
        hostname     = $env:COMPUTERNAME
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        executed     = [bool]$Execute
        dry_run      = -not $Execute
        files        = $totalFiles
        freed_mb     = [math]::Round($totalBytes / 1MB, 1)
        count        = @($perLocation).Count
        items        = @($perLocation)
    } | ConvertTo-Json -Depth 6
    return
}

$perLocation | Format-Table -AutoSize | Out-String | Write-Host

$mode = if ($Execute) { 'Removed' } else { 'Would remove' }
Write-Host ("{0} {1} file(s), {2} MB total." -f $mode, $totalFiles, [math]::Round($totalBytes / 1MB, 1))
if (-not $Execute) {
    Write-Host "Dry run only. Re-run with -Execute to delete." -ForegroundColor Yellow
}
