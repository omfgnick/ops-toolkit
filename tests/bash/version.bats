#!/usr/bin/env bats
#
# A versão fica embutida em cada script (eles são standalone, sem arquivo
# compartilhado). Isso só funciona se nada divergir do arquivo VERSION — daí
# estes testes.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  BASH_DIR="$ROOT/bash"
  VERSION="$(cat "$ROOT/VERSION")"
}

@test "VERSION segue o formato SemVer" {
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "todo script declara a mesma versao do arquivo VERSION" {
  while read -r f; do
    declared="$(grep -oP 'OPS_TOOLKIT_VERSION="\K[^"]+' "$f" | head -1)"
    [ "$declared" = "$VERSION" ] || {
      echo "$f declara '$declared', esperado '$VERSION'"
      return 1
    }
  done < <(find "$BASH_DIR" -name '*.sh')
}

@test "--version imprime nome, projeto e versao" {
  run bash "$BASH_DIR/disk-space.sh" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"disk-space"* ]]
  [[ "$output" == *"ops-toolkit"* ]]
  [[ "$output" == *"$VERSION"* ]]
}

@test "--version funciona em todos os scripts" {
  while read -r f; do
    run bash "$f" --version
    [ "$status" -eq 0 ] || {
      echo "falhou: $f"
      return 1
    }
  done < <(find "$BASH_DIR" -name '*.sh')
}

@test "--help mostra a ajuda em todos os scripts" {
  while read -r f; do
    run bash "$f" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(basename "$f")"* ]] || {
      echo "ajuda vazia: $f"
      return 1
    }
  done < <(find "$BASH_DIR" -name '*.sh')
}
