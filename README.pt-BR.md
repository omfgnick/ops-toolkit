# ops-toolkit

[English](README.md) · **Português (BR)**

[![CI](https://github.com/omfgnick/ops-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/omfgnick/ops-toolkit/actions/workflows/ci.yml)
[![Licença: MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-informational)](LICENSE)

Scripts de operação para infraestrutura e gestão de incidentes — monitoração,
verificação de saúde, relatórios, backup e auditoria — em **PowerShell** e **Bash**.

Escritos e usados por [Nicolas Mesquita Fernandes](https://github.com/omfgnick)
(NOC / suporte N1–N3) na rotina operacional. Todo script passa por lint e
verificação de sintaxe a cada push.

> Este repositório substitui os antigos `Powershell-Scripts` e `Bash-Scripts`;
> o histórico dos dois foi incorporado e está preservado aqui.

## Organização

```
powershell/   Operação no Windows (PowerShell 5.1+ / 7.x)
bash/         Operação no Linux (bash 4+)
tests/        Suítes de teste Pester e Bats
docs/         Referência por linguagem
```

## Convenções

Todo script segue o mesmo contrato — aprender um ensina os demais:

| Convenção | O que significa |
|---|---|
| `-h` / `--help` | Imprime o próprio cabeçalho do script: uso, opções, exemplos |
| `--dry-run` / `-WhatIf` | Tudo que altera estado pode ser simulado antes |
| `--json` | Scripts de relatório emitem saída estruturada para Grafana/Zabbix |
| Códigos de saída | `0` sucesso · `1` falha em execução · `2` uso incorreto |

As quebras de linha são impostas pelo `.gitattributes`: `.sh` sempre em **LF**
(CRLF quebra o shebang no Linux) e `.ps1` em **CRLF**. O CI falha se isso mudar.

## PowerShell

| Script | Para que serve |
|---|---|
| `backup-folder.ps1` | Backup compactado de um diretório, com notificação opcional por e-mail |
| `backup_retention.ps1` | Remove arquivos mais antigos que um limite, recursivamente |
| `Get-DiskSpaceReport.ps1` | Espaço livre por volume, sinalizando o que está abaixo do limiar |
| `Test-ServiceHealth.ps1` | Verifica serviços do Windows, com opção de reiniciar os parados |
| `Test-Endpoints.ps1` | Disponibilidade e latência HTTP/TCP de uma lista de endpoints |
| `Get-OpenPorts.ps1` | Portas TCP em escuta/estabelecidas com o processo dono |
| `Get-EventLogErrors.ps1` | Erros e avisos do log de eventos numa janela de tempo |
| `Get-TLSCertExpiry.ps1` | Dias restantes de validade de certificados TLS |
| `New-UptimeReport.ps1` | Tempo de atividade e último boot |
| `Rotate-Logs.ps1` | Rotaciona e compacta arquivos de log |
| `Cleanup-TempFiles.ps1` | Limpa diretórios temporários |
| `Audit-LocalUsers.ps1` | Contas locais, grupos e política de senha |

Referência completa: [docs/powershell.pt-BR.md](docs/powershell.pt-BR.md)

## Bash

| Script | Para que serve |
|---|---|
| `backup-folder.sh` | Backup compactado com verificação de integridade e e-mail opcional |
| `portscan-vuln.sh` | Varredura com nmap e classificação simples de risco por porta |

Referência completa: [docs/bash.pt-BR.md](docs/bash.pt-BR.md)

## Requisitos

- **PowerShell** 5.1 (Windows) ou 7.x (multiplataforma)
- **Bash** 4+; o `portscan-vuln.sh` também precisa de `nmap`

## Desenvolvimento

```bash
shellcheck -S style bash/*.sh          # precisa passar limpo
bash -n bash/<script>.sh               # sintaxe
```

```powershell
Invoke-ScriptAnalyzer -Path ./powershell -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Veja o [CONTRIBUTING.md](CONTRIBUTING.md).

## Aviso de segurança

O `portscan-vuln.sh` faz varredura ativa. Use apenas em hosts que você tem
autorização para testar.

## Licença

[MIT](LICENSE)
