#!/usr/bin/env bats
#
# Contrato dos quatro scripts novos: sessões, consumo, domínio e comparação.
#
# O que se verifica aqui é o que vale em qualquer máquina — ajuda, códigos de
# saída, JSON válido e recusa de uso errado. O conteúdo do relatório depende do
# ambiente e é exercitado nos jobs de integração.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BASH_DIR="$ROOT/bash"
}

NOVOS="sessions top-consumers domain-health compare-machines"

@test "todos têm -h sem vazar o shebang" {
  for s in $NOVOS; do
    run "$BASH_DIR/$s.sh" -h
    [ "$status" -eq 0 ] || { echo "$s.sh -h saiu com $status"; return 1; }
    [[ "$output" == *"Usage:"* ]] || { echo "$s.sh sem Usage"; return 1; }
    [[ "$output" != *"/usr/bin/env"* ]] || { echo "$s.sh vazou o shebang"; return 1; }
  done
}

@test "todos informam --version com a versão do toolkit" {
  for s in $NOVOS; do
    run "$BASH_DIR/$s.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"ops-toolkit"* ]] || { echo "$s.sh sem versão"; return 1; }
  done
}

@test "todos recusam opção desconhecida com 2" {
  for s in $NOVOS; do
    run "$BASH_DIR/$s.sh" -Z
    [ "$status" -eq 2 ] || { echo "$s.sh aceitou -Z (saiu $status)"; return 1; }
  done
}

@test "sessions: JSON válido com os campos do contrato" {
  run "$BASH_DIR/sessions.sh" -j
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" == *'"source"'* ]]
  [[ "$output" == *'"parked"'* ]]
  [[ "$output" == *'"remote"'* ]]
  # --separate-stderr: sem isso o bats junta os dois, e qualquer aviso do
  # script entra no meio do JSON e o invalida. Foi assim que este teste pegou
  # um erro real do top-consumers ao ler /proc de um processo que ja morreu.
  if command -v python3 >/dev/null 2>&1; then
    run --separate-stderr "$BASH_DIR/sessions.sh" -j
    echo "$stdout" | python3 -c 'import json,sys; json.load(sys.stdin)'
  fi
}

@test "sessions: -i recusa valor que não é número" {
  run "$BASH_DIR/sessions.sh" -i abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"number of hours"* ]]
}

@test "top-consumers: JSON válido e diz de onde veio o número de CPU" {
  run "$BASH_DIR/top-consumers.sh" -s 1 -n 2 -j
  [ "$status" -eq 0 ]
  # A distinção importa: 'proc-sampled' é uso na janela, 'ps-lifetime' é média
  # da vida inteira do processo. Quem lê o JSON precisa saber qual recebeu.
  [[ "$output" == *'"cpu_source"'* ]]
  if command -v python3 >/dev/null 2>&1; then
    run --separate-stderr "$BASH_DIR/top-consumers.sh" -s 1 -n 2 -j
    # O stderr tem de vir VAZIO: aviso solto ali acaba no JSON de quem
    # redireciona 2>&1, que e o caso comum em cron.
    [ -z "$stderr" ] || {
      echo "top-consumers escreveu no stderr: $stderr"
      return 1
    }
    echo "$stdout" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["cpu_source"] in ("proc-sampled", "ps-lifetime"), d["cpu_source"]
for k in ("cores", "process_count"):
    assert isinstance(d[k], int), k
for k in ("memory_total_gb", "memory_free_gb"):
    assert isinstance(d[k], (int, float)), k
'
  fi
}

@test "top-consumers: recusa contagem zero ou negativa" {
  run "$BASH_DIR/top-consumers.sh" -n 0
  [ "$status" -eq 2 ]
}

@test "domain-health: sem domínio sai com 2" {
  run "$BASH_DIR/domain-health.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"No domain given"* ]]
}

@test "domain-health: domínio inexistente vira achado, não travamento" {
  # O caminho de falha é o que mais importa: o relatório tem de SAIR.
  run timeout 60 "$BASH_DIR/domain-health.sh" nao-existe-99999.invalid
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  [[ "$output" == *"finding"* ]]
}

@test "compare-machines: exporta e a comparação consigo mesma não acha diferença" {
  fp1="$BATS_TEST_TMPDIR/a.fp"
  fp2="$BATS_TEST_TMPDIR/b.fp"

  run "$BASH_DIR/compare-machines.sh" -e "$fp1"
  [ "$status" -eq 0 ]
  [ -s "$fp1" ]

  cp "$fp1" "$fp2"
  run "$BASH_DIR/compare-machines.sh" -c "$fp1" "$fp2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 different"* ]]
}

@test "compare-machines: diferença plantada é encontrada e sai com 1" {
  # Um teste de comparação que só compara arquivos iguais nunca falharia;
  # este planta a diferença de propósito.
  fp1="$BATS_TEST_TMPDIR/a.fp"
  fp2="$BATS_TEST_TMPDIR/b.fp"
  "$BASH_DIR/compare-machines.sh" -e "$fp1"
  sed 's/^os|kernel|.*/os|kernel|9.9.9-outro/' "$fp1" >"$fp2"
  echo 'pkg|fantasma|1.0' >>"$fp2"
  sort -o "$fp2" "$fp2"

  run "$BASH_DIR/compare-machines.sh" -c "$fp1" "$fp2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DIFFERENT"* ]]
  [[ "$output" == *"fantasma"* ]]
}

@test "compare-machines: -e e -c juntos são recusados" {
  run "$BASH_DIR/compare-machines.sh" -e /tmp/x.fp -c
  [ "$status" -eq 2 ]
  [[ "$output" == *"Pick one"* ]]
}

@test "compare-machines: comparar sem os dois arquivos sai com 2" {
  run "$BASH_DIR/compare-machines.sh" -c apenas-um.fp
  [ "$status" -eq 2 ]
}

@test "nenhum dos novos altera o sistema" {
  # São relatórios. A exceção legítima é a limpeza do próprio temporário criado
  # com mktemp: descartar o que o script mesmo criou é diferente de mexer na
  # máquina de alguém. A primeira versão deste teste reprovava justamente o
  # 'trap rm' do compare-machines — o teste é que estava grosseiro demais.
  for s in $NOVOS; do
    run grep -nE '\b(mv|chmod|chown|systemctl (start|stop|restart)|kill|shutdown)\b' "$BASH_DIR/$s.sh"
    [ "$status" -ne 0 ] || {
      echo "$s.sh tem comando que altera o sistema:"
      echo "$output"
      return 1
    }

    run grep -nE '\brm\b' "$BASH_DIR/$s.sh"
    if [ "$status" -eq 0 ]; then
      while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        [[ "$linha" == *trap* ]] || {
          echo "$s.sh usa rm fora da limpeza do próprio temporário: $linha"
          return 1
        }
      done <<<"$output"
    fi
  done
}
