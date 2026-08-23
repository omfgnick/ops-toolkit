<#
.SYNOPSIS
    Reports pending Windows updates, pending winget upgrades and whether the
    machine is waiting for a reboot.

.DESCRIPTION
    Read-only. This script never installs, downloads or applies anything: it
    only asks Windows Update what it would offer.

    The value here is not the count of updates. It is the two things that make
    a machine look healthy while it is not:

      - a reboot that never happened, so patches are installed but not active
      - a Windows Update service that has not talked to its source in weeks,
        so "0 pending" means "nobody asked", not "nothing missing"

    Both are reported explicitly instead of being folded into a single number.

    The search talks to whatever source the machine is configured to use
    (Microsoft Update or an internal WSUS), takes a while on the first run of
    the day, and needs the network. When it cannot run, the script says so and
    still reports the reboot state, which is local and always available.

.PARAMETER IncludeHidden
    Also count updates an administrator hid. Hidden updates are excluded by
    default because someone decided they should not be offered.

.PARAMETER SkipWindowsUpdate
    Skip the Windows Update query and report only the reboot state and winget.
    Useful on a machine with no network, where the search would just hang.

.PARAMETER StaleDays
    Consider the last successful search stale after this many days. Default 7.

.PARAMETER AsJson
    Emit JSON instead of the readable report.

.EXAMPLE
    .\Get-PendingUpdate.ps1

    Prints the readable report.

.EXAMPLE
    .\Get-PendingUpdate.ps1 -AsJson | ConvertFrom-Json | Select-Object -Expand pendingCount

    Feeds a monitoring system.

.EXAMPLE
    .\Get-PendingUpdate.ps1 -SkipWindowsUpdate

    Answers "is this machine waiting for a reboot" without touching the network.

.NOTES
    Part of ops-toolkit. Exit codes: 0 nothing pending, 1 updates or a reboot
    pending, 2 the update search could not run.
#>
[CmdletBinding()]
param(
    [switch]$IncludeHidden,
    [switch]$SkipWindowsUpdate,

    [ValidateRange(0, 3650)]
    [int]$StaleDays = 7,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolkitVersion = '1.2.0'

function Test-RebootPending {
    <#
        Windows records a pending reboot in more than one place and no single
        one of them is authoritative. Checking only the Component Based
        Servicing key is the usual mistake: a machine can be waiting on a
        Windows Update reboot with that key absent.
    #>
    $reasons = @()

    $keys = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            Why = 'Component Based Servicing'
        }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
            Why = 'Windows Update'
        }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
            Why = 'servicing in progress'
        }
    )
    foreach ($k in $keys) {
        if (Test-Path -LiteralPath $k.Path) { $reasons += $k.Why }
    }

    # A rename queued for the next boot means a file in use is being replaced
    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    try {
        $item = Get-ItemProperty -LiteralPath $sessionManager -Name 'PendingFileRenameOperations' -ErrorAction Stop
        if ($item.PendingFileRenameOperations) { $reasons += 'pending file rename' }
    } catch {
        # Absent on a machine with nothing queued, which is the normal case
        Write-Verbose "PendingFileRenameOperations not set: $($_.Exception.Message)"
    }

    # A rename of the computer only takes effect after a reboot
    try {
        $active = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
        $next = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
        if ($active -ne $next) { $reasons += "rename to $next" }
    } catch {
        # Not present on every SKU
        Write-Verbose "ComputerName keys unreadable: $($_.Exception.Message)"
    }

    return $reasons
}

function Get-WindowsUpdateStatus {
    param([bool]$WithHidden)

    $result = [ordered]@{
        available     = $false
        count         = 0
        securityCount = 0
        updates       = @()
        lastSearch    = $null
        lastInstall   = $null
        note          = ''
    }

    if (-not $IsWindowsPlatform) {
        $result.note = 'Windows Update is only available on Windows'
        return $result
    }

    # The last search and install timestamps come from a different COM object
    # and are cheap, so they are read even when the search itself fails - they
    # are what tells you whether "0 pending" means anything.
    try {
        $auto = New-Object -ComObject 'Microsoft.Update.AutoUpdate'
        if ($auto.Results.LastSearchSuccessDate) { $result.lastSearch = $auto.Results.LastSearchSuccessDate }
        if ($auto.Results.LastInstallationSuccessDate) { $result.lastInstall = $auto.Results.LastInstallationSuccessDate }
    } catch {
        $result.note = "could not read the update history: $($_.Exception.Message)"
    }

    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $criteria = if ($WithHidden) { 'IsInstalled=0' } else { 'IsInstalled=0 and IsHidden=0' }
        $found = $searcher.Search($criteria)

        $result.available = $true
        $result.count = $found.Updates.Count

        $list = @()
        foreach ($u in $found.Updates) {
            $isSecurity = $false
            foreach ($c in $u.Categories) {
                if ($c.Name -match 'Security') { $isSecurity = $true }
            }
            if ($isSecurity) { $result.securityCount++ }

            $list += [ordered]@{
                title    = $u.Title
                severity = if ($u.MsrcSeverity) { $u.MsrcSeverity } else { '' }
                security = $isSecurity
                sizeMb   = [math]::Round($u.MaxDownloadSize / 1MB, 1)
            }
        }
        $result.updates = $list
    } catch {
        # No network, a WSUS that is down, or the service disabled. Say which,
        # instead of reporting zero and looking like a healthy machine.
        $result.note = "the update search could not run: $($_.Exception.Message)"
    }

    return $result
}

function Get-WingetUpgrade {
    $out = [ordered]@{ available = $false; count = 0; packages = @() }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { return $out }

    try {
        # --accept-source-agreements keeps the first run from waiting on a
        # prompt that nobody is there to answer.
        $lines = & winget upgrade --accept-source-agreements 2>$null
        $out.available = $true

        # The table is column-aligned and the header is localised, so the row
        # of dashes is the only anchor that does not depend on the language.
        #
        # Parsing is done from the right, not the left: a long name fills its
        # column and leaves a single space before the id, which makes splitting
        # on runs of spaces drop exactly the rows with the longest names - the
        # Visual C++ redistributables went missing that way. The four rightmost
        # fields (id, current, available, source) never contain a space, so the
        # name is simply whatever is left.
        $rows = @()
        $inTable = $false
        foreach ($line in $lines) {
            if ($line -match '^\s*-{5,}\s*$') { $inTable = $true; continue }
            if (-not $inTable) { continue }
            if ($line -match '^\s*$') { continue }

            $tok = @($line -split '\s+' | Where-Object { $_ -ne '' })
            if ($tok.Count -lt 5) { continue }

            $current = $tok[$tok.Count - 3]
            $available = $tok[$tok.Count - 2]

            # The trailing prose ("N package(s) have version numbers that
            # cannot be determined...") also has five or more words, so the
            # test that separates a row from a sentence is the shape of the
            # two version columns.
            if ($current -notmatch '^\d' -or $available -notmatch '^\d') { continue }

            $rows += [ordered]@{
                name      = ($tok[0..($tok.Count - 5)] -join ' ')
                id        = $tok[$tok.Count - 4]
                current   = $current
                available = $available
            }
        }
        $out.packages = @($rows)
        $out.count = $rows.Count
    } catch {
        Write-Verbose "winget upgrade failed: $($_.Exception.Message)"
        $out.available = $false
    }

    return $out
}

# PowerShell 5.1 has no $IsWindows, and on 7 it exists and can be false
$IsWindowsPlatform = -not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows)

$rebootReasons = if ($IsWindowsPlatform) { Test-RebootPending } else { @() }
$rebootPending = @($rebootReasons).Count -gt 0

if ($SkipWindowsUpdate) {
    $wu = [ordered]@{
        available = $false; count = 0; securityCount = 0; updates = @()
        lastSearch = $null; lastInstall = $null; note = 'skipped by -SkipWindowsUpdate'
    }
} else {
    $wu = Get-WindowsUpdateStatus -WithHidden:$IncludeHidden.IsPresent
}

$winget = Get-WingetUpgrade

# How stale is the last successful search
$searchAgeDays = -1
if ($wu.lastSearch) {
    $searchAgeDays = [int][math]::Floor(((Get-Date) - [datetime]$wu.lastSearch).TotalDays)
}
$searchStale = ($searchAgeDays -lt 0) -or ($searchAgeDays -gt $StaleDays)

# 2 means "could not check", which is not the same as "nothing pending" and
# must not be confused with it by whatever reads this exit code.
$exitCode = 0
if (-not $SkipWindowsUpdate -and -not $wu.available) {
    $exitCode = 2
} elseif ($wu.count -gt 0 -or $rebootPending -or $winget.count -gt 0) {
    $exitCode = 1
}

$report = [ordered]@{
    host           = [System.Net.Dns]::GetHostName()
    generatedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    toolkitVersion = $script:ToolkitVersion
    pendingCount   = $wu.count
    securityCount  = $wu.securityCount
    updates        = $wu.updates
    searchOk       = $wu.available
    lastSearch     = if ($wu.lastSearch) { ([datetime]$wu.lastSearch).ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
    lastInstall    = if ($wu.lastInstall) { ([datetime]$wu.lastInstall).ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
    searchAgeDays  = $searchAgeDays
    searchStale    = $searchStale
    staleAfterDays = $StaleDays
    rebootPending  = $rebootPending
    rebootReasons  = @($rebootReasons)
    winget         = $winget
    note           = $wu.note
    status         = $exitCode
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 6
    exit $exitCode
}

Write-Host ''
Write-Host "Pending updates - $($report.host)"
Write-Host "Generated at $($report.generatedAt)"
Write-Host ''

Write-Host '  Windows Update'
if ($wu.available) {
    Write-Host ("    Pending      : {0}" -f $wu.count)
    Write-Host ("    Security     : {0}" -f $wu.securityCount)
} else {
    Write-Host '    Pending      : not checked'
}
if ($wu.lastSearch) {
    Write-Host ("    Last search  : {0} ({1} day(s) ago)" -f $report.lastSearch, $searchAgeDays)
} else {
    Write-Host '    Last search  : unknown'
}
if ($wu.lastInstall) {
    Write-Host ("    Last install : {0}" -f $report.lastInstall)
}
if ($wu.note) {
    Write-Host ("    Note         : {0}" -f $wu.note)
}
Write-Host ''

Write-Host '  Reboot'
if ($rebootPending) {
    Write-Host ("    Pending      : yes ({0})" -f ($rebootReasons -join ', '))
    Write-Host '    Installed patches are not active until this happens.'
} else {
    Write-Host '    Pending      : no'
}
Write-Host ''

if ($winget.available) {
    Write-Host '  winget'
    Write-Host ("    Upgradable   : {0} package(s)" -f $winget.count)
}
Write-Host ''

if ($searchStale -and -not $SkipWindowsUpdate) {
    Write-Host '  WARNING: the last successful search is older than the threshold.'
    Write-Host '  A count of 0 above says nobody asked, not that nothing is missing.'
    Write-Host ''
}

if ($wu.available -and $wu.count -gt 0) {
    Write-Host '  Pending updates'
    foreach ($u in $wu.updates) {
        $mark = if ($u.security) { '[SEC]' } else { '     ' }
        Write-Host ("    {0} {1}" -f $mark, $u.title)
    }
    Write-Host ''
}

exit $exitCode
