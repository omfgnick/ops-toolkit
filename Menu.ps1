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
    .\Menu.ps1 -Catalog | ConvertFrom-Json

.EXAMPLE
    .\Menu.ps1 -Run Get-DiskSpaceReport -Arguments @{ ThresholdPercent = 20 }
#>
[CmdletBinding()]
param(
    [switch]$List,

    # O mesmo catalogo que o menu desenha, em JSON: serve para automacao e e o
    # que os testes verificam, em vez de reimplementar a leitura dos cabecalhos.
    [switch]$Catalog,

    [string]$Run,
    [hashtable]$Arguments = @{},

    # Where to put the toolkit when running from the web. Given explicitly, the
    # prompt is skipped - which is what an unattended run needs.
    [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '1.2.0'
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

            # Arquivo que veio da internet carrega a Marca da Web, e com a
            # politica RemoteSigned - padrao em Windows de trabalho - o
            # PowerShell recusa rodar script assim: "a execucao de scripts foi
            # desativada neste sistema". Unblock-File tira essa marca dos
            # arquivos que ACABAMOS de baixar, e de mais nada.
            Get-ChildItem -LiteralPath $script:Root -Recurse -Include *.ps1, *.psm1, *.psd1 -ErrorAction SilentlyContinue |
                Unblock-File -ErrorAction SilentlyContinue
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

<#
    Categoria, resumo e perguntas saem todos do cabecalho do proprio script.

    Um catalogo separado divergiria com o tempo - foi exatamente o que aconteceu
    com docs/, que chegou a documentar 2 dos 16 scripts sem ninguem notar. Aqui a
    unica fonte e o comentario que o script ja carrega para o Get-Help.

    Category e Ask sao lidos do texto do arquivo, e nao do Get-Help: o .NOTES
    volta como um bloco unico de texto e separar linha a linha dali seria mais
    fragil do que a expressao regular.
#>
function Get-Entry {
    Get-ChildItem -LiteralPath $script:ScriptDir -Filter *.ps1 |
        Where-Object { $_.Name -notlike 'OpsToolkit.*' } |
        Sort-Object Name |
        ForEach-Object {
            $texto = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $texto) { $texto = '' }

            $sinopse = ''
            try { $sinopse = (Get-Help $_.FullName -ErrorAction Stop).Synopsis } catch { $sinopse = '' }
            $sinopse = ($sinopse -replace '\s+', ' ').Trim()
            # A frase inteira, e nao a cortada: o corte e coisa da TELA, e o
            # -Catalog serve para automacao. O menu Bash faz igual, e as duas
            # saidas precisam concordar.

            $categoria = 'Other'
            if ($texto -match '(?m)^\s*Category:\s*(.+?)\s*$') { $categoria = $Matches[1] }

            $perguntas = @()
            foreach ($m in [regex]::Matches($texto, '(?m)^\s*Ask:\s*(-\w+)\s*\|\s*(.+?)\s*$')) {
                $perguntas += [pscustomobject]@{
                    Param = $m.Groups[1].Value.TrimStart('-')
                    Label = $m.Groups[2].Value
                }
            }

            [pscustomobject]@{
                Name     = $_.BaseName
                Path     = $_.FullName
                Synopsis = $sinopse
                Category = $categoria
                Asks     = $perguntas
            }
        }
}

# A ordem e a do dia de trabalho, e nao a alfabetica: comeca na triagem, que e o
# que se roda primeiro quando um chamado chega.
$script:CategoryOrder = @('Triage', 'Network', 'Services', 'Security', 'Backup', 'Inventory', 'Other')

function Get-CategoryRank {
    param([string]$Name)
    $i = $script:CategoryOrder.IndexOf($Name)
    if ($i -lt 0) { return $script:CategoryOrder.Count }
    return $i
}

<#
    Libera a execucao SO PARA ESTE PROCESSO do PowerShell.

    Nao altera a politica da maquina nem a do usuario: o escopo Process morre
    junto com esta janela. E o mesmo que fazer 'powershell -ExecutionPolicy
    Bypass' na mao, so que sem exigir isso de quem roda o menu.

    Se houver politica de grupo em vigor, esta chamada falha - e falhar aqui e o
    certo: o menu avisa e nao tenta contornar decisao do administrador.
#>
function Unblock-CurrentProcess {
    $atual = Get-ExecutionPolicy -Scope Process
    if ($atual -eq 'Bypass' -or $atual -eq 'Unrestricted') { return $true }
    try {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host ''
        Write-Host 'A execucao de scripts esta bloqueada nesta maquina e o menu nao conseguiu liberar' -ForegroundColor Yellow
        Write-Host 'nem para a propria sessao - provavelmente ha politica de grupo em vigor.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Abra o PowerShell assim e rode o menu de novo:' -ForegroundColor Cyan
        Write-Host '    powershell -ExecutionPolicy Bypass -NoProfile' -ForegroundColor White
        Write-Host ''
        return $false
    }
}

<#
    Pergunta o que o script exige, em vez de deixa-lo falhar com "uso incorreto".

    Ter de saber a flag de cabeca e o maior atrito do dia a dia. Quando o script
    declara Ask:, so o essencial e perguntado; sem isso, cai na lista completa de
    parametros, que e barulhenta mas ainda melhor do que adivinhar.
#>
function Read-EntryParam {
    param([pscustomobject]$Entry)

    $params = @{}
    $asks = @($Entry.Asks)

    if ($asks.Count -gt 0) {
        Write-Host ''
        Write-Host "  $($Entry.Name) needs:" -ForegroundColor DarkGray
        foreach ($a in $asks) {
            $valor = Read-Host "  $($a.Label)"
            if (-not [string]::IsNullOrWhiteSpace($valor)) { $params[$a.Param] = $valor }
        }
        return $params
    }

    try {
        $cmd = Get-Command $Entry.Path -ErrorAction Stop
        $comuns = [System.Management.Automation.PSCmdlet]::CommonParameters +
        [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $proprios = @($cmd.Parameters.Keys | Where-Object { $_ -notin $comuns })
        if ($proprios.Count -eq 0) { return $params }

        Write-Host ''
        Write-Host "  Parameters (Enter to skip): $($proprios -join ', ')" -ForegroundColor DarkGray
        foreach ($p in $proprios) {
            $valor = Read-Host "  -$p"
            if (-not [string]::IsNullOrWhiteSpace($valor)) {
                # Um switch se define pela presenca, entao qualquer resposta liga.
                if ($cmd.Parameters[$p].SwitchParameter) { $params[$p] = $true }
                else { $params[$p] = $valor }
            }
        }
    }
    catch {
        Write-Verbose "Nao consegui ler os parametros de $($Entry.Name): $($_.Exception.Message)"
    }
    return $params
}

# A lista e para escanear, nao para ler: um resumo de tres linhas some com a
# estrutura de categorias. A frase inteira continua no -Catalog e no Get-Help.
function Get-ShortSummary {
    param([string]$Text)
    if ($Text.Length -gt 66) { return $Text.Substring(0, 63) + '...' }
    return $Text
}

function Write-Rule {
    param([string]$Text)
    $largura = 52 - $Text.Length
    if ($largura -lt 1) { $largura = 1 }
    return ('-' * $largura)
}

<#
    Guardar o relatorio e metade do trabalho: anexar num chamado e o passo
    seguinte de quase toda execucao.

    A captura sai do transcript, e nao de um Tee-Object no cano: os scripts usam
    Write-Host, e redirecionar o fluxo de informacao para o cano faria a saida
    perder a cor na tela - que e onde ela e lida de fato. O transcript grava sem
    tocar no que aparece.
#>
$script:LastOutput = $null

function Invoke-Entry {
    param([pscustomobject]$Entry, [hashtable]$Params = @{})

    Write-Host ''
    Write-Host "+- $($Entry.Name) $(Write-Rule $Entry.Name)" -ForegroundColor Cyan
    Write-Host ''
    if (-not (Unblock-CurrentProcess)) { return 1 }

    $captura = Join-Path $script:RunDir ("{0}-{1}.txt" -f $Entry.Name, (Get-Date -Format 'HHmmss'))
    $gravando = $false
    try {
        Start-Transcript -LiteralPath $captura -ErrorAction Stop | Out-Null
        $gravando = $true
    }
    catch {
        Write-Verbose "Transcript indisponivel: $($_.Exception.Message)"
    }

    $code = 0
    try {
        # Tira a Marca da Web tambem de copia local que veio de download manual
        Unblock-File -LiteralPath $Entry.Path -ErrorAction SilentlyContinue
        & $Entry.Path @Params
        # Script que termina com 'return' em vez de 'exit' nunca define
        # $LASTEXITCODE, e sob Set-StrictMode le-lo LANCA em vez de dar nulo.
        # Passou a acontecer sempre que o -AsJson e usado, porque o bloco de
        # JSON encerra com 'return'.
        $code = 0
        if (Test-Path Variable:LASTEXITCODE) {
            $code = $LASTEXITCODE
            if ($null -eq $code) { $code = 0 }
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $code = 1
    }
    finally {
        if ($gravando) {
            try { Stop-Transcript | Out-Null } catch { Write-Verbose 'Transcript ja estava parado.' }
        }
    }

    if ($gravando -and (Test-Path -LiteralPath $captura)) { $script:LastOutput = $captura }

    Write-Host ''
    if ($code -eq 0) {
        Write-Host "+- done (0)" -ForegroundColor Green
    }
    else {
        # Reportado, e nao engolido: em varios scripts 1 significa "achou algo",
        # que e informacao e nao falha.
        Write-Host "+- finding or failure ($code)" -ForegroundColor Yellow
    }
    return $code
}

function Save-LastOutput {
    if (-not $script:LastOutput -or -not (Test-Path -LiteralPath $script:LastOutput)) {
        Write-Host '  Nothing to save yet.' -ForegroundColor DarkGray
        return
    }
    $padrao = Join-Path (Get-Location).Path (Split-Path -Leaf $script:LastOutput)
    $destino = Read-Host "  Save to [$padrao]"
    if ([string]::IsNullOrWhiteSpace($destino)) { $destino = $padrao }
    try {
        # O transcript enquadra a saida entre blocos de asteriscos com nome de
        # maquina e horario. Quem vai colar isso num chamado quer o relatorio,
        # e nao o cabecalho do PowerShell.
        $linhas = @(Get-Content -LiteralPath $script:LastOutput)
        $limpo = @()
        $dentro = $false
        foreach ($l in $linhas) {
            if ($l -match '^\*{10,}$') { $dentro = -not $dentro; continue }
            if (-not $dentro) { $limpo += $l }
        }
        if ($limpo.Count -eq 0) { $limpo = $linhas }
        Set-Content -LiteralPath $destino -Value $limpo -Encoding UTF8 -ErrorAction Stop
        Write-Host "  saved to $destino" -ForegroundColor Green
    }
    catch {
        Write-Host "  could not write to ${destino}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$script:AllEntries = @(Get-Entry)
if ($script:AllEntries.Count -eq 0) {
    Write-Error "No scripts found in $script:ScriptDir"
    exit 2
}

if ($List) {
    $script:AllEntries | ForEach-Object { $_.Name }
    exit 0
}

if ($Catalog) {
    $script:AllEntries |
        Sort-Object @{ Expression = { Get-CategoryRank $_.Category } }, Name |
        ForEach-Object {
            [pscustomobject]@{
                name     = $_.Name
                category = $_.Category
                summary  = $_.Synopsis
                asks     = @($_.Asks | ForEach-Object { [pscustomobject]@{ param = $_.Param; label = $_.Label } })
            }
        } | ConvertTo-Json -Depth 5
    exit 0
}

if ($Run) {
    $entry = $script:AllEntries | Where-Object { $_.Name -eq $Run } | Select-Object -First 1
    if (-not $entry) {
        Write-Error "No such script: $Run"
        exit 2
    }
    exit (Invoke-Entry -Entry $entry -Params $Arguments)
}

# A saida de cada execucao fica aqui ate o usuario decidir se guarda.
$script:RunDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ops-menu-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null

# ---- Menu interativo ---------------------------------------------------------
$script:Filter = ''

<#
    A numeracao e global e segue a ordem de exibicao, entao o numero de um script
    so muda quando o filtro muda - e o filtro fica sempre visivel no cabecalho.
#>
function Get-VisibleEntry {
    $itens = $script:AllEntries
    if ($script:Filter) {
        $f = $script:Filter
        $itens = $itens | Where-Object {
            $_.Name -like "*$f*" -or $_.Synopsis -like "*$f*" -or $_.Category -like "*$f*"
        }
    }
    # A virgula nao e enfeite: uma funcao que devolve array VAZIO entrega $null
    # a quem chamou, e sob Set-StrictMode o .Count seguinte lanca. Foi o que
    # acontecia ao filtrar por algo que nao existe.
    return , @($itens | Sort-Object @{ Expression = { Get-CategoryRank $_.Category } }, Name)
}

function Show-Board {
    param([array]$Visible)

    Write-Host ''
    Write-Host "+- ops-toolkit $script:Version" -ForegroundColor Cyan
    Write-Host '|' -ForegroundColor Cyan -NoNewline
    Write-Host "  $env:COMPUTERNAME . $([System.Environment]::OSVersion.VersionString) . $(Get-Date -Format 'HH:mm')" -ForegroundColor DarkGray
    if ($script:Filter) {
        Write-Host '|' -ForegroundColor Cyan -NoNewline
        Write-Host "  filter: $script:Filter" -ForegroundColor Yellow -NoNewline
        Write-Host '   (/ alone clears)' -ForegroundColor DarkGray
    }
    Write-Host '+' -ForegroundColor Cyan

    if ($Visible.Count -eq 0) {
        Write-Host ''
        Write-Host "  nothing matches `"$script:Filter`"" -ForegroundColor DarkGray
    }

    $atual = ''
    for ($i = 0; $i -lt $Visible.Count; $i++) {
        if ($Visible[$i].Category -ne $atual) {
            $atual = $Visible[$i].Category
            Write-Host ''
            Write-Host "  $atual"
        }
        Write-Host ('  {0,2}' -f ($i + 1)) -ForegroundColor Cyan -NoNewline
        Write-Host ('  {0,-24}' -f $Visible[$i].Name) -NoNewline
        Write-Host (Get-ShortSummary $Visible[$i].Synopsis) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  /text' -ForegroundColor Cyan -NoNewline
    Write-Host ' filter    ' -NoNewline
    Write-Host '3,7' -ForegroundColor Cyan -NoNewline
    Write-Host ' several    ' -NoNewline
    Write-Host 's' -ForegroundColor Cyan -NoNewline
    Write-Host ' save    ' -NoNewline
    Write-Host 'q' -ForegroundColor Cyan -NoNewline
    Write-Host ' quit'
    Write-Host ''
}

function Invoke-Choice {
    param([array]$Visible, [int]$Number)
    $escolhido = $Visible[$Number - 1]
    $params = Read-EntryParam -Entry $escolhido
    Invoke-Entry -Entry $escolhido -Params $params | Out-Null
}

while ($true) {
    $visiveis = Get-VisibleEntry
    Show-Board -Visible $visiveis

    $answer = Read-Host '  Choose'
    if ($null -eq $answer) { break }
    $answer = $answer.Trim()

    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -in 'q', 'Q', 'quit', 'exit') { break }

    if ($answer -eq '/') { $script:Filter = ''; continue }
    if ($answer.StartsWith('/')) { $script:Filter = $answer.Substring(1); continue }

    if ($answer -in 's', 'S') {
        Save-LastOutput
        Read-Host '  Enter to go back' | Out-Null
        continue
    }

    # "3,7,9" roda os tres em ordem: uma triagem inteira num comando so.
    if ($answer -match ',') {
        foreach ($pedaco in $answer.Split(',')) {
            $n = 0
            $pedaco = $pedaco.Trim()
            if (-not [int]::TryParse($pedaco, [ref]$n)) {
                Write-Host "  ignored: $pedaco" -ForegroundColor DarkGray
                continue
            }
            if ($n -lt 1 -or $n -gt $visiveis.Count) {
                Write-Host "  out of range: $n" -ForegroundColor DarkGray
                continue
            }
            Invoke-Choice -Visible $visiveis -Number $n
        }
    }
    else {
        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number)) {
            Write-Host "  Not a number: $answer" -ForegroundColor Yellow
            continue
        }
        if ($number -lt 1 -or $number -gt $visiveis.Count) {
            Write-Host "  Out of range: $number" -ForegroundColor Yellow
            continue
        }
        Invoke-Choice -Visible $visiveis -Number $number
    }

    # A saida fica na tela ate o usuario mandar voltar: redesenhar na hora
    # empurraria o relatorio para cima antes de alguem ler.
    Write-Host ''
    $depois = Read-Host '  Enter to go back, or "s" to save the output'
    if ($depois -and $depois.Trim() -in 's', 'S') {
        Save-LastOutput
        Read-Host '  Enter to go back' | Out-Null
    }
}

if ($script:RunDir -and (Test-Path -LiteralPath $script:RunDir)) {
    Remove-Item -LiteralPath $script:RunDir -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
