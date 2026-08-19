<#
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
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Spooler', 'WindowsUpdate', 'Network', 'UserCache', 'All')]
    [string[]]$Repair,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows-only: this script drives Windows components. Say so plainly instead of
# failing later with an exception from a cmdlet that does not exist elsewhere.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Error 'This script only runs on Windows.'
    exit 2
}

$results = [System.Collections.Generic.List[pscustomobject]]::new()
function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ repair = $Name; status = $Status; detail = $Detail })
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$wanted = if ($Repair -contains 'All') { 'Spooler', 'WindowsUpdate', 'Network', 'UserCache' } else { $Repair }

# ---- Print spooler -----------------------------------------------------------
if ($wanted -contains 'Spooler') {
    if (-not $isAdmin) {
        Add-Result 'Spooler' 'skipped' 'needs administrator rights'
    }
    elseif ($PSCmdlet.ShouldProcess('Print Spooler', 'Stop, clear the queue and start')) {
        try {
            Stop-Service -Name Spooler -Force
            # The queue lives on disk; a stuck job survives a plain restart.
            $queue = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
            $removed = 0
            if (Test-Path -LiteralPath $queue) {
                $items = @(Get-ChildItem -LiteralPath $queue -File -ErrorAction SilentlyContinue)
                $items | Remove-Item -Force -ErrorAction SilentlyContinue
                $removed = $items.Count
            }
            Start-Service -Name Spooler
            Add-Result 'Spooler' 'done' "queue cleared ($removed file(s)), service restarted"
        }
        catch {
            Add-Result 'Spooler' 'failed' $_.Exception.Message
        }
    }
    else {
        Add-Result 'Spooler' 'whatif' 'would clear the queue and restart the spooler'
    }
}

# ---- Windows Update ----------------------------------------------------------
if ($wanted -contains 'WindowsUpdate') {
    if (-not $isAdmin) {
        Add-Result 'WindowsUpdate' 'skipped' 'needs administrator rights'
    }
    elseif ($PSCmdlet.ShouldProcess('Windows Update', 'Stop services, rename SoftwareDistribution, restart')) {
        try {
            $services = 'wuauserv', 'bits', 'cryptsvc'
            foreach ($s in $services) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
            # Renamed rather than deleted: Windows rebuilds the folder, and the
            # old one stays available if this made things worse.
            $sd = Join-Path $env:SystemRoot 'SoftwareDistribution'
            $backupName = "SoftwareDistribution.old-$(Get-Date -Format 'yyyyMMddHHmmss')"
            if (Test-Path -LiteralPath $sd) { Rename-Item -LiteralPath $sd -NewName $backupName }
            foreach ($s in $services) { Start-Service -Name $s -ErrorAction SilentlyContinue }
            Add-Result 'WindowsUpdate' 'done' "components reset; old folder kept as $backupName"
        }
        catch {
            Add-Result 'WindowsUpdate' 'failed' $_.Exception.Message
        }
    }
    else {
        Add-Result 'WindowsUpdate' 'whatif' 'would reset the update components'
    }
}

# ---- Network -----------------------------------------------------------------
if ($wanted -contains 'Network') {
    if (-not $isAdmin) {
        Add-Result 'Network' 'skipped' 'needs administrator rights'
    }
    elseif ($PSCmdlet.ShouldProcess('Network stack', 'Flush DNS, renew lease, reset winsock')) {
        try {
            $steps = @()
            Clear-DnsClientCache
            $steps += 'dns cache cleared'
            & ipconfig /release | Out-Null
            & ipconfig /renew | Out-Null
            $steps += 'dhcp lease renewed'
            & netsh winsock reset | Out-Null
            $steps += 'winsock reset (reboot required)'
            Add-Result 'Network' 'done' ($steps -join '; ')
        }
        catch {
            Add-Result 'Network' 'failed' $_.Exception.Message
        }
    }
    else {
        Add-Result 'Network' 'whatif' 'would flush DNS, renew the lease and reset winsock'
    }
}

# ---- User caches -------------------------------------------------------------
if ($wanted -contains 'UserCache') {
    if ($PSCmdlet.ShouldProcess('Teams and Outlook caches', 'Delete cached files for the current user')) {
        try {
            $paths = @(
                Join-Path $env:APPDATA 'Microsoft\Teams\Cache'
                Join-Path $env:APPDATA 'Microsoft\Teams\GPUCache'
                Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook\RoamCache'
            )
            $cleared = 0
            foreach ($p in $paths) {
                if (Test-Path -LiteralPath $p) {
                    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
                    $cleared++
                }
            }
            Add-Result 'UserCache' 'done' "$cleared cache folder(s) cleared (close Teams/Outlook first)"
        }
        catch {
            Add-Result 'UserCache' 'failed' $_.Exception.Message
        }
    }
    else {
        Add-Result 'UserCache' 'whatif' 'would clear the Teams and Outlook caches'
    }
}

# ---- Report ------------------------------------------------------------------
$failed = @($results | Where-Object { $_.status -eq 'failed' }).Count

if ($AsJson) {
    [pscustomobject]@{
        hostname = $env:COMPUTERNAME
        as_admin = $isAdmin
        repairs  = @($results)
        failed   = $failed
    } | ConvertTo-Json -Depth 4
}
else {
    Write-Output ''
    Write-Output "Repairs - $env:COMPUTERNAME"
    if (-not $isAdmin) { Write-Output '  (not running as administrator - some repairs were skipped)' }
    Write-Output ''
    foreach ($r in $results) {
        Write-Output ('  [{0,-7}] {1,-14} {2}' -f $r.status, $r.repair, $r.detail)
    }
    Write-Output ''
    if ($wanted -contains 'Network') {
        Write-Output 'A winsock reset only takes effect after a reboot.'
    }
}

if ($failed -gt 0) { exit 1 }
exit 0
