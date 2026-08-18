# PowerShell Scripts

[English](README.md) · **Português (BR)**

[![Lint](https://github.com/omfgnick/Powershell-Scripts/actions/workflows/lint.yml/badge.svg)](https://github.com/omfgnick/Powershell-Scripts/actions/workflows/lint.yml)

Utilitários PowerShell pequenos e autocontidos para tarefas de infraestrutura no
Windows.

## Scripts

### `backup-folder.ps1`
Cria um backup compactado (`.zip`) de uma pasta, verifica se o arquivo pode ser
aberto e enumerado e, opcionalmente, envia um relatório de status por e-mail.

```powershell
.\backup-folder.ps1 -SourcePath "C:\Data" -DestinationPath "D:\Backups"

.\backup-folder.ps1 -SourcePath "C:\Data" -DestinationPath "D:\Backups" `
    -SmtpServer smtp.example.com -MailTo ops@example.com -MailFrom backup@example.com
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-SourcePath` | Diretório a ser copiado (obrigatório) | — |
| `-DestinationPath` | Onde o `.zip` é gravado (criado se não existir, obrigatório) | — |
| `-SmtpServer` | Servidor SMTP para notificação (omitir = sem e-mail) | — |
| `-MailTo` | Destinatário do e-mail de status | — |
| `-MailFrom` | Remetente do e-mail de status | `backup@localhost` |

Suporta `-WhatIf` / `-Verbose`.

### `backup_retention.ps1`
Aplica uma política de retenção a uma pasta: arquivos mais antigos que a janela
de retenção são compactados em `.zip` individuais e os originais removidos;
arquivos `.zip` que já estejam além da janela são apagados.

```powershell
.\backup_retention.ps1 -FolderPath "C:\Logs" -DaysToKeep 30

.\backup_retention.ps1 -FolderPath "C:\Logs" -WhatIf   # apenas prévia
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-FolderPath` | Pasta raiz processada recursivamente (obrigatório) | — |
| `-DaysToKeep` | Limite de idade em dias | `30` |

Arquivos antigos são removidos **antes** de novos serem criados, então um
arquivo recém-gravado nunca é apagado na mesma execução. Suporta `-WhatIf` /
`-Verbose`.

### `Get-DiskSpaceReport.ps1`
Reporta o uso de discos fixos de uma ou mais máquinas e sinaliza volumes abaixo
de um limite de espaço livre. Pode exportar para CSV/HTML.

```powershell
.\Get-DiskSpaceReport.ps1
.\Get-DiskSpaceReport.ps1 -ComputerName SRV01,SRV02 -ThresholdPercent 10 -HtmlPath .\disk.html
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-ComputerName` | Máquinas a consultar | máquina local |
| `-ThresholdPercent` | % livre a partir da qual um volume é marcado como `LOW` | `15` |
| `-CsvPath` / `-HtmlPath` | Caminhos de exportação opcionais | — |

A máquina local é consultada sem WinRM (sessão CIM/DCOM local); máquinas remotas
usam WS-Man.

### `Test-ServiceHealth.ps1`
Verifica serviços do Windows e, opcionalmente, reinicia os que não estão em
execução.

```powershell
.\Test-ServiceHealth.ps1 -Name Spooler,W32Time
.\Test-ServiceHealth.ps1 -InputFile .\services.txt -AutoRestart -WhatIf
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-Name` | Nome(s) do serviço; aceita entrada por pipeline | — |
| `-InputFile` | Arquivo texto, um serviço por linha (comentários com `#`) | — |
| `-AutoRestart` | Inicia qualquer serviço que não esteja em execução | desligado |

Suporta `-WhatIf` / `-Verbose`.

### `Test-Endpoints.ps1`
Faz health-check de endpoints — `host:porta` (TCP) e `http(s)://` (HTTP) —
reportando disponibilidade, status e latência.

```powershell
.\Test-Endpoints.ps1 -Target "example.com:443","https://example.com"
.\Test-Endpoints.ps1 -InputFile .\endpoints.txt -CsvPath .\health.csv
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-Target` | Endpoint(s); aceita entrada por pipeline | — |
| `-InputFile` | Arquivo texto, um alvo por linha (comentários com `#`) | — |
| `-TimeoutSeconds` | Timeout HTTP por requisição | `10` |
| `-CsvPath` | Caminho de exportação CSV opcional | — |

### `Get-OpenPorts.ps1`
Lista as portas TCP locais com o processo dono — contraparte Windows do
`portscan-vuln.sh` em Bash (inspeção local, não um scanner remoto).

```powershell
.\Get-OpenPorts.ps1
.\Get-OpenPorts.ps1 -State Established -Port 443,3389 -CsvPath .\ports.csv
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-State` | Estado(s) TCP: `Listen`, `Established`, `TimeWait`, `CloseWait`, `All` | `Listen` |
| `-Port` | Filtra para porta(s) local(is) específica(s) | todas |
| `-CsvPath` | Caminho de exportação CSV opcional | — |

### `Get-EventLogErrors.ps1`
Coleta eventos de Erro/Aviso dos logs do Windows em uma janela recente e os
resume por fonte (ou retorna os eventos individuais com `-Detailed`).

```powershell
.\Get-EventLogErrors.ps1 -Hours 12
.\Get-EventLogErrors.ps1 -LogName System -Level Error -Detailed -CsvPath .\errors.csv
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-LogName` | Logs a consultar | `System, Application` |
| `-Hours` | Janela de retroação em horas | `24` |
| `-Level` | `Error`, `Warning` ou ambos | ambos |
| `-Detailed` | Retorna eventos individuais em vez do resumo | desligado |
| `-CsvPath` | Caminho de exportação CSV opcional | — |

### `Get-TLSCertExpiry.ps1`
Verifica o certificado TLS de um ou mais hosts e reporta os dias até expirar,
sinalizando `EXPIRING` / `EXPIRED`.

```powershell
.\Get-TLSCertExpiry.ps1 -Target github.com,example.com:443
.\Get-TLSCertExpiry.ps1 -InputFile .\hosts.txt -WarnDays 45 -CsvPath .\certs.csv
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-Target` | Host(s) como `host` ou `host:porta`; aceita entrada por pipeline | — |
| `-InputFile` | Arquivo texto, um host por linha (comentários com `#`) | — |
| `-WarnDays` | Sinaliza certificados que expiram dentro desses dias | `30` |
| `-TimeoutSeconds` | Timeout de conexão por host | `10` |
| `-CsvPath` | Caminho de exportação CSV opcional | — |

A confiança do certificado **não** é validada — o script apenas lê o certificado
apresentado para inspecionar a data de expiração.

### `Audit-LocalUsers.ps1`
Audita contas de usuários locais em busca de achados comuns de hardening: contas
habilitadas cuja senha nunca expira, contas sem senha exigida, membros do grupo
local Administradores e contas que nunca fizeram logon. Somente leitura.

```powershell
.\Audit-LocalUsers.ps1
.\Audit-LocalUsers.ps1 -CsvPath .\localusers.csv -Verbose
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-CsvPath` | Caminho de exportação CSV opcional | — |

A pertinência ao grupo Administradores é resolvida por SID (`S-1-5-32-544`),
então funciona independentemente do idioma do sistema.

### `Rotate-Logs.ps1`
Faz rotação de arquivos de log: comprime logs mais antigos que um limite e apaga
arquivos além do período de retenção. Arquivos antigos são removidos antes de
novos serem criados.

```powershell
.\Rotate-Logs.ps1 -Path C:\inetpub\logs -CompressAfterDays 7 -DeleteAfterDays 60
.\Rotate-Logs.ps1 -Path C:\Logs -Filter *.txt -WhatIf
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-Path` | Pasta raiz com os logs (recursivo, obrigatório) | — |
| `-Filter` | Curinga para os arquivos de log a rotacionar | `*.log` |
| `-CompressAfterDays` | Comprime logs mais antigos que isto | `7` |
| `-DeleteAfterDays` | Apaga `.zip` mais antigos que isto | `90` |

Suporta `-WhatIf` / `-Verbose`.

### `Cleanup-TempFiles.ps1`
Remove arquivos temporários antigos e reporta quanto espaço foi recuperado.
**Prévia (dry run) por padrão** — nada é apagado a menos que `-Execute` seja
informado.

```powershell
.\Cleanup-TempFiles.ps1                      # prévia dos locais padrão
.\Cleanup-TempFiles.ps1 -OlderThanDays 3 -Execute
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-Path` | Pastas a limpar | `%TEMP%`, `Windows\Temp`, INetCache |
| `-OlderThanDays` | Só remove arquivos mais antigos que isto | `7` |
| `-Execute` | Realmente apaga (do contrário, apenas prévia) | desligado |

Arquivos bloqueados/em uso são ignorados com segurança. Suporta `-WhatIf` /
`-Confirm`.

### `New-UptimeReport.ps1`
Executa health-checks de endpoints e gera um relatório HTML de disponibilidade
autocontido e colorido. Reaproveita o `Test-Endpoints.ps1` quando presente.

```powershell
.\New-UptimeReport.ps1 -Target "example.com:443","https://example.com"
.\New-UptimeReport.ps1 -InputFile .\endpoints.txt -OutputPath .\status.html
```

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `-Target` | Endpoint(s); aceita entrada por pipeline | — |
| `-InputFile` | Arquivo texto, um alvo por linha (comentários com `#`) | — |
| `-OutputPath` | Caminho do relatório HTML | `.\uptime-report.html` |
| `-TimeoutSeconds` | Timeout por requisição | `10` |

## Requisitos

- Windows PowerShell 5.1+ ou PowerShell 7+
- `Send-MailMessage` (opcional; apenas para notificações por e-mail)
- Cmdlets CIM / `Get-NetTCPConnection` / `Get-WinEvent` / `Get-LocalUser`
  (nativos no Windows moderno)
- O `Audit-LocalUsers.ps1` lê a pertinência ao grupo Administradores; execute
  como administrador para resultados completos

## Notas de segurança

Scripts que alteram ou apagam dados (`backup_retention.ps1`, `Rotate-Logs.ps1`,
`Cleanup-TempFiles.ps1`, `Test-ServiceHealth.ps1 -AutoRestart`) suportam
`-WhatIf`. Faça a prévia primeiro:

```powershell
.\Cleanup-TempFiles.ps1 -WhatIf -Verbose
```

## Uso

```powershell
# Visualize com segurança qualquer script antes de executá-lo de verdade:
.\backup_retention.ps1 -FolderPath "C:\Logs" -WhatIf -Verbose
```

## Integração contínua

Todo push para a `main` e todo pull request executa o
[workflow de Lint](.github/workflows/lint.yml):

- **PSScriptAnalyzer** com base no
  [`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1). O build falha
  em qualquer `Error`/`Warning`. A regra `PSAvoidUsingWriteHost` é desabilitada
  de propósito (veja a justificativa no arquivo de configuração).
- **Parse check** — cada arquivo `.ps1` é analisado para detectar erros de
  sintaxe.

Rode as mesmas verificações localmente antes do push:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```
