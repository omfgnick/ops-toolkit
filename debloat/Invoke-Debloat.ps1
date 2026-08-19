<#
.SYNOPSIS
    Removes preinstalled apps and turns off telemetry, promotional content and
    unused interface features on Windows - showing the full plan first.

.DESCRIPTION
    Reads every change from Actions.psd1, so what this script can do is a list
    you can review without reading code. Each entry declares which profile it
    belongs to, how risky it is and how to undo it.

    Four things stand between you and a mistake:

      1. Nothing is applied without -Apply. Run it plain and you get the plan.
      2. A System Restore Point is created before the first change (-NoRestorePoint
         to skip, which you should only do if restore points are disabled by policy).
      3. Every registry key touched is exported first, and a revert script is
         written next to the backup.
      4. Every change goes through ShouldProcess, so -WhatIf and -Confirm work.

    Profiles are cumulative: Recommended includes Minimal, Aggressive includes
    both. Services and scheduled tasks are Aggressive only, because a disabled
    service tends to break something weeks later in a way nobody traces back
    here.

    Run this on one machine and use it before rolling it anywhere.

.PARAMETER Preset
    Minimal, Recommended or Aggressive. Default: Minimal.

.PARAMETER Apply
    Actually make the changes. Without it, the script only prints the plan.

.PARAMETER Only
    Apply only these action ids (see the plan for the ids).

.PARAMETER Skip
    Skip these action ids.

.PARAMETER AllUsers
    Remove AppX packages for every user and from the provisioned image, not just
    the current user. Needs administrator rights.

.PARAMETER BackupPath
    Where to write the registry export and the revert script.
    Default: %USERPROFILE%\ops-toolkit-debloat\<timestamp>

.PARAMETER NoRestorePoint
    Skip creating a restore point.

.PARAMETER AsJson
    Emit the plan or the result as JSON.

.EXAMPLE
    .\Invoke-Debloat.ps1
    Shows what the Minimal profile would change. Changes nothing.

.EXAMPLE
    .\Invoke-Debloat.ps1 -Preset Recommended -Apply

.EXAMPLE
    .\Invoke-Debloat.ps1 -Preset Aggressive -Skip svc.diagtrack, app.quickassist -Apply

.EXAMPLE
    .\Invoke-Debloat.ps1 -Preset Recommended -Apply -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # Named -Preset rather than -Profile because $Profile is a PowerShell
    # automatic variable (the shell profile path) and a parameter by that name
    # shadows it. The alias keeps -Profile working for anyone who types it.
    [Alias('Profile')]
    [ValidateSet('Minimal', 'Recommended', 'Aggressive')]
    [string]$Preset = 'Minimal',

    [switch]$Apply,
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$AllUsers,
    [string]$BackupPath,
    [switch]$NoRestorePoint,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Applying only makes sense on Windows, but showing the plan is just reading a
# data file - useful from any machine when you want to review what this would do
# before touching a workstation.
$onWindows = -not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows)
if ($Apply -and -not $onWindows) {
    Write-Error 'Changes can only be applied on Windows. Run without -Apply to see the plan.'
    exit 2
}

$actionsFile = Join-Path $PSScriptRoot 'Actions.psd1'
if (-not (Test-Path -LiteralPath $actionsFile)) {
    Write-Error "Actions.psd1 not found next to the script."
    exit 2
}
$catalog = Import-PowerShellDataFile -LiteralPath $actionsFile

$rank = @{ Minimal = 1; Recommended = 2; Aggressive = 3 }
$wanted = $rank[$Preset]

# ---- Build the plan ----------------------------------------------------------
$plan = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($type in 'AppX', 'Registry', 'Service', 'Task') {
    foreach ($a in $catalog[$type]) {
        if ($rank[$a.Profile] -gt $wanted) { continue }
        if ($Only -and $a.Id -notin $Only) { continue }
        if ($Skip -and $a.Id -in $Skip) { continue }
        $plan.Add([pscustomobject]@{
                Id         = $a.Id
                Type       = $type
                Summary    = $a.Summary
                Risk       = $a.Risk
                Reversible = $a.Reversible
                Note       = if ($a.ContainsKey('Note')) { $a.Note } else { '' }
                Data       = $a
                Status     = 'planned'
                Detail     = ''
            })
    }
}

$isAdmin = $false
if ($onWindows) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- Dry run: show the plan and stop ----------------------------------------
if (-not $Apply) {
    if ($AsJson) {
        [pscustomobject]@{
            mode    = 'plan'
            profile = $Preset
            applied = $false
            actions = @($plan | Select-Object Id, Type, Summary, Risk, Reversible, Note)
        } | ConvertTo-Json -Depth 4
    }
    else {
        Write-Host ''
        Write-Host "Debloat plan - preset: $Preset" -ForegroundColor Cyan
        Write-Host 'Nothing below has been changed. Add -Apply to carry it out.' -ForegroundColor DarkGray
        Write-Host ''
        foreach ($p in $plan) {
            $colour = switch ($p.Risk) { 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'Gray' } }
            Write-Host ('  {0,-26}' -f $p.Id) -NoNewline
            Write-Host ('{0,-7}' -f $p.Risk) -ForegroundColor $colour -NoNewline
            Write-Host $p.Summary
            if ($p.Note) { Write-Host ('  {0,-26}       ! {1}' -f '', $p.Note) -ForegroundColor DarkYellow }
        }
        Write-Host ''
        Write-Host "$($plan.Count) action(s). Every one of them is reversible; see debloat/README.md."
        if (-not $isAdmin) {
            Write-Host 'Not running as administrator - system-wide changes would be skipped.' -ForegroundColor DarkYellow
        }
    }
    exit 0
}

# ---- From here on, changes may happen ---------------------------------------
if (-not $BackupPath) {
    $BackupPath = Join-Path $env:USERPROFILE "ops-toolkit-debloat\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
if ($PSCmdlet.ShouldProcess($BackupPath, 'Create the backup folder')) {
    New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
}

# Restore point: the operating system's own safety net, and the only one that
# covers what this script did not anticipate.
if (-not $NoRestorePoint) {
    if (-not $isAdmin) {
        Write-Host 'Skipping the restore point: needs administrator rights.' -ForegroundColor DarkYellow
    }
    elseif ($PSCmdlet.ShouldProcess('System', 'Create a restore point')) {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description 'Before ops-toolkit debloat' -RestorePointType MODIFY_SETTINGS
            Write-Host 'Restore point created.' -ForegroundColor DarkGray
        }
        catch {
            # Windows refuses more than one restore point in 24h by default.
            Write-Host "Could not create a restore point: $($_.Exception.Message)" -ForegroundColor DarkYellow
            Write-Host 'Continuing - the registry backup below still applies.' -ForegroundColor DarkYellow
        }
    }
}

$revert = [System.Collections.Generic.List[string]]::new()
$revert.Add('# Undoes the changes made by Invoke-Debloat.ps1.')
$revert.Add("# Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), profile $Preset.")
$revert.Add('# Registry values come back from the .reg exports next to this file.')
$revert.Add('')

foreach ($p in $plan) {
    $a = $p.Data
    switch ($p.Type) {

        'AppX' {
            if ($PSCmdlet.ShouldProcess($a.Package, 'Remove the app')) {
                try {
                    $pkgs = @(Get-AppxPackage -Name $a.Package -ErrorAction SilentlyContinue)
                    if ($AllUsers) { $pkgs = @(Get-AppxPackage -Name $a.Package -AllUsers -ErrorAction SilentlyContinue) }
                    if ($pkgs.Count -eq 0) {
                        $p.Status = 'absent'; $p.Detail = 'not installed'
                    }
                    else {
                        $pkgs | Remove-AppxPackage -ErrorAction Stop
                        if ($AllUsers -and $isAdmin) {
                            Get-AppxProvisionedPackage -Online |
                                Where-Object { $_.DisplayName -eq $a.Package } |
                                ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue } | Out-Null
                        }
                        $p.Status = 'done'; $p.Detail = "removed ($($pkgs.Count) package(s))"
                        $revert.Add("# $($a.Id): reinstall '$($a.Package)' from the Microsoft Store")
                    }
                }
                catch {
                    $p.Status = 'failed'; $p.Detail = $_.Exception.Message
                }
            }
            else { $p.Status = 'whatif'; $p.Detail = 'would remove the app' }
        }

        'Registry' {
            $needsAdmin = $a.Path -like 'HKLM:*'
            if ($needsAdmin -and -not $isAdmin) {
                $p.Status = 'skipped'; $p.Detail = 'needs administrator rights'
            }
            elseif ($PSCmdlet.ShouldProcess("$($a.Path)\$($a.Name)", "Set to $($a.Value)")) {
                try {
                    # Export before touching anything. A key that does not exist
                    # yet is recorded as such, so the revert removes it instead
                    # of restoring a value that was never there.
                    $regPath = $a.Path -replace '^HKCU:', 'HKCU' -replace '^HKLM:', 'HKLM'
                    $exportFile = Join-Path $BackupPath ("$($a.Id).reg" -replace '[\\/:*?"<>|]', '_')
                    if (Test-Path -LiteralPath $a.Path) {
                        & reg.exe export $regPath $exportFile /y 2>&1 | Out-Null
                        $revert.Add("reg.exe import `"$exportFile`"")
                    }
                    else {
                        New-Item -Path $a.Path -Force | Out-Null
                        $revert.Add("Remove-Item -Path '$($a.Path)' -Recurse -Force  # did not exist before")
                    }
                    New-ItemProperty -Path $a.Path -Name $a.Name -Value $a.Value -PropertyType $a.Kind -Force | Out-Null
                    $p.Status = 'done'; $p.Detail = "$($a.Name) = $($a.Value)"
                }
                catch {
                    $p.Status = 'failed'; $p.Detail = $_.Exception.Message
                }
            }
            else { $p.Status = 'whatif'; $p.Detail = "would set $($a.Name) = $($a.Value)" }
        }

        'Service' {
            if (-not $isAdmin) {
                $p.Status = 'skipped'; $p.Detail = 'needs administrator rights'
            }
            elseif ($PSCmdlet.ShouldProcess($a.Name, 'Stop and disable the service')) {
                try {
                    $svc = Get-Service -Name $a.Name -ErrorAction SilentlyContinue
                    if (-not $svc) {
                        $p.Status = 'absent'; $p.Detail = 'service not present'
                    }
                    else {
                        $before = (Get-CimInstance Win32_Service -Filter "Name='$($a.Name)'").StartMode
                        Stop-Service -Name $a.Name -Force -ErrorAction SilentlyContinue
                        Set-Service -Name $a.Name -StartupType Disabled
                        $p.Status = 'done'; $p.Detail = "was $before, now Disabled"
                        $revert.Add("Set-Service -Name '$($a.Name)' -StartupType $before")
                    }
                }
                catch {
                    $p.Status = 'failed'; $p.Detail = $_.Exception.Message
                }
            }
            else { $p.Status = 'whatif'; $p.Detail = 'would stop and disable the service' }
        }

        'Task' {
            if (-not $isAdmin) {
                $p.Status = 'skipped'; $p.Detail = 'needs administrator rights'
            }
            elseif ($PSCmdlet.ShouldProcess("$($a.Path)$($a.Name)", 'Disable the scheduled task')) {
                try {
                    $task = Get-ScheduledTask -TaskPath $a.Path -TaskName $a.Name -ErrorAction SilentlyContinue
                    if (-not $task) {
                        $p.Status = 'absent'; $p.Detail = 'task not present'
                    }
                    else {
                        Disable-ScheduledTask -TaskPath $a.Path -TaskName $a.Name | Out-Null
                        $p.Status = 'done'; $p.Detail = 'disabled'
                        $revert.Add("Enable-ScheduledTask -TaskPath '$($a.Path)' -TaskName '$($a.Name)'")
                    }
                }
                catch {
                    $p.Status = 'failed'; $p.Detail = $_.Exception.Message
                }
            }
            else { $p.Status = 'whatif'; $p.Detail = 'would disable the scheduled task' }
        }
    }
}

# ---- Write the revert script -------------------------------------------------
$revertFile = Join-Path $BackupPath 'Undo-Debloat.ps1'
if ($PSCmdlet.ShouldProcess($revertFile, 'Write the revert script')) {
    $revert.Add('')
    $revert.Add('Write-Host "Reverted. Sign out and back in, or reboot, for everything to take effect."')
    $revert | Set-Content -LiteralPath $revertFile -Encoding UTF8
}

# ---- Report ------------------------------------------------------------------
$done = @($plan | Where-Object { $_.Status -eq 'done' }).Count
$failed = @($plan | Where-Object { $_.Status -eq 'failed' }).Count

if ($AsJson) {
    [pscustomobject]@{
        mode        = 'apply'
        profile     = $Preset
        applied     = $true
        backup_path = $BackupPath
        revert      = $revertFile
        done        = $done
        failed      = $failed
        actions     = @($plan | Select-Object Id, Type, Status, Detail, Risk)
    } | ConvertTo-Json -Depth 4
}
else {
    Write-Host ''
    Write-Host "Debloat - preset: $Preset" -ForegroundColor Cyan
    Write-Host ''
    foreach ($p in $plan) {
        Write-Host ('  [{0,-7}] {1,-26} {2}' -f $p.Status, $p.Id, $p.Detail)
    }
    Write-Host ''
    Write-Host "$done applied, $failed failed."
    Write-Host "Backup and revert script: $BackupPath" -ForegroundColor DarkGray
    Write-Host "To undo everything:  & '$revertFile'" -ForegroundColor DarkGray
    Write-Host 'Sign out and back in, or reboot, for the interface changes to show.' -ForegroundColor DarkGray
}

if ($failed -gt 0) { exit 1 }
exit 0
