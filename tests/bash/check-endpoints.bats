#!/usr/bin/env bats
#
# O endpoint inalcançável produzia "status_code":000 — zero à esquerda não é
# número JSON válido, então a saída inteira era rejeitada por qualquer parser.
# Pego pela validação de schema; estes testes evitam a volta.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../bash/check-endpoints.sh"
}

@test "endpoint inalcancavel ainda produz JSON valido" {
  run bash -c "bash '$SCRIPT' -j http://127.0.0.1:19999/ | jq -e . >/dev/null"
  [ "$status" -eq 0 ]
}

@test "status_code de inalcancavel e 0, sem zeros a esquerda" {
  run bash -c "bash '$SCRIPT' -j http://127.0.0.1:19999/ | jq -r '.endpoints[0].status_code'"
  [ "$output" = "0" ]
}

@test "opcao depois do operando e recusada em vez de ignorada" {
  # 'host -j' devolveria tabela em silêncio; agora falha explicando
  run bash "$SCRIPT" http://127.0.0.1:19999/ -j
  [ "$status" -eq 2 ]
  [[ "$output" == *"before arguments"* ]]
}
