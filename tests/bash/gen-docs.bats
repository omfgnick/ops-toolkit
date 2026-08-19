#!/usr/bin/env bats
#
# Testes do gerador de docs.
#
# O gerador existe porque a documentação escrita à mão divergiu: o README
# apontava "referência completa" para um arquivo com 2 dos 16 scripts. Estes
# testes garantem que ele cobre todos e que o modo -c realmente reprova quando
# algo sai do lugar - um check que não reprova é pior que check nenhum.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GEN="$ROOT/tools/gen-docs.sh"
}

@test "-h mostra a ajuda sem vazar o shebang" {
  run "$GEN" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" != *"/usr/bin/env"* ]]
}

@test "opcao desconhecida sai com 2" {
  run "$GEN" -Z
  [ "$status" -eq 2 ]
}

@test "argumento inesperado sai com 2" {
  run "$GEN" alguma-coisa
  [ "$status" -eq 2 ]
}

@test "-c passa com os docs versionados" {
  run "$GEN" -c
  [ "$status" -eq 0 ]
}

@test "documenta todos os scripts, sem sobrar nem faltar" {
  bash_count=$(find "$ROOT/bash" -maxdepth 1 -name '*.sh' | wc -l)
  ps_count=$(find "$ROOT/powershell" -maxdepth 1 -name '*.ps1' | wc -l)

  for f in bash.en.md bash.pt-BR.md; do
    got=$(grep -c '^### ' "$ROOT/docs/$f")
    [ "$got" -eq "$bash_count" ] || {
      echo "docs/$f documenta $got de $bash_count scripts Bash"
      return 1
    }
  done
  for f in powershell.en.md powershell.pt-BR.md; do
    got=$(grep -c '^### ' "$ROOT/docs/$f")
    [ "$got" -eq "$ps_count" ] || {
      echo "docs/$f documenta $got de $ps_count scripts PowerShell"
      return 1
    }
  done
}

@test "-c reprova quando o cabecalho de um script muda" {
  # Sem esta prova o check poderia estar sempre verde e ninguem saberia.
  work="$BATS_TEST_TMPDIR/repo"
  cp -r "$ROOT" "$work"
  rm -rf "$work/.git"

  run "$work/tools/gen-docs.sh" -c
  [ "$status" -eq 0 ]

  sed -i 's/^# Usage:/# Uso trocado no teste:/' "$work/bash/disk-space.sh"
  run "$work/tools/gen-docs.sh" -c
  [ "$status" -eq 1 ]
  [[ "$output" == *"DESATUALIZADO"* ]]
}

@test "os links entre os idiomas apontam para arquivos que existem" {
  # Os quatro arquivos apontavam para README.md e README.pt-BR.md, que nao
  # existem em docs/ - sobra de quando eram READMEs dos repositorios antigos.
  for f in "$ROOT"/docs/*.md; do
    while read -r target; do
      case "$target" in http*) continue ;; esac
      [ -e "$ROOT/docs/$target" ] || [ -e "$ROOT/$target" ] || {
        echo "$(basename "$f") aponta para $target, que nao existe"
        return 1
      }
    done < <(grep -o '](\([^)#]*\.md\)[^)]*)' "$f" | sed 's/](\([^)#]*\.md\).*/\1/')
  done
}
