#!/usr/bin/env bats
#
# Regressão de um bug que só aparecia quando /etc/ssh/sshd_config existia:
# `grep` sem correspondência retorna 1 e, com `set -o pipefail`, derrubava o
# script inteiro — que então saía sem imprimir nada. O CI pegou; estes testes
# existem para que não volte.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../bash/audit-hardening.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

@test "produz JSON valido quando sshd_config existe SEM as diretivas procuradas" {
  # nenhuma linha PermitRootLogin/PasswordAuthentication: o grep não casa
  printf '# vazio de proposito\nPort 22\n' >"$WORK/sshd_config"
  run bash -c "SSHD_CONFIG='$WORK/sshd_config' bash '$SCRIPT' -j | jq -e . >/dev/null"
  [ "$status" -eq 0 ]
}

@test "produz saida legivel quando sshd_config existe sem as diretivas" {
  printf 'Port 22\n' >"$WORK/sshd_config"
  SSHD_CONFIG="$WORK/sshd_config" run bash "$SCRIPT"
  [ -n "$output" ]
  [[ "$output" == *"HARDENING AUDIT"* ]]
}

@test "sinaliza PermitRootLogin yes como severidade alta" {
  printf 'PermitRootLogin yes\n' >"$WORK/sshd_config"
  run bash -c "SSHD_CONFIG='$WORK/sshd_config' bash '$SCRIPT' -j | jq -r '.findings[] | select(.severity==\"high\") | .message'"
  [[ "$output" == *"root login"* ]]
}

@test "sinaliza PasswordAuthentication yes como severidade media" {
  printf 'PasswordAuthentication yes\n' >"$WORK/sshd_config"
  run bash -c "SSHD_CONFIG='$WORK/sshd_config' bash '$SCRIPT' -j | jq -r '.findings[] | select(.severity==\"medium\") | .message'"
  [[ "$output" == *"password authentication"* ]]
}

@test "linha comentada nao conta como diretiva ativa" {
  printf '#PermitRootLogin yes\nPort 22\n' >"$WORK/sshd_config"
  run bash -c "SSHD_CONFIG='$WORK/sshd_config' bash '$SCRIPT' -j | jq -r '[.findings[] | select(.severity==\"high\")] | length'"
  [ "$output" = "0" ]
}

@test "achado apenas informativo nao muda o codigo de saida" {
  printf 'Port 22\n' >"$WORK/sshd_config"
  SSHD_CONFIG="$WORK/sshd_config" run bash "$SCRIPT" -j
  # só 'high'/'medium' devem falhar; 'info' é nota
  [ "$status" -eq 0 ]
}

@test "achado de severidade alta faz sair com 1" {
  printf 'PermitRootLogin yes\n' >"$WORK/sshd_config"
  SSHD_CONFIG="$WORK/sshd_config" run bash "$SCRIPT" -j
  [ "$status" -eq 1 ]
}
