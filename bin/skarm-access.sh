#!/usr/bin/env bash
# skarm-access.sh — vaktar ÅTKOMSTEN till signage-burkarna, inte bilderna.
#
# Att kunna nå skärmarna via SSH är en av de viktigaste delarna i entilldisplay: utan inloggning
# går det inte att felsöka när något brinner, och burkarna sitter inte där man kommer åt dem.
# Det här skriptet testar varje känd inloggningsväg och larmar via vakt-ntfy när en slutar
# fungera — så en trasig väg upptäcks *innan* du behöver den, inte när.
#
# Kör: ./skarm-access.sh [--alltid]     (--alltid = kvitto även när allt är grönt)
# Cron på .52: dagligen. Nod-listan är avsiktligt explicit — en bortglömd burk ska synas.
#
# Designval: SSH-försöket ÄR livstestet. `tailscale ping` visade sig flaky över DERP-relay
# (ibland >5 s) och gav falska "offline". Vi skiljer istället på svaren:
#   nekad      = vi är utelåsta        -> LARM
#   timeout    = burken är avstängd    -> ingen larm (nattavstängning är normalt)
set -uo pipefail
export TZ=Europe/Stockholm

# STANDARD för alla displayer — enhetligt, inga snöflingor. Varje burk ska ha EXAKT samma
# rad: användare `eriks` (primär, med sudo) och `root` (reserv), båda via Tailscale-SSH.
# Avviker en burk är det ett fel att åtgärda, inte en egenhet att dokumentera.
# (De gamla nodnamns-användarna krog-vagg5/krog-vagg1/krog-dorr finns kvar som tjänsteanvändare
#  för playern, men är INTE inloggningsvägen och testas inte här.)
NODER=(
  "krog-vagg5:eriks,root"
  "krog-vagg1:eriks,root"
  "krog-dorr:eriks,root"
)

fel=(); ok=(); offline=()

# 0 = inne, 1 = nekad (utelåst), 2 = ingen kontakt (burken nere)
testa_inloggning(){
  local u="$1" n="$2" ut
  ut=$(ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
       "$u@$n" 'true' 2>&1) && return 0
  case "$ut" in
    *"Permission denied"*|*"policy does not permit"*|*"Too many authentication"*) return 1 ;;
    *) return 2 ;;
  esac
}

for rad in "${NODER[@]}"; do
  nod="${rad%%:*}"
  IFS=',' read -ra users <<< "${rad#*:}"
  nod_ok=0; nekade=(); tysta=0
  for u in "${users[@]}"; do
    testa_inloggning "$u" "$nod"
    case $? in
      0) nod_ok=$((nod_ok+1)); ok+=("$u@$nod") ;;
      1) nekade+=("$u@$nod") ;;
      2) tysta=$((tysta+1)) ;;
    esac
  done
  if [ "$nod_ok" -gt 0 ]; then
    # Minst en väg in fungerar. En nekad reservväg är inte akut, men ska synas.
    [ ${#nekade[@]} -gt 0 ] && fel+=("$nod: reservvägen nekar (${nekade[*]}) — $nod_ok av ${#users[@]} kvar")
  elif [ ${#nekade[@]} -gt 0 ]; then
    fel+=("$nod: UTELÅST — alla vägar nekar (${nekade[*]})")
  else
    offline+=("$nod")   # ingen svarade alls = avstängd burk, inte ett åtkomstfel
  fi
done

skicka(){  # $1=prio $2=rubrik $3=text
  local url topic
  url=$(sudo -n grep -h '^NTFY_URL=' /etc/entill-sentinel/sentinel.conf 2>/dev/null | cut -d= -f2- | tr -d '"')
  topic=$(sudo -n grep -h '^NTFY_TOPIC=' /etc/entill-sentinel/sentinel.conf 2>/dev/null | cut -d= -f2- | tr -d '"')
  [ -n "$url" ] && [ -n "$topic" ] || { echo "(ingen ntfy-konfig — hoppar notis)"; return; }
  curl -fsS -m 20 -H "Title: $2" -H "Priority: $1" -d "$3" "${url%/}/$topic" >/dev/null && echo "notis skickad"
}

stamp=$(date '+%Y-%m-%d %H:%M')
offline_txt=""; [ ${#offline[@]} -gt 0 ] && offline_txt=" | avstängda (ej testbara): ${offline[*]}"

if [ ${#fel[@]} -eq 0 ]; then
  echo "[$stamp] ✅ SSH-åtkomst OK: ${ok[*]:-—}$offline_txt"
  [ "${1:-}" = "--alltid" ] && skicka default "Skärmar: SSH-åtkomst OK" \
    "$(printf '%s\n' "${ok[@]}")$offline_txt"
else
  printf '[%s] ❌ %s\n' "$stamp" "$(IFS='; '; echo "${fel[*]}")"
  skicka high "Skärmar: SSH-åtkomst BRUTEN" \
    "$(printf '%s\n' "${fel[@]}")

Fungerar fortfarande: ${ok[*]:-inget}$offline_txt"
fi
