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
    [hashtable]$Arguments = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '1.0.0'
$script:Root = $PSScriptRoot
$script:ScriptDir = Join-Path $script:Root 'powershell'

if (-not (Test-Path -LiteralPath $script:ScriptDir)) {
    Write-Error "Script directory not found: $script:ScriptDir. Run this from a clone of the repository."
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
