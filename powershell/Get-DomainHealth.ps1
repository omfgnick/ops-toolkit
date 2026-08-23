<#
.SYNOPSIS
    Full check of a domain: DNS records, TLS chain, HTTPS answer and the e-mail
    records that decide whether your mail is trusted.

.DESCRIPTION
    Read-only. Wider than Get-TLSCertExpiry.ps1, which answers only "when does
    the certificate expire". This answers "is this domain healthy", which is the
    question behind most tickets that begin with "the site is weird".

    Two checks here catch what an expiry date misses:

      - THE CHAIN, not just the leaf certificate. One valid for another 60 days
        still breaks every client if the intermediate is missing from the
        handshake. Browsers hide this by caching the intermediate; a service
        account at 3am does not.
      - SPF and DMARC. Their absence never surfaces as an error anywhere. The
        mail simply lands in spam, quietly, for months.

.PARAMETER Domain
    One or more domains to check.

.PARAMETER WarnDays
    Warn when the certificate expires within this many days. Default 30.

.PARAMETER AsJson
    Emit JSON instead of the readable report.

.EXAMPLE
    .\Get-DomainHealth.ps1 example.com

    Prints the readable report.

.EXAMPLE
    .\Get-DomainHealth.ps1 example.com outro.com -AsJson | ConvertFrom-Json

    Feeds a monitoring system.

.NOTES
    Part of ops-toolkit. Exit codes: 0 healthy, 1 at least one finding.
#>
[CmdletBinding()]
param(
    # Sem ValueFromPipeline de proposito: o script trata o array inteiro de
    # uma vez, e aceitar pipeline sem bloco process processaria so o ultimo
    # item silenciosamente.
    [Parameter(Position = 0)]
    [string[]]$Domain,

    [ValidateRange(1, 3650)]
    [int]$WarnDays = 30,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolkitVersion = '1.2.0'

if (-not $Domain -or @($Domain).Count -eq 0) {
    throw 'No domain given. Use -Domain example.com'
}

function Resolve-Registro {
    param([string]$Nome, [string]$Tipo)
    try {
        $r = Resolve-DnsName -Name $Nome -Type $Tipo -ErrorAction Stop
        switch ($Tipo) {
            'A' { return @($r | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }) }
            'NS' { return @($r | Where-Object { $_.NameHost } | ForEach-Object { $_.NameHost }) }
            'MX' { return @($r | Where-Object { $_.NameExchange } | ForEach-Object { $_.NameExchange }) }
            'TXT' { return @($r | Where-Object { $_.Strings } | ForEach-Object { $_.Strings -join '' }) }
            default { return @() }
        }
    } catch {
        Write-Verbose "$Tipo de $Nome nao resolveu: $($_.Exception.Message)"
        return @()
    }
}

<#
    Handshake real, e nao apenas leitura do certificado: e a unica forma de ver
    se a CADEIA fecha. O callback registra o erro em vez de aceitar tudo - com
    'return $true' incondicional o teste passaria sempre e a checagem perderia o
    sentido.
#>
function Test-Cadeia {
    param([string]$Host_, [int]$Porta = 443)

    $resultado = [ordered]@{
        chain = 'failed'; subject = ''; issuer = ''; days_left = $null; error = ''
    }
    $cliente = $null
    $ssl = $null
    try {
        $cliente = New-Object System.Net.Sockets.TcpClient
        $tarefa = $cliente.ConnectAsync($Host_, $Porta)
        if (-not $tarefa.Wait(8000)) { throw 'timeout ao conectar na porta 443' }

        $erroCadeia = ''
        $ssl = New-Object System.Net.Security.SslStream($cliente.GetStream(), $false,
            [System.Net.Security.RemoteCertificateValidationCallback] {
                param($remetente, $cert, $cadeia, $erros)
                # Os tres primeiros vem da assinatura do delegate e nao sao
                # usados; descarta-los explicitamente evita apontamento do
                # analisador sem mudar a assinatura, que e fixa.
                $null = $remetente, $cert, $cadeia
                if ($erros -ne [System.Net.Security.SslPolicyErrors]::None) {
                    $script:UltimoErroTls = $erros.ToString()
                }
                # Segue o handshake para poder LER o certificado mesmo invalido,
                # mas o erro fica registrado acima e vira achado depois.
                return $true
            })
        $script:UltimoErroTls = ''
        $ssl.AuthenticateAsClient($Host_)

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $resultado.subject = $cert.Subject
        $resultado.issuer = $cert.Issuer
        $resultado.days_left = [int]([math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays))

        $erroCadeia = $script:UltimoErroTls
        if ($erroCadeia) {
            $resultado.chain = if ($erroCadeia -match 'Chain') { 'incomplete' } else { 'invalid' }
            $resultado.error = $erroCadeia
        }
        else {
            $resultado.chain = 'ok'
        }
    }
    catch {
        $resultado.error = $_.Exception.Message
    }
    finally {
        if ($ssl) { $ssl.Dispose() }
        if ($cliente) { $cliente.Dispose() }
    }
    return $resultado
}

$dominios = @()
$totalAchados = 0

foreach ($d in $Domain) {
    $achados = @()

    # O @() nao e decorativo: o PowerShell desenrola array de UM item ao
    # devolver, e sob Set-StrictMode ler .Count de uma string LANCA. Foi o que
    # derrubou a primeira execucao deste script.
    $a = @(Resolve-Registro -Nome $d -Tipo A)
    $ns = @(Resolve-Registro -Nome $d -Tipo NS)
    $mx = @(Resolve-Registro -Nome $d -Tipo MX)
    $txt = @(Resolve-Registro -Nome $d -Tipo TXT)
    $dmarcTxt = @(Resolve-Registro -Nome "_dmarc.$d" -Tipo TXT)

    $spf = @($txt | Where-Object { $_ -match 'v=spf1' })
    $dmarc = @($dmarcTxt | Where-Object { $_ -match 'v=DMARC1' })

    if (@($a).Count -eq 0) { $achados += @{ severity = 'high'; area = 'dns'; message = 'no A record: the name does not resolve' } }
    if (@($ns).Count -eq 0) { $achados += @{ severity = 'medium'; area = 'dns'; message = 'no NS record returned' } }
    if (@($mx).Count -gt 0) {
        # SPF e DMARC so importam se o dominio troca e-mail
        if (@($spf).Count -eq 0) { $achados += @{ severity = 'medium'; area = 'mail'; message = 'no SPF record: your mail is easier to spoof' } }
        if (@($dmarc).Count -eq 0) { $achados += @{ severity = 'medium'; area = 'mail'; message = 'no DMARC record: nobody is told what to do with fakes' } }
    }

    $tls = Test-Cadeia -Host_ $d
    if ($tls.chain -eq 'failed') {
        $achados += @{ severity = 'high'; area = 'tls'; message = "no TLS handshake on port 443: $($tls.error)" }
    }
    elseif ($tls.chain -ne 'ok') {
        $achados += @{ severity = 'high'; area = 'tls'; message = "chain does not verify ($($tls.error)): an intermediate is probably missing" }
    }
    if ($null -ne $tls.days_left) {
        if ($tls.days_left -lt 0) {
            $achados += @{ severity = 'high'; area = 'tls'; message = "certificate EXPIRED $([math]::Abs($tls.days_left)) day(s) ago" }
        }
        elseif ($tls.days_left -le $WarnDays) {
            $achados += @{ severity = 'high'; area = 'tls'; message = "certificate expires in $($tls.days_left) day(s)" }
        }
    }

    $httpCode = 0
    $httpFinal = ''
    try {
        $resposta = Invoke-WebRequest -Uri "https://$d" -MaximumRedirection 5 -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
        $httpCode = [int]$resposta.StatusCode
        $httpFinal = $resposta.BaseResponse.ResponseUri.AbsoluteUri
    }
    catch {
        # Sob Set-StrictMode, ler uma propriedade que a excecao nao tem LANCA em
        # vez de devolver nulo - e nem toda falha de rede traz .Response. Foi
        # isso que derrubou o job Windows: um dominio que nao responde virava
        # excecao dentro do catch.
        $resp = $_.Exception.PSObject.Properties['Response']
        if ($resp -and $resp.Value) {
            try { $httpCode = [int]$resp.Value.StatusCode } catch { $httpCode = 0 }
        }
        Write-Verbose "HTTPS de $d : $($_.Exception.Message)"
    }
    if ($httpCode -eq 0) { $achados += @{ severity = 'high'; area = 'http'; message = 'no answer over HTTPS' } }
    elseif ($httpCode -ge 500) { $achados += @{ severity = 'high'; area = 'http'; message = "server answers $httpCode" } }
    elseif ($httpCode -ge 400) { $achados += @{ severity = 'medium'; area = 'http'; message = "server answers $httpCode" } }

    $totalAchados += @($achados).Count

    $dominios += [pscustomobject]@{
        domain         = $d
        a              = $a
        ns             = $ns
        mx             = $mx
        spf            = ($spf.Count -gt 0)
        dmarc          = ($dmarc.Count -gt 0)
        cert_subject   = $tls.subject
        cert_issuer    = $tls.issuer
        cert_days_left = $tls.days_left
        cert_chain     = $tls.chain
        http_code      = $httpCode
        http_final_url = $httpFinal
        findings       = @($achados | ForEach-Object { [pscustomobject]$_ })
    }
}

$status = if ($totalAchados -gt 0) { 1 } else { 0 }

if ($AsJson) {
    [pscustomobject]@{
        script        = 'Get-DomainHealth'
        kind          = 'domain_health'
        hostname      = $env:COMPUTERNAME
        generated_at  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        warn_days     = $WarnDays
        count         = @($dominios).Count
        finding_count = $totalAchados
        items         = @($dominios)
        status        = $status
    } | ConvertTo-Json -Depth 8
    exit $status
}

Write-Host ''
Write-Host 'Domain health'
Write-Host ("Generated at " + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
Write-Host ''

foreach ($x in $dominios) {
    Write-Host ("  " + $x.domain)
    Write-Host ("    {0,-14} {1}" -f 'A', $(if (@($x.a).Count) { @($x.a) -join ' ' } else { '-' }))
    Write-Host ("    {0,-14} {1}" -f 'NS', $(if (@($x.ns).Count) { @($x.ns) -join ' ' } else { '-' }))
    Write-Host ("    {0,-14} {1}" -f 'MX', $(if (@($x.mx).Count) { @($x.mx) -join ' ' } else { '-' }))
    Write-Host ("    {0,-14} {1}" -f 'SPF', $(if ($x.spf) { 'present' } else { 'MISSING' }))
    Write-Host ("    {0,-14} {1}" -f 'DMARC', $(if ($x.dmarc) { 'present' } else { 'MISSING' }))
    Write-Host ("    {0,-14} {1}" -f 'TLS chain', $x.cert_chain)
    if ($x.cert_issuer) { Write-Host ("    {0,-14} {1}" -f 'Issued by', $x.cert_issuer) }
    if ($null -ne $x.cert_days_left) { Write-Host ("    {0,-14} {1} day(s)" -f 'Expires in', $x.cert_days_left) }
    Write-Host ("    {0,-14} {1}  {2}" -f 'HTTPS', $x.http_code, $x.http_final_url)

    if (@($x.findings).Count -gt 0) {
        Write-Host ''
        Write-Host '    Findings'
        foreach ($f in $x.findings) {
            Write-Host ("      [{0,-6}] {1,-5} {2}" -f $f.severity, $f.area, $f.message)
        }
    }
    Write-Host ''
}

Write-Host ("  {0} finding(s) across {1} domain(s)" -f $totalAchados, @($dominios).Count)
Write-Host ''
exit $status
