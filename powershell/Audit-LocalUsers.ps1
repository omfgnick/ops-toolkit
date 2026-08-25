<#
.SYNOPSIS
    Audits local user accounts for common hardening findings.

.DESCRIPTION
    Lists local users with their enabled state, password-expiry setting and last
    logon, and highlights potential issues: enabled accounts whose password
    never expires, members of the local Administrators group, and accounts that
    have never logged on. Also lists the current Administrators membership.
    Read-only. Optionally exports the user table to CSV.

.PARAMETER CsvPath
    If provided, writes the user table to this CSV file.

.EXAMPLE
    .\Audit-LocalUsers.ps1

.EXAMPLE
    .\Audit-LocalUsers.ps1 -CsvPath .\localusers.csv -Verbose

.NOTES
    Category: Security
#>
[CmdletBinding()]
param(
    [string]$CsvPath,

    # Contrato do toolkit: todo relatorio sabe falar JSON
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) {
    throw "Get-LocalUser is not available on this system (requires the Microsoft.PowerShell.LocalAccounts module)."
}

# Resolve Administrators group membership once (by SID, so it is locale-neutral).
$adminSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$adminGroup = Get-LocalGroup -SID $adminSid
$adminMembers = @(Get-LocalGroupMember -Group $adminGroup |
    ForEach-Object { ($_.Name -split '\\')[-1] })

$users = Get-LocalUser | ForEach-Object {
    $isAdmin = $adminMembers -contains $_.Name

    $findings = [System.Collections.Generic.List[string]]::new()
    if ($_.Enabled -and -not $_.PasswordExpires -and $_.PasswordRequired) {
        $findings.Add('PasswordNeverExpires')
    }
    if ($_.Enabled -and -not $_.PasswordRequired) {
        $findings.Add('NoPasswordRequired')
    }
    if ($isAdmin -and $_.Enabled) {
        $findings.Add('EnabledAdmin')
    }
    if ($null -eq $_.LastLogon) {
        $findings.Add('NeverLoggedOn')
    }

    [pscustomobject]@{
        Name           = $_.Name
        Enabled        = $_.Enabled
        IsAdmin        = $isAdmin
        PasswordExpires = $_.PasswordExpires
        PasswordRequired = $_.PasswordRequired
        LastLogon      = $_.LastLogon
        Findings       = ($findings -join ', ')
    }
}

Write-Host "Administrators group members: $($adminMembers -join ', ')" -ForegroundColor Cyan
Write-Host ""

$flagged = $users | Where-Object { $_.Findings }
if ($flagged) {
    Write-Warning "$($flagged.Count) account(s) have findings worth reviewing."
}

if ($CsvPath) {
    $users | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Verbose "CSV written to $CsvPath"
}

# JSON com envelope: o mesmo formato em todos os scripts, e assim
# quem consome nao precisa adivinhar se veio objeto ou lista. Um
# ConvertTo-Json direto colapsaria lista de um item em objeto.
if ($AsJson) {
    [pscustomobject]@{
        script       = 'Audit-LocalUsers'
        kind         = 'local_users'
        hostname     = $env:COMPUTERNAME
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        count        = @($users).Count
        items        = @($users)
    } | ConvertTo-Json -Depth 6
    return
}
$users
