#!/usr/bin/env bats
#
# rotate-logs.sh apaga arquivos. Estes testes existem para garantir que ele
# só apague o que deveria — e que o dry-run realmente não toque em nada.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../bash/rotate-logs.sh"
  WORK="$(mktemp -d)"
  # 2 logs antigos, 1 recente, 1 arquivo .gz fora da retenção
  for n in a b; do
    echo conteudo >"$WORK/$n.log"
    touch -d '30 days ago' "$WORK/$n.log"
  done
  echo recente >"$WORK/hoje.log"
  echo x | gzip >"$WORK/velho.gz"
  touch -d '200 days ago' "$WORK/velho.gz"
}

teardown() {
  rm -rf "$WORK"
}

listing() {
  find "$WORK" -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' '
}

@test "sem -d sai com 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "diretorio inexistente sai com 2" {
  run bash "$SCRIPT" -d /caminho/que/nao/existe
  [ "$status" -eq 2 ]
}

@test "dry-run e o padrao e nao altera nada" {
  before="$(listing)"
  run bash "$SCRIPT" -d "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ "$(listing)" = "$before" ]
}

@test "dry-run planeja compactar os antigos e apagar o vencido" {
  run bash "$SCRIPT" -d "$WORK"
  [[ "$output" == *"compressed=2"* ]]
  [[ "$output" == *"deleted=1"* ]]
}

@test "-f compacta os antigos e preserva o log recente" {
  run bash "$SCRIPT" -d "$WORK" -f
  [ "$status" -eq 0 ]
  [ -f "$WORK/a.log.gz" ]
  [ -f "$WORK/b.log.gz" ]
  [ ! -f "$WORK/a.log" ]
  # o log de hoje esta dentro da janela: nao pode ser tocado
  [ -f "$WORK/hoje.log" ]
}

@test "-f remove arquivo alem da retencao" {
  run bash "$SCRIPT" -d "$WORK" -f
  [ ! -f "$WORK/velho.gz" ]
}

@test "-a maior que a idade dos arquivos nao compacta nada" {
  run bash "$SCRIPT" -d "$WORK" -a 365 -k 365 -f
  [ -f "$WORK/a.log" ]
  [ -f "$WORK/velho.gz" ]
}

@test "saida -j e JSON valido e reflete o plano" {
  run bash -c "bash '$SCRIPT' -d '$WORK' -j | jq -r '.applied, .compressed, .deleted'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "false" ]
  [ "${lines[1]}" = "2" ]
  [ "${lines[2]}" = "1" ]
}
