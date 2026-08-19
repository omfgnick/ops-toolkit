<#
    OpsToolkit — module wrapper around the scripts in this folder.

    The scripts stay standalone on purpose: you can copy a single .ps1 to a
    server and run it. This module exists so that, on a machine where the whole
    toolkit is available, they can be used the way PowerShell expects —
    Import-Module once, then call them as commands with tab completion.

    The wrappers deliberately do no work of their own. They forward every
    parameter to the script, so the module can never drift from the behaviour
    of the file it wraps.
#>

Set-StrictMode -Version Latest

$script:ScriptRoot = $PSScriptRoot
$script:VersionFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'

function Get-OpsToolkitVersion {
    <#
    .SYNOPSIS
        Returns the ops-toolkit version.
    .DESCRIPTION
        Reads the VERSION file at the repository root, the same source the Bash
        scripts embed and the CI checks for drift.
    .EXAMPLE
        Get-OpsToolkitVersion
    #>
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $script:VersionFile) {
        (Get-Content -LiteralPath $script:VersionFile -Raw).Trim()
    }
    else {
        'unknown'
    }
}

function Get-OpsToolkitCommand {
    <#
    .SYNOPSIS
        Lists the scripts this module exposes.
    .DESCRIPTION
        Each entry maps a command to the .ps1 that implements it and shows the
        synopsis taken from that file's comment-based help.
    .EXAMPLE
        Get-OpsToolkitCommand | Format-Table -AutoSize
    #>
    [CmdletBinding()]
    param()
    Get-ChildItem -LiteralPath $script:ScriptRoot -Filter *.ps1 |
        Where-Object { $_.Name -ne 'OpsToolkit.psm1' } |
        ForEach-Object {
            $synopsis = ''
            try { $synopsis = (Get-Help $_.FullName -ErrorAction Stop).Synopsis } catch { $synopsis = '' }
            [pscustomobject]@{
                Command  = $_.BaseName
                Script   = $_.Name
                Synopsis = $synopsis
            }
        }
}

# ---- Wrappers ----------------------------------------------------------------
# One per script. @args forwards everything, including -WhatIf and -Verbose, so
# the wrapper cannot change how the script behaves.

function Invoke-OpsScript {
    <#
    .SYNOPSIS
        Runs one of the toolkit scripts by name.
    .DESCRIPTION
        Escape hatch for a script that has no dedicated wrapper yet. Prefer the
        named commands; this exists so nothing in the folder is unreachable.
    .PARAMETER Name
        Script file name, with or without the .ps1 extension.
    .EXAMPLE
        Invoke-OpsScript -Name Get-DiskSpaceReport -ThresholdPercent 20
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(ValueFromRemainingArguments)][object[]]$Arguments
    )
    if (-not $Name.EndsWith('.ps1')) { $Name = "$Name.ps1" }
    $path = Join-Path $script:ScriptRoot $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Script not found in the toolkit: $Name"
    }
    & $path @Arguments
}

function Get-DiskSpaceReport { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Get-DiskSpaceReport.ps1') @args }
function Test-ServiceHealth { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Test-ServiceHealth.ps1') @args }
function Test-Endpoints { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Test-Endpoints.ps1') @args }
function Get-OpenPorts { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Get-OpenPorts.ps1') @args }
function Get-EventLogErrors { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Get-EventLogErrors.ps1') @args }
function Get-TLSCertExpiry { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Get-TLSCertExpiry.ps1') @args }
function New-UptimeReport { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'New-UptimeReport.ps1') @args }
function Invoke-LogRotation { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Rotate-Logs.ps1') @args }
function Clear-TempFiles { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Cleanup-TempFiles.ps1') @args }
function Get-LocalUserAudit { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'Audit-LocalUsers.ps1') @args }
function Backup-Folder { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'backup-folder.ps1') @args }
function Invoke-BackupRetention { [CmdletBinding()] param() & (Join-Path $script:ScriptRoot 'backup_retention.ps1') @args }

Export-ModuleMember -Function @(
    'Get-OpsToolkitVersion'
    'Get-OpsToolkitCommand'
    'Invoke-OpsScript'
    'Get-DiskSpaceReport'
    'Test-ServiceHealth'
    'Test-Endpoints'
    'Get-OpenPorts'
    'Get-EventLogErrors'
    'Get-TLSCertExpiry'
    'New-UptimeReport'
    'Invoke-LogRotation'
    'Clear-TempFiles'
    'Get-LocalUserAudit'
    'Backup-Folder'
    'Invoke-BackupRetention'
)
