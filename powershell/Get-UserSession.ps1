<#
.SYNOPSIS
    Lists who is logged on: interactive sessions, RDP, idle time and
    disconnected sessions still holding resources.

.DESCRIPTION
    Read-only. Answers the first question of almost every support ticket -
    "who is on this machine, and since when".

    The value here is not the list of names. It is the two things that a plain
    "quser" leaves you to work out by hand:

      - a DISCONNECTED session is not a closed one. It keeps the profile
        loaded, files locked and licences taken, and it survives reboots of
        nobody's attention for weeks. Those are listed first and counted apart.
      - idle time tells you whether a session is in use or just parked.

    Falls back cleanly: quser is missing on some editions, so the session list
    is rebuilt from the Windows API when it is not there.

.PARAMETER IdleWarnHours
    Flag a session as parked after this many idle hours. Default 4.

.PARAMETER AsJson
    Emit JSON instead of the readable report.

.EXAMPLE
    .\Get-UserSession.ps1

    Prints the readable report.

.EXAMPLE
    .\Get-UserSession.ps1 -AsJson | ConvertFrom-Json | Select-Object -Expand disconnected

    Feeds a monitoring system with the count that matters.

.NOTES
    Part of ops-toolkit. Exit codes: 0 nothing worth attention, 1 a disconnected
    or long-idle session was found.
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 720)]
    [int]$IdleWarnHours = 4,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolkitVersion = '1.1.0'

<#
    'quser' prints a fixed-width table and no object. Worse, the header is
    localised, so parsing by column NAME breaks on a machine in Portuguese or
    German - which is exactly where a support script gets used.

    Parsing is done by POSITION instead, using the header row to find where each
    column starts. The first column carries a '>' for the current session, and
    that marker shifts the whole row by one character if it is not stripped.
#>
function Read-QUser {
    $saida = & quser 2>$null
    if (-not $saida -or @($saida).Count -lt 2) { return $null }

    $linhas = @($saida)
    $cab = $linhas[0]
    # Cada coluna comeca onde ha um caractere apos espaco em branco
    $inicios = @()
    for ($i = 1; $i -lt $cab.Length; $i++) {
        if ($cab[$i] -ne ' ' -and $cab[$i - 1] -eq ' ') { $inicios += $i }
    }
    $inicios = @(0) + $inicios

    $fatia = {
        param($linha, $de, $ate)
        if ($de -ge $linha.Length) { return '' }
        $fim = [Math]::Min($ate, $linha.Length)
        $linha.Substring($de, $fim - $de).Trim()
    }

    $sessoes = @()
    foreach ($linha in $linhas[1..($linhas.Count - 1)]) {
        if (-not $linha.Trim()) { continue }
        $campos = @()
        for ($c = 0; $c -lt $inicios.Count; $c++) {
            $de = $inicios[$c]
            $ate = if ($c + 1 -lt $inicios.Count) { $inicios[$c + 1] } else { $linha.Length }
            $campos += (& $fatia $linha $de $ate)
        }
        # O '>' marca a sessao atual e desalinha o nome se ficar
        $usuario = $campos[0].TrimStart('>').Trim()
        if (-not $usuario) { continue }

        $sessoes += [pscustomobject]@{
            user      = $usuario
            session   = if ($campos.Count -gt 1) { $campos[1] } else { '' }
            id        = if ($campos.Count -gt 2) { $campos[2] } else { '' }
            state     = if ($campos.Count -gt 3) { $campos[3] } else { '' }
            idleRaw   = if ($campos.Count -gt 4) { $campos[4] } else { '' }
            logonRaw  = if ($campos.Count -gt 5) { $campos[5] } else { '' }
        }
    }
    return $sessoes
}

<#
    Converte o campo de ocioso do quser em horas. Ele vem em tres formatos:
    '.' (ativo agora), 'mm' (minutos) e 'hh:mm'. Tratar tudo como numero daria
    4 horas para uma sessao ociosa ha 4 minutos.
#>
function ConvertTo-IdleTime {
    param([string]$Bruto)
    if (-not $Bruto -or $Bruto -eq '.' -or $Bruto -eq 'none') { return 0.0 }
    if ($Bruto -match '^\s*(\d+)\+?(\d+):(\d+)\s*$') {
        # dias+hh:mm
        return [double]$Matches[1] * 24 + [double]$Matches[2] + [double]$Matches[3] / 60
    }
    if ($Bruto -match '^\s*(\d+):(\d+)\s*$') {
        return [double]$Matches[1] + [double]$Matches[2] / 60
    }
    if ($Bruto -match '^\s*(\d+)\s*$') {
        return [double]$Matches[1] / 60
    }
    return 0.0
}

$sessoes = @()
$fonte = 'quser'
$bruto = $null
try { $bruto = Read-QUser } catch { $bruto = $null }

if ($bruto) {
    foreach ($s in $bruto) {
        $horas = ConvertTo-IdleTime -Bruto $s.idleRaw
        $sessoes += [pscustomobject]@{
            user         = $s.user
            session      = $s.session
            id           = $s.id
            state        = $s.state
            idle_hours   = [math]::Round($horas, 1)
            logon        = $s.logonRaw
            disconnected = ($s.state -match 'Disc')
            parked       = ($horas -ge $IdleWarnHours)
            remote       = ($s.session -match 'rdp|ica')
        }
    }
}
else {
    # quser nao existe em toda edicao do Windows. Sem ele nao ha estado de
    # sessao, entao o relatorio diz o que consegue e admite o resto.
    $fonte = 'explorer-owners'
    try {
        $donos = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue).User } |
            Where-Object { $_ } | Sort-Object -Unique
        foreach ($d in $donos) {
            $sessoes += [pscustomobject]@{
                user = $d; session = ''; id = ''; state = 'unknown'
                idle_hours = $null; logon = ''; disconnected = $false
                parked = $false; remote = $false
            }
        }
    } catch {
        Write-Verbose "Nem quser nem Win32_Process responderam: $($_.Exception.Message)"
    }
}

$desconectadas = @($sessoes | Where-Object { $_.disconnected }).Count
$paradas = @($sessoes | Where-Object { $_.parked -and -not $_.disconnected }).Count
$remotas = @($sessoes | Where-Object { $_.remote }).Count

$status = if ($desconectadas -gt 0 -or $paradas -gt 0) { 1 } else { 0 }

if ($AsJson) {
    [pscustomobject]@{
        script          = 'Get-UserSession'
        kind            = 'user_sessions'
        hostname        = $env:COMPUTERNAME
        generated_at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        source          = $fonte
        idle_warn_hours = $IdleWarnHours
        count           = @($sessoes).Count
        disconnected    = $desconectadas
        parked          = $paradas
        remote          = $remotas
        items           = @($sessoes)
        status          = $status
    } | ConvertTo-Json -Depth 6
    exit $status
}

Write-Host ''
Write-Host "User sessions - $env:COMPUTERNAME"
Write-Host ("Generated at " + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
Write-Host ''

if (@($sessoes).Count -eq 0) {
    Write-Host '  No session could be read on this machine.'
    Write-Host '  quser is absent and the fallback returned nothing.'
    exit 0
}

if ($fonte -ne 'quser') {
    Write-Host "  NOTE: quser is not available here, so session state and idle" -ForegroundColor Yellow
    Write-Host "  time are unknown. Only the logged-on users could be read." -ForegroundColor Yellow
    Write-Host ''
}

# Desconectadas primeiro: sao as que seguram recurso sem ninguem por perto
foreach ($grupo in @(
        @{ Titulo = 'DISCONNECTED - still holding the profile'; Filtro = { $_.disconnected } },
        @{ Titulo = 'PARKED - idle past the threshold'; Filtro = { $_.parked -and -not $_.disconnected } },
        @{ Titulo = 'ACTIVE'; Filtro = { -not $_.disconnected -and -not $_.parked } }
    )) {
    $itens = @($sessoes | Where-Object $grupo.Filtro)
    if ($itens.Count -eq 0) { continue }
    Write-Host ("  " + $grupo.Titulo)
    foreach ($s in $itens) {
        $ocioso = if ($null -eq $s.idle_hours) { '   ?  ' } else { ('{0,5:N1}h' -f $s.idle_hours) }
        $marca = if ($s.remote) { 'RDP' } else { '   ' }
        Write-Host ("    {0,-20} {1,-12} {2} idle {3}  {4}" -f $s.user, $s.session, $marca, $ocioso, $s.logon)
    }
    Write-Host ''
}

Write-Host ("  {0} session(s) - {1} disconnected, {2} parked, {3} remote" -f @($sessoes).Count, $desconectadas, $paradas, $remotas)
Write-Host ''
exit $status
