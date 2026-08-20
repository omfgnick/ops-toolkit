#!/usr/bin/env bats
#
# O menu é a porta de entrada de quem não decora nome de script, então ele
# precisa ser difícil de quebrar: entrada inválida não pode derrubar, e as
# opções digitadas depois do número têm de chegar ao script escolhido.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  MENU="$ROOT/menu.sh"
}

@test "-l lista um script por linha" {
  run bash "$MENU" -l
  [ "$status" -eq 0 ]
  [[ "$output" == *"disk-space"* ]]
  [[ "$output" == *"incident-triage"* ]]
}

@test "a lista tem o mesmo tamanho da pasta bash/" {
  run bash -c "bash '$MENU' -l | wc -l"
  expected="$(find "$ROOT/bash" -maxdepth 1 -name '*.sh' | wc -l)"
  [ "$output" -eq "$expected" ]
}

@test "-r executa o script escolhido" {
  run bash "$MENU" -r disk-space -t 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"FILESYSTEM"* ]]
}

@test "-r repassa as opções para o script, sem consumi-las" {
  # o menu não pode tentar interpretar -t como opção sua
  run bash "$MENU" -r disk-space -t 99
  [ "$status" -eq 1 ]
  [[ "$output" != *"Unknown option"* ]]
}

@test "-r com script inexistente sai com 2" {
  run bash "$MENU" -r nao-existe
  [ "$status" -eq 2 ]
}

@test "-r sem nome sai com 2" {
  run bash "$MENU" -r
  [ "$status" -eq 2 ]
}

@test "opção desconhecida sai com 2" {
  run bash "$MENU" -Z
  [ "$status" -eq 2 ]
}

@test "entrada inválida não derruba o menu" {
  run bash -c "printf 'abc\n999\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not a number"* ]]
  [[ "$output" == *"Out of range"* ]]
}

@test "escolha numerada executa e volta ao menu" {
  # O numero e descoberto na hora, e nao fixo: a lista sai em ordem alfabetica,
  # entao qualquer script novo desloca as posicoes seguintes. Com '7' cravado,
  # este teste quebrou ao entrar o compare-machines - falhou por causa do
  # proprio teste, nao do menu.
  local n
  n="$(bash "$MENU" -l | grep -n '^disk-space$' | cut -d: -f1)"
  [ -n "$n" ] || {
    echo "disk-space sumiu da lista do menu"
    return 1
  }

  run bash -c "printf '$n -t 1\n\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FILESYSTEM"* ]]
}

@test "--version responde" {
  run bash "$MENU" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ops-toolkit"* ]]
}
