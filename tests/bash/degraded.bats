#!/usr/bin/env bats
#
# Ambiente hostil: ferramenta ausente, nome que não resolve, rede sem saída.
#
# Existe porque a mesma armadilha me pegou três vezes: com `set -euo pipefail`,
# um comando que retorna != 0 dentro de substituição (grep sem correspondência,
# getent sem resposta) derruba o script inteiro — e sempre no caminho de falha,
# que é exatamente quando o relatório precisa aparecer. Sair calado é pior que
# reportar o problema.

setup() {
  BASH_DIR="${BATS_TEST_DIRNAME}/../../bash"
}

# Scripts que devem produzir relatório mesmo quando tudo dá errado
DEGRADABLE="incident-triage disk-space inventory audit-hardening net-diagnose pending-updates"

@test "produzem saida com PATH reduzido (ferramentas ausentes)" {
  for s in $DEGRADABLE; do
    [ -f "$BASH_DIR/$s.sh" ] || continue
    # só coreutils e bash: sem ip, ss, systemctl, curl, getent...
    run env PATH=/usr/bin:/bin bash "$BASH_DIR/$s.sh"
    [ -n "$output" ] || {
      echo "$s.sh não imprimiu nada com PATH reduzido"
      return 1
    }
  done
}

@test "produzem JSON valido com PATH reduzido" {
  for s in $DEGRADABLE; do
    [ -f "$BASH_DIR/$s.sh" ] || continue
    run bash -c "env PATH=/usr/bin:/bin bash '$BASH_DIR/$s.sh' -j | jq -e . >/dev/null"
    [ "$status" -eq 0 ] || {
      echo "$s.sh não devolveu JSON válido com PATH reduzido"
      return 1
    }
  done
}

@test "net-diagnose relata falha em vez de morrer quando o nome nao resolve" {
  run bash "$BASH_DIR/net-diagnose.sh" -d nao-existe-99999.invalid
  # 1 = achou problema (esperado); vazio ou 2 seria o bug
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"dns"* ]]
}

@test "net-diagnose nao duplica o codigo http quando falha" {
  run bash -c "bash '$BASH_DIR/net-diagnose.sh' -d nao-existe-99999.invalid -j | jq -r '.steps[] | select(.step==\"https\") | .detail'"
  [[ "$output" != *"000000"* ]]
}

@test "support-bundle gera pacote mesmo com PATH reduzido" {
  out="$(mktemp -d)/b.tar.gz"
  run env PATH=/usr/bin:/bin bash "$BASH_DIR/support-bundle.sh" -o "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  rm -rf "$(dirname "$out")"
}
