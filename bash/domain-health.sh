#!/usr/bin/env bash
#
# domain-health.sh — Full check of a domain: DNS records, TLS chain, redirect
# chain and the e-mail records that decide whether your mail is trusted.
#
# Wider than check-tls-expiry.sh, which answers only "when does the certificate
# expire". This one answers "is this domain healthy", which is the question
# behind most tickets that start with "the site is weird".
#
# Two checks here catch the failures that expiry dates miss:
#
#   - CHAIN, not just the leaf. A certificate valid for 60 more days still
#     breaks every client if the intermediate is missing from the handshake.
#     Browsers often hide this by caching the intermediate; curl does not, and
#     neither does a Java client at 3am.
#   - SPF and DMARC. Their absence never shows up as an error anywhere — the
#     mail just quietly lands in spam.
#
# Read-only: nothing here changes a record or a certificate.
#
# Usage:
#   ./domain-health.sh [options] DOMAIN [DOMAIN...]
#
# Options:
#   -w DAYS      Warn when the certificate expires within DAYS (default 30)
#   -j           Emit JSON instead of the readable report
#   -o FILE      Also write the output to FILE
#   -h           Show this help
#
# Exit codes:
#   0 everything healthy · 1 at least one finding · 2 bad usage
#
# Examples:
#   ./domain-health.sh example.com
#   ./domain-health.sh -w 45 example.com outro.com
#   ./domain-health.sh -j example.com | jq '.domains[].findings'
#
# Requires: coreutils. Uses openssl, curl and one of dig/host/nslookup; each
# missing tool turns its own checks into "skipped", never into a wrong answer.
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

readonly OPS_TOOLKIT_VERSION="1.1.0"

case "${1:-}" in
  --version)
    echo "$(basename "$0") (ops-toolkit) $OPS_TOOLKIT_VERSION"
    exit 0
    ;;
  --help)
    usage
    exit 0
    ;;
esac

WARN_DAYS=30
AS_JSON=0
OUT_FILE=""

while getopts ":w:jo:h" opt; do
  case "$opt" in
    w) WARN_DAYS="$OPTARG" ;;
    j) AS_JSON=1 ;;
    o) OUT_FILE="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 2
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      exit 2
      ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -eq 0 ]; then
  echo "No domain given." >&2
  echo "Usage: $(basename "$0") [options] DOMAIN [DOMAIN...]" >&2
  exit 2
fi

case "$WARN_DAYS" in
  '' | *[!0-9]*)
    echo "-w expects a number of days, got: $WARN_DAYS" >&2
    exit 2
    ;;
esac

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'
}
have() { command -v "$1" >/dev/null 2>&1; }

# Um resolvedor entre os tres mais comuns; sem nenhum, DNS vira 'skipped'
DNS_TOOL=""
for t in dig host nslookup; do
  if have "$t"; then
    DNS_TOOL="$t"
    break
  fi
done

# $1 = nome, $2 = tipo. Devolve uma resposta por linha, ou nada.
#
# Cada ferramenta responde num formato diferente, e o nslookup ainda vem
# TRADUZIDO ("Servidor"/"Server", "Nome"/"Name") e quebra o TXT em duas linhas.
# Casar por rotulo daria errado numa maquina em portugues - que e exatamente
# onde um script de suporte roda. Aqui o cabecalho do resolvedor e descartado
# por posicao (tudo ate a primeira linha em branco), o que independe de idioma.
resolve() {
  local nome="$1" tipo="$2" corpo=""
  case "$DNS_TOOL" in
    dig)
      dig +short "$tipo" "$nome" 2>/dev/null | sed '/^$/d' || true
      ;;
    host)
      case "$tipo" in
        A) host -t A "$nome" 2>/dev/null | sed -n 's/.* has address //p' || true ;;
        NS) host -t NS "$nome" 2>/dev/null | sed -n 's/.* name server //p' || true ;;
        MX) host -t MX "$nome" 2>/dev/null | sed -n 's/.* mail is handled by //p' || true ;;
        TXT) host -t TXT "$nome" 2>/dev/null | sed -n 's/.* descriptive text //p' || true ;;
        *) : ;;
      esac
      ;;
    nslookup)
      # Descarta o bloco de cabecalho: primeira linha em branco em diante e a
      # resposta. Depois junta tudo numa linha so, porque o TXT vem partido.
      corpo="$(nslookup -type="$tipo" "$nome" 2>/dev/null |
        awk 'BEGIN { cab = 1 } cab && /^[[:space:]]*$/ { cab = 0; next } !cab' || true)"
      case "$tipo" in
        A) sed -n 's/^Address:[[:space:]]*//p' <<<"$corpo" || true ;;
        NS) sed -n 's/.*nameserver = //p' <<<"$corpo" || true ;;
        MX) sed -n 's/.*mail exchanger = //p' <<<"$corpo" || true ;;
        TXT) tr -d '\n' <<<"$corpo" | grep -o '"[^"]*"' || true ;;
        *) : ;;
      esac
      ;;
    *) : ;;
  esac
}

TOTAL_FINDINGS=0
DOMS=()

for dominio in "$@"; do
  findings=()
  a_rec=""
  mx_rec=""
  ns_rec=""
  spf=""
  dmarc=""
  cert_subject=""
  cert_issuer=""
  cert_days=""
  cert_chain="skipped"
  http_final=""
  http_code=""

  # ---- DNS ------------------------------------------------------------------
  if [ -n "$DNS_TOOL" ]; then
    a_rec="$(resolve "$dominio" A | head -3 | tr '\n' ' ' | sed 's/ $//')"
    mx_rec="$(resolve "$dominio" MX | head -3 | tr '\n' ' ' | sed 's/ $//')"
    ns_rec="$(resolve "$dominio" NS | head -3 | tr '\n' ' ' | sed 's/ $//')"
    spf="$(resolve "$dominio" TXT | grep -i 'v=spf1' | head -1 || true)"
    dmarc="$(resolve "_dmarc.$dominio" TXT | grep -i 'v=DMARC1' | head -1 || true)"

    [ -n "$a_rec" ] || findings+=("high|dns|no A record: the name does not resolve")
    [ -n "$ns_rec" ] || findings+=("medium|dns|no NS record returned")
    if [ -n "$mx_rec" ]; then
      # SPF/DMARC so importam se o dominio recebe ou envia e-mail
      [ -n "$spf" ] || findings+=("medium|mail|no SPF record: your mail is easier to spoof")
      [ -n "$dmarc" ] || findings+=("medium|mail|no DMARC record: nobody is told what to do with fakes")
    fi
  else
    findings+=("info|dns|skipped: no dig, host or nslookup on this machine")
  fi

  # ---- TLS ------------------------------------------------------------------
  if have openssl; then
    # -verify_return_error faz a validacao da CADEIA falhar de verdade, em vez
    # de so avisar: e a diferenca entre "expira em 60 dias" e "quebra agora"
    saida="$(echo | timeout 12 openssl s_client -connect "$dominio:443" -servername "$dominio" \
      -verify_return_error 2>&1 || true)"

    if printf '%s' "$saida" | grep -q 'BEGIN CERTIFICATE'; then
      cert_chain="ok"
      cert_subject="$(printf '%s' "$saida" | sed -n 's/^subject=//p' | head -1)"
      cert_issuer="$(printf '%s' "$saida" | sed -n 's/^issuer=//p' | head -1)"

      fim="$(printf '%s' "$saida" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//' || true)"
      if [ -n "$fim" ]; then
        fim_ts="$(date -d "$fim" +%s 2>/dev/null || echo 0)"
        if [ "$fim_ts" -gt 0 ]; then
          cert_days=$(((fim_ts - $(date +%s)) / 86400))
          if [ "$cert_days" -lt 0 ]; then
            findings+=("high|tls|certificate EXPIRED $((-cert_days)) day(s) ago")
          elif [ "$cert_days" -le "$WARN_DAYS" ]; then
            findings+=("high|tls|certificate expires in $cert_days day(s)")
          fi
        fi
      fi

      # Cadeia incompleta: o handshake conecta mas a verificacao reprova
      if printf '%s' "$saida" | grep -qiE 'unable to get local issuer|self.signed|verify error'; then
        cert_chain="incomplete"
        findings+=("high|tls|chain does not verify: an intermediate is probably missing from the handshake")
      fi
    else
      cert_chain="failed"
      findings+=("high|tls|no TLS handshake on port 443")
    fi
  else
    findings+=("info|tls|skipped: openssl not available")
  fi

  # ---- HTTP -----------------------------------------------------------------
  if have curl; then
    # 10#: sem isso um codigo com zero a esquerda vira octal e o JSON quebra -
    # o mesmo furo que ja mordeu o check-endpoints
    http_code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 12 "https://$dominio" 2>/dev/null || echo 0)"
    http_code="$((10#${http_code:-0}))"
    http_final="$(curl -s -o /dev/null -w '%{url_effective}' -L --max-time 12 "https://$dominio" 2>/dev/null || echo '')"
    if [ "$http_code" -eq 0 ]; then
      findings+=("high|http|no answer over HTTPS")
    elif [ "$http_code" -ge 500 ]; then
      findings+=("high|http|server answers $http_code")
    elif [ "$http_code" -ge 400 ]; then
      findings+=("medium|http|server answers $http_code")
    fi
  else
    findings+=("info|http|skipped: curl not available")
  fi

  n=${#findings[@]}
  TOTAL_FINDINGS=$((TOTAL_FINDINGS + n))

  # Serializa este dominio numa linha; o separador raro evita colisao com o dado
  DOMS+=("$dominio"$'\x1f'"$a_rec"$'\x1f'"$mx_rec"$'\x1f'"$ns_rec"$'\x1f'"$spf"$'\x1f'"$dmarc"$'\x1f'"$cert_subject"$'\x1f'"$cert_issuer"$'\x1f'"$cert_days"$'\x1f'"$cert_chain"$'\x1f'"$http_code"$'\x1f'"$http_final"$'\x1f'"$(printf '%s\x1e' ${findings[@]+"${findings[@]}"})")
done

STATUS=0
[ "$TOTAL_FINDINGS" -gt 0 ] && STATUS=1

render_json() {
  local first=1 d
  printf '{'
  printf '"generated_at":"%s",' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '"warn_days":%s,' "$WARN_DAYS"
  printf '"dns_tool":"%s",' "${DNS_TOOL:-none}"
  printf '"finding_count":%s,' "$TOTAL_FINDINGS"
  printf '"domains":['
  for d in ${DOMS[@]+"${DOMS[@]}"}; do
    IFS=$'\x1f' read -r nome a mx ns spf dmarc subj issuer dias cadeia code final fl <<<"$d"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"domain":"%s","a":"%s","mx":"%s","ns":"%s","spf":%s,"dmarc":%s,' \
      "$(json_escape "$nome")" "$(json_escape "$a")" "$(json_escape "$mx")" "$(json_escape "$ns")" \
      "$([ -n "$spf" ] && echo true || echo false)" "$([ -n "$dmarc" ] && echo true || echo false)"
    printf '"cert_subject":"%s","cert_issuer":"%s","cert_days_left":%s,"cert_chain":"%s",' \
      "$(json_escape "$subj")" "$(json_escape "$issuer")" "${dias:-null}" "$cadeia"
    printf '"http_code":%s,"http_final_url":"%s","findings":[' "${code:-0}" "$(json_escape "$final")"
    local fp=1 item sev cat msg
    while IFS= read -r -d $'\x1e' item; do
      [ -n "$item" ] || continue
      IFS='|' read -r sev cat msg <<<"$item"
      [ "$fp" -eq 1 ] || printf ','
      fp=0
      printf '{"severity":"%s","area":"%s","message":"%s"}' "$sev" "$cat" "$(json_escape "$msg")"
    done <<<"$fl"
    printf ']}'
  done
  printf '],'
  printf '"status":%s' "$STATUS"
  printf '}\n'
}

render_text() {
  local d nome a mx ns spf dmarc subj issuer dias cadeia code final fl item sev cat msg

  echo "Domain health"
  echo "Generated at $(date '+%Y-%m-%d %H:%M:%S %Z')"
  [ -n "$DNS_TOOL" ] || echo "  (no DNS tool found: dig, host or nslookup)"
  echo

  for d in ${DOMS[@]+"${DOMS[@]}"}; do
    IFS=$'\x1f' read -r nome a mx ns spf dmarc subj issuer dias cadeia code final fl <<<"$d"
    echo "  $nome"
    printf '    %-14s %s\n' "A" "${a:-—}"
    printf '    %-14s %s\n' "NS" "${ns:-—}"
    printf '    %-14s %s\n' "MX" "${mx:-—}"
    printf '    %-14s %s\n' "SPF" "$([ -n "$spf" ] && echo present || echo 'MISSING')"
    printf '    %-14s %s\n' "DMARC" "$([ -n "$dmarc" ] && echo present || echo 'MISSING')"
    printf '    %-14s %s\n' "TLS chain" "$cadeia"
    [ -n "$issuer" ] && printf '    %-14s %s\n' "Issued by" "$issuer"
    [ -n "$dias" ] && printf '    %-14s %s day(s)\n' "Expires in" "$dias"
    printf '    %-14s %s  %s\n' "HTTPS" "${code:-0}" "${final:-}"

    local achou=0
    while IFS= read -r -d $'\x1e' item; do
      [ -n "$item" ] || continue
      IFS='|' read -r sev cat msg <<<"$item"
      [ "$achou" -eq 0 ] && echo "" && echo "    Findings"
      achou=1
      printf '      [%-6s] %-5s %s\n' "$sev" "$cat" "$msg"
    done <<<"$fl"
    echo
  done

  printf '  %s finding(s) across %s domain(s)\n' "$TOTAL_FINDINGS" "${#DOMS[@]}"
}

if [ "$AS_JSON" -eq 1 ]; then output="$(render_json)"; else output="$(render_text)"; fi
printf '%s\n' "$output"
if [ -n "$OUT_FILE" ]; then printf '%s\n' "$output" >"$OUT_FILE"; fi
exit "$STATUS"
