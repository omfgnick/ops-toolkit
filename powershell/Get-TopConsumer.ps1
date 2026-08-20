<#
.SYNOPSIS
    Lists the processes eating the most CPU, memory and disk, with the account
    each one runs under.

.DESCRIPTION
    Read-only. The second question of every "this machine is slow" ticket,
    right after "who is logged on".

    On CPU there is a trap worth knowing about: the CPU property of a process
    is TOTAL SECONDS SINCE IT STARTED, not current usage. Sorting by it just
    lists whatever has been running longest - on a workstation that is almost
    always the browser or the antivirus, whether or not they are doing anything
    right now.

    This script samples twice and reports the DIFFERENCE, which is actual usage
    during the sample window, and normalises by core count so 100% means one
    machine, not one core.

.PARAMETER Top
    How many processes to list per category. Default 5.

.PARAMETER SampleSeconds
    Length of the CPU sample window. Default 2. Longer is steadier and slower.

.PARAMETER AsJson
    Emit JSON instead of the readable report.

.EXAMPLE
    .\Get-TopConsumer.ps1

    Prints the readable report.

.EXAMPLE
    .\Get-TopConsumer.ps1 -Top 10 -SampleSeconds 5 -AsJson

    Longer, steadier sample for a monitoring system.

.NOTES
    Part of ops-toolkit. Exit code is always 0: this is a report, and a busy
    machine is not by itself a fault.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$Top = 5,

    [ValidateRange(1, 60)]
    [int]$SampleSeconds = 2,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolkitVersion = '1.1.0'

$nucleos = [Environment]::ProcessorCount
if (-not $nucleos -or $nucleos -lt 1) { $nucleos = 1 }

# Dono do processo custa uma chamada por PID e nem sempre e permitida; buscar
# de uma vez e casar por PID evita repetir o custo e o erro.
$donos = @{}
try {
    Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
        $p = $_
        try {
            $u = (Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop)
            if ($u.User) { $donos[[int]$p.ProcessId] = "$($u.Domain)\$($u.User)" }
        } catch {
            # Processo de sistema costuma recusar; fica sem dono e tudo bem
        }
    }
} catch {
    Write-Verbose "Nao foi possivel enumerar donos: $($_.Exception.Message)"
}

<#
    Duas amostras da mesma metrica, com intervalo entre elas. A diferenca
    dividida pelo tempo decorrido e pelo numero de nucleos da a fracao real da
    maquina que o processo consumiu na janela.
#>
$antes = @{}
foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
    try { $antes[$p.Id] = $p.CPU } catch { }
}
$relogio = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds $SampleSeconds
$relogio.Stop()
$decorrido = [Math]::Max(0.001, $relogio.Elapsed.TotalSeconds)

$processos = @()
foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
    $cpuAgora = $null
    try { $cpuAgora = $p.CPU } catch { continue }
    if ($null -eq $cpuAgora) { continue }

    $cpuAntes = if ($antes.ContainsKey($p.Id)) { $antes[$p.Id] } else { $cpuAgora }
    $delta = [double]$cpuAgora - [double]$cpuAntes
    if ($delta -lt 0) { $delta = 0 }   # processo reiniciado com o mesmo PID

    $pct = ($delta / $decorrido / $nucleos) * 100

    $processos += [pscustomobject]@{
        pid       = $p.Id
        name      = $p.ProcessName
        cpu_pct   = [math]::Round($pct, 1)
        memory_mb = [math]::Round($p.WorkingSet64 / 1MB, 1)
        io_mb     = $null
        user      = if ($donos.ContainsKey($p.Id)) { $donos[$p.Id] } else { '' }
    }
}

# Disco: Win32_Process traz bytes acumulados de I/O, que servem para ranquear
# quem mais mexeu no disco desde que subiu.
try {
    $io = @{}
    Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
        $total = 0
        if ($_.ReadTransferCount) { $total += [double]$_.ReadTransferCount }
        if ($_.WriteTransferCount) { $total += [double]$_.WriteTransferCount }
        $io[[int]$_.ProcessId] = [math]::Round($total / 1MB, 1)
    }
    foreach ($p in $processos) {
        if ($io.ContainsKey($p.pid)) { $p.io_mb = $io[$p.pid] }
    }
} catch {
    Write-Verbose "I/O por processo indisponivel: $($_.Exception.Message)"
}

$porCpu = @($processos | Sort-Object cpu_pct -Descending | Select-Object -First $Top)
$porMem = @($processos | Sort-Object memory_mb -Descending | Select-Object -First $Top)
$porIo = @($processos | Where-Object { $null -ne $_.io_mb } | Sort-Object io_mb -Descending | Select-Object -First $Top)

# Contexto da maquina, para o ranking nao ficar solto
$memTotal = $null
$memLivre = $null
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $memTotal = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $memLivre = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
} catch {
    Write-Verbose "Memoria total indisponivel: $($_.Exception.Message)"
}

if ($AsJson) {
    [pscustomobject]@{
        script         = 'Get-TopConsumer'
        kind           = 'top_consumers'
        hostname       = $env:COMPUTERNAME
        generated_at   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        cores          = $nucleos
        sample_seconds = [math]::Round($decorrido, 2)
        memory_total_gb = $memTotal
        memory_free_gb  = $memLivre
        process_count  = @($processos).Count
        top_cpu        = $porCpu
        top_memory     = $porMem
        top_io         = $porIo
        status         = 0
    } | ConvertTo-Json -Depth 6
    exit 0
}

Write-Host ''
Write-Host "Top consumers - $env:COMPUTERNAME"
Write-Host ("Generated at " + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
Write-Host ("{0} cores - CPU sampled over {1:N1}s - 100% means the whole machine" -f $nucleos, $decorrido)
if ($null -ne $memTotal) {
    Write-Host ("Memory: {0} GB free of {1} GB" -f $memLivre, $memTotal)
}
Write-Host ''

function Show-Tabela {
    param([string]$Titulo, [array]$Itens, [string]$Campo, [string]$Unidade)
    Write-Host "  $Titulo"
    if ($Itens.Count -eq 0) {
        Write-Host '    (nothing to show)'
        Write-Host ''
        return
    }
    foreach ($i in $Itens) {
        Write-Host ("    {0,8} {1,-26} {2,9}{3}  {4}" -f $i.pid, $i.name, $i.$Campo, $Unidade, $i.user)
    }
    Write-Host ''
}

Show-Tabela -Titulo 'BY CPU (usage during the sample, not total since start)' -Itens $porCpu -Campo 'cpu_pct' -Unidade '%'
Show-Tabela -Titulo 'BY MEMORY (working set)' -Itens $porMem -Campo 'memory_mb' -Unidade ' MB'
Show-Tabela -Titulo 'BY DISK I/O (accumulated since the process started)' -Itens $porIo -Campo 'io_mb' -Unidade ' MB'

exit 0
