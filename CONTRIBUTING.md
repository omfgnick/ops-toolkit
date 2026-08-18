# Contribuindo

Obrigado pelo interesse. Este repositório reúne scripts de operação em
PowerShell (`powershell/`) e Bash (`bash/`).

## Antes de abrir um PR

O CI roda automaticamente, mas dá para verificar tudo localmente:

```bash
# Bash
shellcheck -S style bash/*.sh
bash -n bash/algum-script.sh
bats tests/bash            # se tiver o bats instalado
```

```powershell
# PowerShell
Invoke-ScriptAnalyzer -Path ./powershell -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester ./tests/powershell
```

## Padrões

- **Quebras de linha**: `.sh` sempre em LF, `.ps1` em CRLF. O `.gitattributes`
  cuida disso — não desative. Um `.sh` com CRLF falha em Linux com
  `bad interpreter`.
- **Cabeçalho**: todo script começa com o bloco padrão (descrição, uso,
  variáveis de ambiente, exemplos, requisitos). É ele que alimenta o `-h`.
- **Segurança**: scripts que alteram estado precisam de `--dry-run` (Bash) ou
  `SupportsShouldProcess`/`-WhatIf` (PowerShell).
- **Saída**: scripts de relatório oferecem `--json` para integração com
  Grafana/Zabbix, além da saída legível.
- **Sem apontamentos**: ShellCheck em `-S style` e PSScriptAnalyzer precisam
  passar limpos.

## Commits

Mensagens no imperativo, explicando o *porquê* quando não for óbvio.
