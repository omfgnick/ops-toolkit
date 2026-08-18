# Política de segurança

## Reportando uma vulnerabilidade

Se encontrar uma falha de segurança neste repositório, **não abra uma issue
pública**. Use uma destas vias:

- [Security advisories](https://github.com/omfgnick/ops-toolkit/security/advisories/new) do GitHub
- E-mail: omfg_nick@hotmail.com

Descreva o script afetado, como reproduzir e o impacto que você enxerga.
Respondo em até 7 dias.

## Escopo

Este repositório contém scripts de operação executados com privilégios no seu
próprio parque. Considere reporte válido, por exemplo:

- Injeção de comando a partir de argumento, arquivo de entrada ou nome de arquivo
- Escrita em caminho previsível permitindo escalonamento (symlink, TOCTOU)
- Vazamento de credencial em log, saída ou arquivo temporário
- Remoção de arquivo fora do alvo pretendido

## Uso responsável

O `portscan-vuln.sh` faz **varredura ativa de portas** e o `audit-hardening.sh`
inspeciona configuração sensível. Use apenas em hosts que você tem autorização
para testar. Varrer sistemas de terceiros sem permissão é ilegal em muitos
países, inclusive no Brasil.

## O que estes scripts não fazem

Não substituem uma ferramenta de segurança dedicada. O `audit-hardening.sh`
sinaliza indícios comuns e não pretende ser um benchmark CIS completo — trate
os apontamentos como ponto de partida, não como veredito.
