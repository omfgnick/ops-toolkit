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

## Como é na prática

Saída real, capturada da imagem Docker deste repositório — não é exemplo
inventado.

`incident-triage` — o primeiro comando quando um chamado chega:

```console
$ incident-triage
===============================================================
 INCIDENT TRIAGE — 7e40c2effda0
 2026-08-18 22:25:17 UTC
===============================================================

-- System ------------------------------------------------------
  Kernel      : Linux 6.18.33.1-microsoft-standard-WSL2
  Uptime      : unknown
  Load        : 0.28 0.38 0.36  (0.04 per core, 8 CPUs)
  Memory      : 11% used
  Fullest FS  : /etc/hosts at 4%

-- Failed units ------------------------------------------------
  none

-- Listening sockets -------------------------------------------
  (ss unavailable)

-- Recent errors (last 15) -------------------------------------
  none (or journalctl unavailable)

-- Summary -----------------------------------------------------
  Nothing alarming found.
```

`disk-space` — sinaliza o que está no ou abaixo do limiar e sai com código != 0:

```console
$ disk-space -t 25
FILESYSTEM               MOUNT                    SIZE     USED    AVAIL  FREE%  STATUS
/dev/sdd                 /etc/hosts            1006.9G    31.7G   923.9G    96%  ok

0 filesystem(s) at or below 25% free.
```

Todo script de relatório também fala JSON, validado no CI contra [schemas/](schemas/):

```console
$ disk-space -j | jq
{
  "threshold_percent": 15,
  "low_count": 0,
  "filesystems": [
    {
      "filesystem": "/dev/sdd",
      "mount": "/etc/hosts",
      "size_kb": 1055762868,
      "used_kb": 33232832,
      "available_kb": 968826564,
      "free_percent": 96,
      "low": false
    }
  ]
}
```

`backup-verify` — o backup só é dado como bom depois de restaurado e conferido
por hash contra a origem:

```console
$ backup-verify -s /tmp/conf -d /tmp/bk
Backup: /tmp/bk/conf-2026-08-18_222517.tar.gz
  source       : /tmp/conf (2 file(s), 4117 bytes)
  archive      : 192 bytes
  verification : 2 file(s) restored and checked with sha256
  result       : OK — restored and identical to the source
```

`metrics-collector -p` — pronto para o textfile collector do node_exporter:

```console
$ metrics-collector -p -s disk-space,incident-triage
# HELP ops_toolkit_up 1 when collection finished without failures
# TYPE ops_toolkit_up gauge
ops_toolkit_up 0
# HELP ops_toolkit_collect_timestamp_seconds When the collection ran
# TYPE ops_toolkit_collect_timestamp_seconds gauge
ops_toolkit_collect_timestamp_seconds 1787091917
```

## Debloat (Windows)

Separado de tudo acima, em [`debloat/`](debloat/), e propositalmente fora do menu
principal: o resto do toolkit relata o estado de uma máquina, esse altera.

```powershell
.\debloat\Invoke-Debloat.ps1                     # mostra o plano, não altera nada
.\debloat\Invoke-Debloat.ps1 -Preset Recommended -Apply
```

Nada é aplicado sem `-Apply`; um ponto de restauração é criado antes; cada chave
de registro é exportada antes de ser tocada e um script de reversão é gerado.
Veja o [debloat/README.md](debloat/README.md), inclusive a ressalva sobre o que o
CI consegue e o que não consegue verificar ali — o plano roda num Windows de
verdade, mas nada é aplicado lá.

## Menu interativo

Se preferir escolher de uma lista a decorar nomes e opções:

```bash
./menu.sh
```

```powershell
.\Menu.ps1
```

A lista é montada a partir dos próprios scripts, então um script novo aparece
sem mexer no menu — e a descrição vem do mesmo cabeçalho que alimenta o
`--help`, de modo que as duas não podem divergir.

Digite o número para executar; o que vier depois do número é repassado direto
(`7 -t 20`). O menu do PowerShell vai além e pergunta cada parâmetro do script
escolhido.

Os dois também funcionam sem menu, que é o que uma tarefa agendada precisa:

```bash
./menu.sh -l                        # lista os nomes
./menu.sh -r disk-space -t 20       # executa um direto
```

### Rodar sem clonar

Direto da web, como se faz com um instalador avulso:

```powershell
& ([scriptblock]::Create((irm "https://ops.omfgnickss.workers.dev")))
```

```bash
curl -fsSL https://ops.omfgnickss.workers.dev/sh | bash
```

Esse endereço curto é um Worker da Cloudflare que serve o launcher direto deste
repositório — ele é só um encurtador, e o cabeçalho `X-Source` da resposta diz
qual arquivo exatamente. Se preferir ver de onde o código vem antes de executar,
use a URL raw; faz a mesma coisa:

```powershell
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/Menu.ps1")))
```

```bash
curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/menu.sh | bash
```

Nesse modo não existe arquivo em disco, então o menu **pergunta onde colocar o
toolkit** antes de baixar qualquer coisa — pasta temporária se for só para
experimentar, ou permanente se quiser manter. Nada é gravado antes da resposta.

Para pular a pergunta (uso não interativo), diga o destino de antemão:

```powershell
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/Menu.ps1"))) -Destination Temp
```

```bash
DESTINATION=temp curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/menu.sh | bash
```

## Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/install.sh | bash
```

Cada script vira um comando sem o `.sh`, então `incident-triage -j` funciona de
qualquer diretório. Com `sudo` instala em `/usr/local/bin`; sem, em
`~/.local/bin`. Para desinstalar, `./install.sh -u` — ele só remove arquivos
com a marca do toolkit, preservando comando homônimo de outra origem.

Prefere container? `docker build -t ops-toolkit . && docker run --rm ops-toolkit incident-triage`.
Para inspecionar o **host** em vez do container, veja as notas no [Dockerfile](Dockerfile).

Todo comando responde `--version` e `--help`, e `man incident-triage` funciona
depois de rodar `tools/gen-man.sh` (as páginas saem do mesmo cabeçalho que
alimenta o `--help`, então não divergem).

## Convenções

Todo script segue o mesmo contrato — aprender um ensina os demais:

| Convenção | O que significa |
|---|---|
| `-h` / `--help` | Imprime o próprio cabeçalho do script: uso, opções, exemplos |
| `--dry-run` / `-WhatIf` | Tudo que altera estado pode ser simulado antes |
| `--json` / `-AsJson` | Scripts de relatório emitem saída estruturada para Grafana/Zabbix, validada no CI contra [schemas/](schemas/). Todo script Bash de relatório tem; no PowerShell os mais novos têm, e os antigos exportam com `-CsvPath`/`-HtmlPath` |
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
| `Get-PendingUpdate.ps1` | Atualizações do Windows pendentes, upgrades do winget e reboot pendente |
| `Get-IncidentTriage.ps1` | Retrato da máquina em um comando, para abrir o atendimento |
| `Test-NetworkPath.ps1` | Perda/latência de ping e checagem de portas TCP, para monitorar links |
| `Get-SecurityAudit.ps1` | Revisão de segurança somente leitura: contas, firewall, SMBv1, RDP |
| `Repair-CommonIssues.ps1` | Os reparos repetidos do helpdesk: spooler, Windows Update, rede, caches |

### Como módulo PowerShell

Os scripts continuam standalone — copiar um `.ps1` solto para um servidor segue
funcionando. Numa máquina com o toolkit inteiro, importar o módulo entrega os
mesmos scripts como comandos, com autocompletar e `Get-Help`:

```powershell
Import-Module ./powershell/OpsToolkit.psd1
Get-OpsToolkitCommand            # o que está disponível
Get-DiskSpaceReport -ThresholdPercent 20
```

Os wrappers repassam todos os parâmetros sem tocar (inclusive `-WhatIf`), então
o módulo não tem como se comportar diferente do arquivo que ele embrulha.

Referência completa: [docs/powershell.pt-BR.md](docs/powershell.pt-BR.md)

## Bash

| Script | Para que serve |
|---|---|
| `backup-folder.sh` | Backup compactado com verificação de integridade e e-mail opcional |
| `portscan-vuln.sh` | Varredura com nmap e classificação simples de risco por porta |
| `check-services.sh` | Saúde de serviços systemd, com opção de reiniciar os parados |
| `disk-space.sh` | Espaço livre por sistema de arquivos, sinalizando o que passa do limiar |
| `rotate-logs.sh` | Compacta logs antigos e remove arquivos vencidos (dry-run por padrão) |
| `check-endpoints.sh` | Disponibilidade HTTP(S), código de status e latência |
| `check-tls-expiry.sh` | Dias restantes de validade de certificados TLS |
| `incident-triage.sh` | Retrato da máquina em um comando, para abrir o atendimento |
| `net-monitor.sh` | Perda/latência de ping e checagem de portas TCP, para monitorar links |
| `audit-hardening.sh` | Revisão de segurança somente leitura: contas, sudo, SSH, permissões |
| `support-bundle.sh` | Junta estado, logs e relatórios num arquivo só para anexar no chamado |
| `net-diagnose.sh` | Percorre interface → gateway → DNS → internet e aponta a primeira falha |
| `metrics-collector.sh` | Roda os scripts de relatório e emite um JSON único, ou métricas Prometheus para o node_exporter |
| `backup-verify.sh` | Backup que só é considerado bom depois de restaurado e conferido por hash |
| `inventory.sh` | Inventário da máquina: identificação, SO, CPU, discos, rede, pacotes |
| `pending-updates.sh` | Atualizações pendentes e de segurança, idade da lista de pacotes, reboot pendente |

Referência completa: [docs/bash.pt-BR.md](docs/bash.pt-BR.md)

## Requisitos

- **PowerShell** 5.1 (Windows) ou 7.x (multiplataforma)
- **Bash** 4+ com **coreutils GNU** — testado em Ubuntu, Debian 12 e Rocky 9
  no CI. BusyBox (Alpine) *não* é suportado: seu `df`, `date` e `find` não têm
  as opções que estes scripts usam. Os scripts detectam isso e avisam, em vez
  de devolver uma resposta errada em silêncio.
- O `portscan-vuln.sh` também precisa de `nmap`; o `check-tls-expiry.sh`, de `openssl`

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
