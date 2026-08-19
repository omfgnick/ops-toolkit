#!/usr/bin/env bats
#
# Testes do pending-updates.sh.
#
# O que mais importa aqui não é contar pacotes: é que "0 pendentes" com a lista
# velha seja tratado como alerta, e não como máquina saudável. Um relatório que
# some com essa diferença dá exatamente a falsa segurança que o script existe
# para evitar.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/bash/pending-updates.sh"
}

@test "roda e produz relatório legível" {
  run "$SCRIPT"
  # 0 = em dia, 1 = há pendência/reboot/metadados velhos: os dois são sucesso
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" == *"Package manager"* ]]
  [[ "$output" == *"Reboot required"* ]]
}

@test "-h mostra a ajuda sem vazar o shebang" {
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" != *"/usr/bin/env"* ]]
}

@test "--version informa a versão do toolkit" {
  run "$SCRIPT" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ops-toolkit"* ]]
}

@test "-j produz JSON com os campos do contrato" {
  run "$SCRIPT" -j
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" == *'"package_manager"'* ]]
  [[ "$output" == *'"metadata_stale"'* ]]
  [[ "$output" == *'"pending_count"'* ]]
  [[ "$output" == *'"security_count"'* ]]
  [[ "$output" == *'"reboot_required"'* ]]

  if command -v python3 >/dev/null 2>&1; then
    echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
  fi
}

@test "os contadores do JSON são números, não texto" {
  # Já houve caso de contador virar string vazia quando o comando não achou
  # nada; aí quem consome o JSON quebra na hora de somar.
  command -v python3 >/dev/null 2>&1 || skip "sem python3"
  run "$SCRIPT" -j
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("pending_count", "security_count", "metadata_age_days", "stale_after_days", "status"):
    assert isinstance(d[k], int), k + " nao e inteiro: " + repr(d[k])
for k in ("metadata_stale", "refreshed", "reboot_required"):
    assert isinstance(d[k], bool), k + " nao e booleano: " + repr(d[k])
'
}

@test "-d 0 sempre marca a lista como velha" {
  # A comparação é inclusiva justamente para que -d 0 tenha um significado
  # definido; sem isso não havia como testar este caminho sem envelhecer um
  # arquivo do sistema.
  command -v python3 >/dev/null 2>&1 || skip "sem python3"
  run "$SCRIPT" -j -d 0
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["metadata_stale"] is True, "com -d 0 os metadados tinham de contar como velhos"
assert d["status"] == 1, "lista velha precisa sair com status 1, nao 0"
'
}

@test "o limiar realmente discrimina, e nao marca tudo como velho" {
  # Sem este teste, trocar a comparação por 'sempre verdadeiro' passaria
  # despercebido: o teste acima continuaria verde e o aviso perderia o sentido.
  command -v python3 >/dev/null 2>&1 || skip "sem python3"
  run "$SCRIPT" -j -d 3650
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d["metadata_age_days"] < 0:
    sys.exit(0)   # sem gerenciador de pacotes nao ha idade para comparar
assert d["metadata_stale"] is False, "10 anos de limiar nao pode marcar lista de %d dia(s) como velha" % d["metadata_age_days"]
'
}

@test "-d recusa valor que não é número" {
  run "$SCRIPT" -d abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"number of days"* ]]
}

@test "opção depois de operando é recusada, não ignorada" {
  # getopts para no primeiro operando: sem esta checagem o -j sairia ignorado
  # e o usuário receberia tabela achando que pediu JSON.
  run "$SCRIPT" foo -j
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unexpected argument"* ]]
}

@test "opção desconhecida sai com 2" {
  run "$SCRIPT" -Z
  [ "$status" -eq 2 ]
}

@test "-o também escreve o relatório no arquivo" {
  out="$BATS_TEST_TMPDIR/rel.json"
  run "$SCRIPT" -j -o "$out"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [ -s "$out" ]
  grep -q '"pending_count"' "$out"
}

@test "nenhum verbo que instala ou remove pacote aparece no script" {
  # É um relatório. Um regex frouxo aqui daria falsa confiança, então isto
  # procura os verbos em si, sem tentar entender a linha de comando: install,
  # remove, dist-upgrade, -Su, -U. Se algum aparecer, alguém precisa justificar.
  run grep -nE '\b(install|reinstall|dist-upgrade|autoremove)\b|[[:space:]]-(Su|U|Rns?)\b' "$SCRIPT"
  [ "$status" -ne 0 ] || {
    echo "verbo que altera pacotes encontrado:"
    echo "$output"
    return 1
  }
}

@test "toda chamada a 'upgrade' é simulada" {
  # 'apt-get upgrade' instala; 'apt-get -s upgrade' só calcula o que faria. A
  # diferença é um -s, e é a diferença entre relatório e mudança na máquina.
  while IFS= read -r line; do
    [[ "$line" == *"-s "* ]] || {
      echo "chamada a upgrade sem -s (simulação): $line"
      return 1
    }
  done < <(grep -nE '^[^#]*(apt-get|dnf|yum|zypper)[^|]*upgrade' "$SCRIPT" || true)
}

@test "só o modo -r pode escrever, e só com root" {
  # O refresh é a única ação do script. Os comandos que atualizam metadados têm
  # de estar dentro do bloco de -r, que por sua vez exige root.
  refresh_block="$(sed -n '/^if \[ "\$REFRESH" -eq 1 \]/,/^fi$/p' "$SCRIPT")"
  [ -n "$refresh_block" ]
  [[ "$refresh_block" == *'IS_ROOT'* ]]

  for cmd in "apt-get update" "makecache" "zypper -q refresh" "pacman -Sy" "apk update"; do
    if grep -qF "$cmd" "$SCRIPT"; then
      [[ "$refresh_block" == *"$cmd"* ]] || {
        echo "'$cmd' aparece fora do bloco de refresh"
        return 1
      }
    fi
  done
}

@test "sobrevive a PATH reduzido" {
  # O caso que já matou outros scripts: 'set -euo pipefail' com comando que
  # retorna != 0 dentro de substituição. Com as ferramentas fora do caminho, o
  # relatório ainda tem de sair.
  run env PATH=/usr/bin:/bin bash "$SCRIPT"
  [ -n "$output" ]
  [[ "$output" == *"Package manager"* ]]
}
