#!/usr/bin/env bats
#
# Contrato comum a todos os scripts Bash: ajuda, códigos de saída e JSON.
# Estes testes valem para qualquer script novo — se um deles quebrar aqui,
# é porque saiu do padrão do projeto.

setup() {
  BASH_DIR="${BATS_TEST_DIRNAME}/../../bash"
  # Scripts que aceitam -j e podem rodar sem argumento nem privilégio
  JSON_SCRIPTS=(disk-space.sh incident-triage.sh audit-hardening.sh)
}

all_scripts() {
  find "$BASH_DIR" -name '*.sh' | sort
}

@test "todo script tem shebang de bash na primeira linha" {
  while read -r f; do
    run head -1 "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "#!/usr/bin/env bash" ]
  done < <(all_scripts)
}

@test "nenhum script tem CRLF (quebraria em Linux)" {
  while read -r f; do
    run grep -c $'\r' "$f"
    # grep sem correspondência sai com 1; encontrar CR é que seria falha
    [ "$output" = "0" ]
  done < <(all_scripts)
}

@test "todo script usa set -euo pipefail" {
  while read -r f; do
    run grep -qx 'set -euo pipefail' "$f"
    [ "$status" -eq 0 ] || {
      echo "faltando em: $f"
      return 1
    }
  done < <(all_scripts)
}

@test "-h imprime a ajuda e sai com 0" {
  while read -r f; do
    run bash "$f" -h
    [ "$status" -eq 0 ]
    # a ajuda começa pelo nome do próprio script
    [[ "$output" == *"$(basename "$f")"* ]]
  done < <(all_scripts)
}

@test "-h nao vaza o shebang para a saida" {
  while read -r f; do
    run bash "$f" -h
    [[ "$output" != *"!/usr/bin/env"* ]] || {
      echo "shebang vazou em: $f"
      return 1
    }
  done < <(all_scripts)
}

@test "opcao desconhecida sai com 2" {
  while read -r f; do
    run bash "$f" -Z
    [ "$status" -eq 2 ] || {
      echo "$f saiu com $status, esperado 2"
      return 1
    }
  done < <(all_scripts)
}

@test "saida -j e JSON valido" {
  for name in "${JSON_SCRIPTS[@]}"; do
    run bash -c "bash '$BASH_DIR/$name' -j | jq -e . >/dev/null"
    [ "$status" -eq 0 ] || {
      echo "JSON invalido em: $name"
      return 1
    }
  done
}
