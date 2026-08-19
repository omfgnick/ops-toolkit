<#
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
#>
[CmdletBinding()]
param(
    [switch]$AsJson,
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows-only: this script drives Windows components. Say so plainly instead of
# failing later with an exception from a cmdlet that does not exist elsewhere.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Error 'This script only runs on Windows.'
    exit 2
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()
function Add-Finding {
    param([string]$Severity, [string]$Message)
    $findings.Add([pscustomobject]@{ severity = $Severity; message = $Message })
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Add-Finding 'info' 'running without administrator rights; some checks were skipped'
}

# ---- Local accounts ----------------------------------------------------------
$localUsers = @()
try {
    $localUsers = @(Get-LocalUser -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Name                 = $_.Name
                Enabled              = $_.Enabled
                PasswordRequired     = $_.PasswordRequired
                PasswordNeverExpires = $null -eq $_.PasswordExpires
                LastLogon            = $_.LastLogon
            }
        })
}
catch {
    Add-Finding 'info' "local accounts could not be listed: $($_.Exception.Message)"
}

foreach ($u in $localUsers) {
    if ($u.Enabled -and -not $u.PasswordRequired) {
        Add-Finding 'high' "account '$($u.Name)' is enabled and requires no password"
    }
    if ($u.Enabled -and $u.PasswordNeverExpires) {
        Add-Finding 'medium' "account '$($u.Name)' has a password that never expires"
    }
}

# The built-in Administrator being enabled is a common finding: it is a known
# name with no lockout, which makes it the first target for brute force.
$builtinAdmin = $localUsers | Where-Object { $_.Name -eq 'Administrator' }
if ($builtinAdmin -and $builtinAdmin.Enabled) {
    Add-Finding 'medium' "the built-in 'Administrator' account is enabled"
}

# ---- Administrators group ----------------------------------------------------
try {
    $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | Select-Object -ExpandProperty Name)
    if ($admins.Count -gt 3) {
        Add-Finding 'medium' "$($admins.Count) members in the Administrators group"
    }
}
catch {
    $admins = @()
    Add-Finding 'info' 'Administrators group membership could not be read'
}

# ---- Firewall ----------------------------------------------------------------
$firewall = @()
try {
    $firewall = @(Get-NetFirewallProfile -ErrorAction Stop | Select-Object Name, Enabled)
    foreach ($p in $firewall) {
        if (-not $p.Enabled) { Add-Finding 'high' "firewall profile '$($p.Name)' is disabled" }
    }
}
catch {
    Add-Finding 'info' 'firewall profiles could not be read'
}

# ---- SMBv1 -------------------------------------------------------------------
# SMBv1 is the protocol WannaCry spread over; it should be off everywhere.
try {
    $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
    if ($smb1) { Add-Finding 'high' 'SMBv1 is enabled on the server service' }
}
catch {
    Add-Finding 'info' 'SMB server configuration could not be read (needs admin)'
}

# ---- RDP ---------------------------------------------------------------------
try {
    $ts = Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop
    if ($ts.fDenyTSConnections -eq 0) {
        $nla = $null
        try {
            $nla = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction Stop).UserAuthentication
        }
        catch {
            Write-Verbose "NLA setting unreadable: $($_.Exception.Message)"
        }
        if ($nla -eq 0) {
            Add-Finding 'high' 'RDP is enabled without Network Level Authentication'
        }
        else {
            Add-Finding 'info' 'RDP is enabled (with NLA)'
        }
    }
}
catch {
    Add-Finding 'info' 'RDP configuration could not be read'
}

# ---- Listening ports ---------------------------------------------------------
$listening = @()
try {
    $listening = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Select-Object -Unique LocalAddress, LocalPort |
            Sort-Object LocalPort)
    $external = @($listening | Where-Object { $_.LocalAddress -in '0.0.0.0', '::' })
    if ($external.Count -gt 0) {
        Add-Finding 'info' "$($external.Count) socket(s) listening on all interfaces"
    }
}
catch {
    Add-Finding 'info' 'listening ports could not be read'
}

# ---- Output ------------------------------------------------------------------
$high = @($findings | Where-Object { $_.severity -eq 'high' }).Count
$medium = @($findings | Where-Object { $_.severity -eq 'medium' }).Count
$info = @($findings | Where-Object { $_.severity -eq 'info' }).Count

if ($AsJson) {
    $output = [pscustomobject]@{
        hostname  = $env:COMPUTERNAME
        as_admin  = $isAdmin
        accounts  = @($localUsers)
        firewall  = @($firewall)
        listening = @($listening)
        findings  = @($findings)
        summary   = @{ high = $high; medium = $medium; info = $info }
    } | ConvertTo-Json -Depth 5
}
else {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('===============================================================')
    [void]$sb.AppendLine(" SECURITY AUDIT - $env:COMPUTERNAME")
    [void]$sb.AppendLine(" $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')")
    if (-not $isAdmin) { [void]$sb.AppendLine(' (running unprivileged - some checks were skipped)') }
    [void]$sb.AppendLine('===============================================================')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Local accounts ----------------------------------------------')
    if ($localUsers.Count -eq 0) { [void]$sb.AppendLine('  (unavailable)') }
    else {
        foreach ($u in $localUsers) {
            [void]$sb.AppendLine(("  {0,-22} enabled={1,-5} pwd_required={2}" -f $u.Name, $u.Enabled, $u.PasswordRequired))
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Administrators ----------------------------------------------')
    if ($admins.Count -eq 0) { [void]$sb.AppendLine('  (unavailable)') }
    else { foreach ($a in $admins) { [void]$sb.AppendLine("  $a") } }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Firewall ----------------------------------------------------')
    if ($firewall.Count -eq 0) { [void]$sb.AppendLine('  (unavailable)') }
    else { foreach ($p in $firewall) { [void]$sb.AppendLine(("  {0,-10} enabled={1}" -f $p.Name, $p.Enabled)) } }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Findings ----------------------------------------------------')
    if ($findings.Count -eq 0) { [void]$sb.AppendLine('  Nothing flagged.') }
    else { foreach ($f in $findings) { [void]$sb.AppendLine(("  [{0,-6}] {1}" -f $f.severity, $f.message)) } }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("high=$high medium=$medium info=$info")
    $output = $sb.ToString()
}

$output
if ($OutFile) { $output | Set-Content -LiteralPath $OutFile -Encoding UTF8 }

# 'info' entries are notes, not problems: only high/medium change the exit code
if ($high -gt 0 -or $medium -gt 0) { exit 1 }
exit 0
