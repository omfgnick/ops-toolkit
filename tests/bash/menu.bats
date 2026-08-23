#!/usr/bin/env bats
#
# O menu é a porta de entrada de quem não decora nome de script, então ele
# precisa ser difícil de quebrar: entrada inválida não pode derrubar, e as
# opções digitadas depois do número têm de chegar ao script escolhido.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  MENU="$ROOT/menu.sh"
  # Sem isto a origem da resposta depende de existir TTY, e a mesma suite
  # passaria num runner e travaria noutro.
  export OPS_MENU_INPUT=/dev/stdin
}

# A numeração da tela segue a ordem por categoria, e não a alfabética do -l.
# Descobrir a posição na hora é o que impede este arquivo de quebrar sozinho
# toda vez que entra um script novo — foi o que aconteceu com o '7' cravado.
posicao_de() {
  bash "$MENU" -c |
    grep -o '"name":"[^"]*"' |
    cut -d'"' -f4 |
    grep -n "^$1\$" |
    cut -d: -f1
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
  local n
  n="$(posicao_de disk-space)"
  [ -n "$n" ] || {
    echo "disk-space sumiu do catálogo do menu"
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

# ---- Catálogo ----------------------------------------------------------------

@test "-c devolve JSON válido com uma entrada por script" {
  run bash -c "bash '$MENU' -c"
  [ "$status" -eq 0 ]
  if command -v python3 >/dev/null 2>&1; then
    esperado="$(find "$ROOT/bash" -maxdepth 1 -name '*.sh' | wc -l)"
    echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert len(d) == $esperado, '%d entradas, esperado $esperado' % len(d)
for e in d:
    for k in ('name', 'category', 'summary', 'asks'):
        assert k in e, (e.get('name'), k)
    assert e['category'], e['name'] + ' sem categoria'
"
  fi
}

@test "toda categoria é uma das que o menu sabe desenhar" {
  # Categoria escrita errada não quebra nada visivelmente: o script cai em
  # 'Other', no fim da lista, e ninguém repara. Este teste é o que faz o erro
  # de digitação aparecer.
  conhecidas="Triage Network Services Security Backup Inventory"
  while IFS= read -r cat; do
    [ -n "$cat" ] || continue
    encontrada=0
    for c in $conhecidas; do
      [ "$cat" = "$c" ] && encontrada=1
    done
    [ "$encontrada" -eq 1 ] || {
      echo "categoria desconhecida: '$cat'"
      return 1
    }
  done < <(bash "$MENU" -c | grep -o '"category":"[^"]*"' | cut -d'"' -f4)
}

@test "todo script declara categoria no próprio cabeçalho" {
  for f in "$ROOT"/bash/*.sh; do
    grep -q '^# Category:' "$f" || {
      echo "$(basename "$f") não declara categoria"
      return 1
    }
  done
}

# ---- Interface ---------------------------------------------------------------

@test "a tela agrupa por categoria" {
  run bash -c "printf 'q\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Triage"* ]]
  [[ "$output" == *"Network"* ]]
  [[ "$output" == *"Backup"* ]]
}

@test "/texto filtra a lista e o filtro fica visível" {
  run bash -c "printf '/tls\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"filter: tls"* ]]

  # A sessão inteira contém as duas telas — a de antes e a de depois do filtro.
  # Comparar contra tudo daria um teste sempre verde; o que interessa é só o
  # que sobrou na segunda tela, porque esconder é metade do valor do filtro.
  filtrada="${output#*filter: tls}"
  [[ "$filtrada" == *"check-tls-expiry"* ]]
  [[ "$filtrada" != *"backup-verify"* ]]
  [[ "$filtrada" != *"disk-space"* ]]
}

@test "filtro sem resultado avisa em vez de mostrar lista vazia" {
  run bash -c "printf '/zzzznaoexiste\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing matches"* ]]
}

@test "'/' sozinho limpa o filtro" {
  run bash -c "printf '/tls\n/\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-verify"* ]]
}

@test "o resumo é cortado para a lista caber numa tela" {
  # incident-triage tem a sinopse mais longa do conjunto; sem corte ela sozinha
  # ocupa três linhas e some com a estrutura de categorias.
  run bash -c "printf 'q\n' | bash '$MENU'"
  while IFS= read -r linha; do
    [ "${#linha}" -le 100 ] || {
      echo "linha de ${#linha} caracteres: $linha"
      return 1
    }
  done <<<"$output"
}

# ---- Execução ----------------------------------------------------------------

@test "pergunta o argumento que o script exige, em vez de deixá-lo falhar" {
  local n
  n="$(posicao_de check-tls-expiry)"
  run bash -c "printf '$n\nexample.com\n\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs:"* ]]
  # E o valor respondido tem de CHEGAR ao script: a primeira versão perguntava
  # e engolia a execução, porque reabria $INPUT a cada leitura e a segunda já
  # vinha vazia.
  [[ "$output" == *"check-tls-expiry"* ]]
  [[ "$output" == *"example.com"* ]]
}

@test "toda pergunta declarada tem rótulo, e não só a flag" {
  while IFS= read -r rotulo; do
    [ -n "$rotulo" ] || {
      echo "há um Ask: sem rótulo"
      return 1
    }
  done < <(grep -h '^# Ask:' "$ROOT"/bash/*.sh | sed 's/^# Ask:[^|]*|[[:space:]]*//')
}

@test "3,7 roda os dois em sequência" {
  local a b
  a="$(posicao_de audit-hardening)"
  b="$(posicao_de disk-space)"
  run bash -c "printf '$a,$b\n\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HARDENING AUDIT"* ]]
  [[ "$output" == *"FILESYSTEM"* ]]
}

@test "número inválido no meio do lote não interrompe o resto" {
  local a
  a="$(posicao_de audit-hardening)"
  run bash -c "printf 'xx,$a,999\n\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignored: xx"* ]]
  [[ "$output" == *"out of range: 999"* ]]
  [[ "$output" == *"HARDENING AUDIT"* ]]
}

@test "a saída da execução pode ser salva num arquivo" {
  local n destino
  n="$(posicao_de audit-hardening)"
  destino="$BATS_TEST_TMPDIR/relatorio.txt"

  run bash -c "printf '$n\ns\n$destino\n\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [ -s "$destino" ] || {
    echo "nada foi escrito em $destino"
    echo "$output"
    return 1
  }
  grep -q "HARDENING AUDIT" "$destino" || {
    echo "o arquivo salvo não tem o relatório:"
    cat "$destino"
    return 1
  }
}

@test "salvar sem nada executado avisa em vez de escrever lixo" {
  run bash -c "printf 's\n\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to save yet"* ]]
}

@test "o menu não deixa a pasta temporária para trás" {
  antes="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l)"
  run bash -c "printf 'q\n' | bash '$MENU'"
  [ "$status" -eq 0 ]
  depois="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l)"
  [ "$depois" -le "$antes" ] || {
    echo "sobrou pasta temporária: $antes -> $depois"
    return 1
  }
}

@test "a tela do menu não fala português" {
  # Todo o resto que o toolkit imprime é em inglês — resumo, --help, relatório.
  # A interface do menu chegou a sair em português nesta mesma mudança, e a tela
  # ficou metade numa língua e metade na outra.
  run bash -c "printf '99\nabc\n/zzz\n/\ns\n\nq\n' | bash '$MENU'"
  [ "$status" -eq 0 ]

  suspeitas='escolha|salvar|sair|voltar|nada para|filtrar|varios|precisa de|concluido|fora da lista|nao e um|nenhum script'
  achado="$(printf '%s\n' "$output" | grep -inE "$suspeitas" || true)"
  [ -z "$achado" ] || {
    echo "texto em português na tela:"
    echo "$achado"
    return 1
  }
}

@test "os rótulos das perguntas estão em inglês" {
  # O rótulo aparece na tela junto de resumos em inglês; escrito em português
  # ele vaza também para docs/*.en.md.
  achado="$(grep -h '^# Ask:' "$ROOT"/bash/*.sh |
    grep -inE 'diretorio|dominio|servico|checar|escanear|monitorar|espaco|separadas|nome do' || true)"
  [ -z "$achado" ] || {
    echo "rótulo de pergunta em português:"
    echo "$achado"
    return 1
  }
}
