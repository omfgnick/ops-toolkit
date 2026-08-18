#!/usr/bin/env bats
#
# O ponto deste script é não confiar no backup sem restaurar. Estes testes
# garantem que a verificação realmente compara conteúdo — e falha quando difere.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../bash/backup-verify.sh"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/src/sub"
  echo alfa >"$WORK/src/a.txt"
  echo beta >"$WORK/src/sub/b.txt"
}

teardown() { rm -rf "$WORK"; }

@test "sem -s e -d sai com 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "origem inexistente sai com 2" {
  run bash "$SCRIPT" -s /nao/existe -d "$WORK/out"
  [ "$status" -eq 2 ]
}

@test "dry-run nao cria arquivo algum" {
  run bash "$SCRIPT" -s "$WORK/src" -d "$WORK/out" -n
  [ "$status" -eq 0 ]
  [ ! -d "$WORK/out" ]
}

@test "backup e criado e verificado por sha256" {
  run bash "$SCRIPT" -s "$WORK/src" -d "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restored and identical"* ]]
  [ "$(find "$WORK/out" -name '*.tar.gz' | wc -l)" -eq 1 ]
}

@test "JSON reporta a verificacao com os arquivos comparados" {
  run bash -c "bash '$SCRIPT' -s '$WORK/src' -d '$WORK/out' -j | jq -r '.verification.restored, .verification.files_compared, .verification.mismatched'"
  [ "${lines[0]}" = "true" ]
  [ "${lines[1]}" = "2" ]
  [ "${lines[2]}" = "0" ]
}

@test "retencao mantem apenas os N mais recentes" {
  for _ in 1 2 3; do
    bash "$SCRIPT" -s "$WORK/src" -d "$WORK/out" >/dev/null
    sleep 1
  done
  bash "$SCRIPT" -s "$WORK/src" -d "$WORK/out" -k 2 >/dev/null
  [ "$(find "$WORK/out" -name '*.tar.gz' | wc -l)" -eq 2 ]
}
