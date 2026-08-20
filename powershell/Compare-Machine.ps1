<#
.SYNOPSIS
    Answers "why does it only fail on that machine" by putting two machines side
    by side: OS, hotfixes, installed software, services and network.

.DESCRIPTION
    Read-only. It does NOT log into anything: remote access needs credentials,
    and a script that asks for them is a script nobody should run. It works in
    two steps instead - each machine exports its own fingerprint, and the
    comparison happens wherever you have both files.

        on machine A:   .\Compare-Machine.ps1 -Export a.fp
        on machine B:   .\Compare-Machine.ps1 -Export b.fp
        anywhere:       .\Compare-Machine.ps1 -Reference a.fp -Difference b.fp

    The fingerprint is plain sorted text, one "section|key|value" per line - the
    same format the Bash version writes, so a Linux export and a Windows export
    can be compared against each other. Plain text on purpose: you can read it,
    diff it and paste it into a ticket with no tooling at all.

    Services are read as ENABLED (start type), not as currently running. What is
    up right now changes minute to minute; what is set to start is configuration,
    and configuration is what differs between two machines.

.PARAMETER Export
    Write this machine's fingerprint to this path.

.PARAMETER Reference
    First fingerprint file to compare (machine A).

.PARAMETER Difference
    Second fingerprint file to compare (machine B).

.PARAMETER ShowEqual
    Also list what is identical, not only what differs.

.PARAMETER AsJson
    Emit JSON instead of the readable report.

.EXAMPLE
    .\Compare-Machine.ps1 -Export C:\temp\prod.fp

    Exports this machine's fingerprint.

.EXAMPLE
    .\Compare-Machine.ps1 -Reference prod.fp -Difference homolog.fp

    Compares two machines.

.NOTES
    Part of ops-toolkit. Exit codes: 0 no differences, 1 differences found.
#>
[CmdletBinding()]
param(
    [string]$Export,
    [string]$Reference,
    [string]$Difference,
    [switch]$ShowEqual,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolkitVersion = '1.1.0'

if ($Export -and ($Reference -or $Difference)) {
    throw 'Pick one: -Export writes a fingerprint, -Reference/-Difference compare two.'
}
if (-not $Export -and -not ($Reference -and $Difference)) {
    throw 'Nothing to do. Use -Export FILE, or -Reference A -Difference B.'
}

# Uma linha do fingerprint. Qualquer '|' no valor viraria coluna extra na
# comparacao, entao vira '/'.
function Write-Entrada {
    param([string]$Secao, [string]$Chave, $Valor)
    $v = "$Valor" -replace '\|', '/' -replace "`r|`n", ' '
    "$Secao|$Chave|$v"
}

function Get-Fingerprint {
    $linhas = New-Object System.Collections.Generic.List[string]

    $linhas.Add((Write-Entrada 'os' 'hostname' $env:COMPUTERNAME))
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $linhas.Add((Write-Entrada 'os' 'name' $os.Caption))
        $linhas.Add((Write-Entrada 'os' 'version' $os.Version))
        $linhas.Add((Write-Entrada 'os' 'build' $os.BuildNumber))
        $linhas.Add((Write-Entrada 'os' 'arch' $os.OSArchitecture))
        $linhas.Add((Write-Entrada 'hw' 'memory_gb' ([math]::Round($os.TotalVisibleMemorySize / 1MB, 1))))
    } catch {
        Write-Verbose "Win32_OperatingSystem indisponivel: $($_.Exception.Message)"
    }

    try {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
        $linhas.Add((Write-Entrada 'hw' 'cpu_model' $cpu.Name))
        $linhas.Add((Write-Entrada 'hw' 'cpu_count' $env:NUMBER_OF_PROCESSORS))
    } catch {
        Write-Verbose "Win32_Processor indisponivel: $($_.Exception.Message)"
    }

    # Hotfixes: a diferenca que mais explica "so nessa maquina"
    try {
        foreach ($h in Get-HotFix -ErrorAction Stop) {
            $linhas.Add((Write-Entrada 'hotfix' $h.HotFixID ($h.InstalledOn -as [string])))
        }
    } catch {
        Write-Verbose "Get-HotFix indisponivel: $($_.Exception.Message)"
    }

    <#
        Software instalado sai do registro, e das DUAS arvores: a de 64 bits e a
        WOW6432Node. Ler so uma esconde metade dos programas numa maquina de 64
        bits, e a diferenca aparece como "esse programa nao existe la" quando
        existe.
    #>
    $chaves = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($ch in $chaves) {
        try {
            Get-ItemProperty -Path $ch -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                ForEach-Object {
                    $linhas.Add((Write-Entrada 'software' $_.DisplayName ($_.DisplayVersion -as [string])))
                }
        } catch {
            Write-Verbose "Registro $ch indisponivel: $($_.Exception.Message)"
        }
    }

    # Servicos por tipo de INICIO, nao por estado atual
    try {
        Get-CimInstance Win32_Service -ErrorAction Stop |
            Where-Object { $_.StartMode -ne 'Disabled' } |
            ForEach-Object {
                $linhas.Add((Write-Entrada 'service' $_.Name $_.StartMode))
            }
    } catch {
        Write-Verbose "Win32_Service indisponivel: $($_.Exception.Message)"
    }

    try {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '169.254.*' } |
            ForEach-Object {
                $linhas.Add((Write-Entrada 'net' $_.InterfaceAlias "$($_.IPAddress)/$($_.PrefixLength)"))
            }
    } catch {
        Write-Verbose "Get-NetIPAddress indisponivel: $($_.Exception.Message)"
    }

    return @($linhas | Sort-Object -Unique)
}

# ---- Exportar ---------------------------------------------------------------
if ($Export) {
    $fp = Get-Fingerprint
    Set-Content -LiteralPath $Export -Value $fp -Encoding ASCII
    if ($AsJson) {
        [pscustomobject]@{
            script = 'Compare-Machine'; kind = 'fingerprint_export'
            hostname = $env:COMPUTERNAME
            generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            file = $Export; lines = @($fp).Count; status = 0
        } | ConvertTo-Json -Depth 4
    }
    else {
        Write-Host "Fingerprint of $env:COMPUTERNAME written to $Export ($(@($fp).Count) entries)."
        Write-Host 'Run the same on the other machine, then compare:'
        Write-Host "  .\Compare-Machine.ps1 -Reference $Export -Difference outra.fp"
    }
    exit 0
}

# ---- Comparar ---------------------------------------------------------------
foreach ($f in @($Reference, $Difference)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Cannot read fingerprint: $f" }
}

function Read-Fingerprint {
    param([string]$Caminho)
    $mapa = @{}
    foreach ($linha in Get-Content -LiteralPath $Caminho) {
        if (-not $linha.Trim()) { continue }
        $p = $linha.Split('|', 3)
        if ($p.Count -lt 3) { continue }
        $mapa["$($p[0])|$($p[1])"] = $p[2]
    }
    return $mapa
}

$mA = Read-Fingerprint -Caminho $Reference
$mB = Read-Fingerprint -Caminho $Difference

$hostA = if ($mA.ContainsKey('os|hostname')) { $mA['os|hostname'] } else { Split-Path -Leaf $Reference }
$hostB = if ($mB.ContainsKey('os|hostname')) { $mB['os|hostname'] } else { Split-Path -Leaf $Difference }

$diferentes = @()
$iguais = @()
$soA = @()
$soB = @()

foreach ($k in $mA.Keys) {
    if ($mB.ContainsKey($k)) {
        $p = $k.Split('|', 2)
        if ($mA[$k] -eq $mB[$k]) {
            $iguais += [pscustomobject]@{ section = $p[0]; key = $p[1]; value = $mA[$k] }
        }
        else {
            $diferentes += [pscustomobject]@{ section = $p[0]; key = $p[1]; a = $mA[$k]; b = $mB[$k] }
        }
    }
    else {
        $p = $k.Split('|', 2)
        $soA += [pscustomobject]@{ section = $p[0]; key = $p[1]; value = $mA[$k] }
    }
}
foreach ($k in $mB.Keys) {
    if (-not $mA.ContainsKey($k)) {
        $p = $k.Split('|', 2)
        $soB += [pscustomobject]@{ section = $p[0]; key = $p[1]; value = $mB[$k] }
    }
}

$diferentes = @($diferentes | Sort-Object section, key)
$soA = @($soA | Sort-Object section, key)
$soB = @($soB | Sort-Object section, key)

$total = @($diferentes).Count + @($soA).Count + @($soB).Count
$status = if ($total -gt 0) { 1 } else { 0 }

if ($AsJson) {
    [pscustomobject]@{
        script       = 'Compare-Machine'
        kind         = 'machine_comparison'
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        host_a       = $hostA
        host_b       = $hostB
        same_count   = @($iguais).Count
        differ_count = @($diferentes).Count
        only_a_count = @($soA).Count
        only_b_count = @($soB).Count
        differences  = $diferentes
        only_in_a    = $soA
        only_in_b    = $soB
        status       = $status
    } | ConvertTo-Json -Depth 6
    exit $status
}

Write-Host ''
Write-Host 'Machine comparison'
Write-Host ("Generated at " + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
Write-Host ("  A: {0}   ({1})" -f $hostA, $Reference)
Write-Host ("  B: {0}   ({1})" -f $hostB, $Difference)
Write-Host ''

if (@($diferentes).Count -gt 0) {
    Write-Host ("  DIFFERENT ({0})" -f @($diferentes).Count)
    $secaoAtual = ''
    foreach ($d in $diferentes) {
        if ($d.section -ne $secaoAtual) { $secaoAtual = $d.section; Write-Host "    [$secaoAtual]" }
        Write-Host ("      {0,-32} A: {1}" -f $d.key, $d.a)
        Write-Host ("      {0,-32} B: {1}" -f '', $d.b)
    }
    Write-Host ''
}
if (@($soA).Count -gt 0) {
    Write-Host ("  ONLY ON A ({0})" -f @($soA).Count)
    foreach ($d in $soA) { Write-Host ("      {0,-10} {1,-32} {2}" -f $d.section, $d.key, $d.value) }
    Write-Host ''
}
if (@($soB).Count -gt 0) {
    Write-Host ("  ONLY ON B ({0})" -f @($soB).Count)
    foreach ($d in $soB) { Write-Host ("      {0,-10} {1,-32} {2}" -f $d.section, $d.key, $d.value) }
    Write-Host ''
}
if ($ShowEqual) {
    Write-Host ("  IDENTICAL ({0})" -f @($iguais).Count)
    foreach ($d in @($iguais | Sort-Object section, key)) {
        Write-Host ("      {0,-10} {1,-32} {2}" -f $d.section, $d.key, $d.value)
    }
    Write-Host ''
}

Write-Host ("  {0} identical, {1} different, {2} only on A, {3} only on B" -f `
    @($iguais).Count, @($diferentes).Count, @($soA).Count, @($soB).Count)
Write-Host ''
exit $status
