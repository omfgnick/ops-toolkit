<#
.SYNOPSIS
    Interactive launcher for the toolkit: pick a script from a numbered list
    instead of remembering names and parameters.

.DESCRIPTION
    Builds the list from the scripts themselves, using each file's own
    comment-based help, so a new script shows up here with no change to this
    file and can never be described differently from its documentation.

    Also usable without the menu, for scheduled tasks: -List prints the
    available names and -Run executes one directly.

.PARAMETER List
    Print the available scripts and exit.

.PARAMETER Run
    Run this script and exit, without showing the menu.

.PARAMETER Arguments
    Parameters forwarded to the script named in -Run.

.EXAMPLE
    .\Menu.ps1

.EXAMPLE
    .\Menu.ps1 -List

.EXAMPLE
    .\Menu.ps1 -Run Get-DiskSpaceReport -Arguments @{ ThresholdPercent = 20 }
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$Run,
    [hashtable]$Arguments = @{},

    # Where to put the toolkit when running from the web. Given explicitly, the
    # prompt is skipped - which is what an unattended run needs.
    [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '1.0.0'
$script:Repo = 'https://github.com/omfgnick/ops-toolkit'

<#
    Executed straight from the web -

        & ([scriptblock]::Create((irm https://.../Menu.ps1)))

    - there is no file on disk, so $PSScriptRoot is empty and the scripts this
    menu launches are nowhere to be found. In that case, fetch the repository
    into a temp folder and run from there. Started from a clone, this block is
    skipped and nothing is downloaded.
#>
if ($PSScriptRoot) {
    $script:Root = $PSScriptRoot
}
else {
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) 'ops-toolkit'
    $keepPath = Join-Path $HOME 'ops-toolkit'

    # Downloading somewhere on someone's machine is not a decision to make for
    # them silently: ask where it goes. A temp copy is fine to try things out;
    # anyone who wants to keep the toolkit should get it somewhere permanent.
    if (-not $Destination) {
        Write-Host ''
        Write-Host 'ops-toolkit is not on this machine yet. Where should it go?'
    Write-Host ''
        Write-Host '   1' -ForegroundColor Cyan -NoNewline
        Write-Host "  Temporary folder - just trying it out   $tempPath"
        Write-Host '   2' -ForegroundColor Cyan -NoNewline
        Write-Host "  Keep it - installs for real             $keepPath"
        Write-Host '   q' -ForegroundColor Cyan -NoNewline
        Write-Host '  cancel'
        Write-Host ''
    }
    # Read-Host returns null when there is no console to read from; without this
    # guard the next line would crash instead of cancelling cleanly.
    if ($Destination) {
        $script:Root = switch ($Destination) {
            'Temp' { $tempPath }
            'Keep' { $keepPath }
            default { $Destination }   # any other value is taken as a path
        }
        Write-Host "Destination: $script:Root" -ForegroundColor DarkGray
    }
    else {
        # Read-Host returns null when there is no console to read from; without
        # this guard the next line would crash instead of cancelling cleanly.
        $where = ''
        try { $where = Read-Host 'Choose' } catch { $where = '' }
        if ($null -eq $where) { $where = '' }

        switch ($where.Trim()) {
            '1' { $script:Root = $tempPath }
            '2' { $script:Root = $keepPath }
            default {
                Write-Host 'Cancelled - nothing was downloaded.' -ForegroundColor DarkGray
                exit 0
            }
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $script:Root 'powershell'))) {
        Write-Host "Downloading ops-toolkit into $script:Root ..." -ForegroundColor DarkGray
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) 'ops-toolkit.zip'
        $unpack = Join-Path ([System.IO.Path]::GetTempPath()) 'ops-toolkit-unpack'
        try {
            # TLS 1.2 matters on stock Windows PowerShell 5.1, where it is not
            # the default and GitHub refuses anything older.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri "$script:Repo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
            if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
            Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
            if (Test-Path -LiteralPath $script:Root) { Remove-Item -LiteralPath $script:Root -Recurse -Force }
            # The archive unpacks into ops-toolkit-main/; move it to a stable name
            Move-Item -LiteralPath (Join-Path $unpack 'ops-toolkit-main') -Destination $script:Root
            Remove-Item -LiteralPath $zip, $unpack -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Error "Could not download the toolkit: $($_.Exception.Message)"
            exit 1
        }
    }
    else {
        Write-Host "Using the copy already in $script:Root" -ForegroundColor DarkGray
    }

    if ($script:Root -eq $tempPath) {
        Write-Host 'This copy is in a temporary folder and the system may delete it.' -ForegroundColor DarkGray
        Write-Host "To keep it: git clone $script:Repo" -ForegroundColor DarkGray
    }
}

$script:ScriptDir = Join-Path $script:Root 'powershell'

if (-not (Test-Path -LiteralPath $script:ScriptDir)) {
    Write-Error "Script directory not found: $script:ScriptDir"
    exit 2
}

function Get-Entries {
    Get-ChildItem -LiteralPath $script:ScriptDir -Filter *.ps1 |
        Where-Object { $_.Name -notlike 'OpsToolkit.*' } |
        Sort-Object Name |
        ForEach-Object {
            $synopsis = ''
            try { $synopsis = (Get-Help $_.FullName -ErrorAction Stop).Synopsis } catch { $synopsis = '' }
            # The synopsis is often several lines; the menu needs one.
            $synopsis = ($synopsis -replace '\s+', ' ').Trim()
            if ($synopsis.Length -gt 96) { $synopsis = $synopsis.Substring(0, 93) + '...' }
            [pscustomobject]@{
                Name     = $_.BaseName
                Path     = $_.FullName
                Synopsis = $synopsis
            }
        }
}

function Invoke-Entry {
    param([pscustomobject]$Entry, [hashtable]$Params = @{})
    Write-Host ''
    Write-Host "--- $($Entry.Name) " -ForegroundColor Cyan
    Write-Host ''
    $code = 0
    try {
        & $Entry.Path @Params
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $code = 1
    }
    Write-Host ''
    if ($code -eq 0) {
        Write-Host "exit $code" -ForegroundColor Green
    }
    else {
        # Reported rather than swallowed: several scripts use 1 to signal a
        # finding, which is information, not a crash.
        Write-Host "exit $code (1 = finding or failure, 2 = bad usage)" -ForegroundColor Yellow
    }
    return $code
}

$entries = @(Get-Entries)
if ($entries.Count -eq 0) {
    Write-Error "No scripts found in $script:ScriptDir"
    exit 2
}

if ($List) {
    $entries | ForEach-Object { $_.Name }
    exit 0
}

if ($Run) {
    $entry = $entries | Where-Object { $_.Name -eq $Run } | Select-Object -First 1
    if (-not $entry) {
        Write-Error "No such script: $Run"
        exit 2
    }
    exit (Invoke-Entry -Entry $entry -Params $Arguments)
}

# ---- Interactive menu --------------------------------------------------------
while ($true) {
    Write-Host ''
    Write-Host 'ops-toolkit ' -NoNewline
    Write-Host $script:Version -ForegroundColor DarkGray
    Write-Host "$([System.Environment]::OSVersion.VersionString) - $env:COMPUTERNAME" -ForegroundColor DarkGray
    Write-Host ''

    for ($i = 0; $i -lt $entries.Count; $i++) {
        Write-Host ('  {0,2}' -f ($i + 1)) -ForegroundColor Cyan -NoNewline
        Write-Host ('  {0,-24}' -f $entries[$i].Name) -NoNewline
        Write-Host $entries[$i].Synopsis -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '   q' -ForegroundColor Cyan -NoNewline
    Write-Host '  quit'
    Write-Host ''

    $answer = Read-Host 'Choose a number'
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -in 'q', 'Q', 'quit', 'exit') { break }

    $number = 0
    if (-not [int]::TryParse($answer.Trim(), [ref]$number)) {
        Write-Host "Not a number: $answer" -ForegroundColor Yellow
        continue
    }
    if ($number -lt 1 -or $number -gt $entries.Count) {
        Write-Host "Out of range: $number" -ForegroundColor Yellow
        continue
    }

    $chosen = $entries[$number - 1]

    # Offer the script's own parameters instead of making the user recall them.
    $params = @{}
    try {
        $cmd = Get-Command $chosen.Path -ErrorAction Stop
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters +
        [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $own = $cmd.Parameters.Keys | Where-Object { $_ -notin $common }
        if ($own) {
            Write-Host ''
            Write-Host "Parameters (Enter to skip): $($own -join ', ')" -ForegroundColor DarkGray
            foreach ($p in $own) {
                $value = Read-Host "  -$p"
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    # A switch is set by presence, so any answer turns it on.
                    if ($cmd.Parameters[$p].SwitchParameter) { $params[$p] = $true }
                    else { $params[$p] = $value }
                }
            }
        }
    }
    catch {
        Write-Verbose "Could not read parameters for $($chosen.Name): $($_.Exception.Message)"
    }

    Invoke-Entry -Entry $chosen -Params $params | Out-Null

    Write-Host ''
    Read-Host 'Press Enter to return to the menu' | Out-Null
}

exit 0
