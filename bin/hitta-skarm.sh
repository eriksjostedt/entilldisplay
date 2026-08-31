#!/usr/bin/env bash
# hitta-skarm.sh — hitta en nyinstallerad burk på plats, utan Tailscale.
#
# Erik 2026-08-31: "Installationen gör vi på plats i restaurangen. Då kan du
# söka över deras nätverk efter den nya installationen och hämta den utan
# tailscale första gången."
#
# ⭐ VARFÖR DET LÖSER KORT-I-FICKAN
# Ett förberett kort bär en Tailscale-nyckel som åldras. Står man DÄR spelar
# det ingen roll: burken hittas på det lokala nätet, och nyckeln myntas färsk
# i samma stund via .52 (Macen når .52 över tailnet även från krogen).
# Ett kort som legat ett år i fickan fungerar alltså lika bra som ett nytt.
#
# Körs FRÅN MACEN, ansluten till samma nät som burken.
#
#   ./bin/hitta-skarm.sh                  leta och visa vad som hittas
#   ./bin/hitta-skarm.sh --anslut vagg2   leta + koppla in den på tailnet som vagg2
#
set -uo pipefail
HAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_OPT=(-o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

gron(){ printf '\033[32m%s\033[0m\n' "$*"; }
rod(){  printf '\033[31m%s\033[0m\n' "$*"; }
gul(){  printf '\033[33m%s\033[0m\n' "$*"; }

anslut=""; 
while [ $# -gt 0 ]; do
  case "$1" in
    --anslut) anslut="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) rod "Okänd flagga: $1"; exit 2 ;;
  esac
done

# Vilket nät sitter vi på? Ta första icke-loopback IPv4.
MITT=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null \
       || ip -4 addr show scope global 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)
[ -n "$MITT" ] || { rod "Hittar inget lokalt nät — är du ansluten till krogens wifi?"; exit 1; }
NAT="${MITT%.*}"
echo "Söker på $NAT.0/24 (jag är $MITT)"
echo

# Snabb svepning: ping fyller ARP-tabellen, sedan kollar vi port 22.
for i in $(seq 1 254); do (ping -c1 -W1 "$NAT.$i" >/dev/null 2>&1 &) ; done
sleep 3

# Portkollen görs PARALLELLT. I serie tar 254 adresser à 1 s upp till fyra
# minuter — oacceptabelt när man står i restaurangen och väntar.
TMP=$(mktemp -d)
for i in $(seq 1 254); do
  ip="$NAT.$i"
  [ "$ip" = "$MITT" ] && continue
  {
    # -G på macOS, -w på Linux.
    if nc -z -G 1 "$ip" 22 >/dev/null 2>&1 || nc -z -w 1 "$ip" 22 >/dev/null 2>&1; then
      echo "$ip" > "$TMP/$i"
    fi
  } &
done
wait
hittade=()
for f in "$TMP"/*; do [ -f "$f" ] && hittade+=("$(cat "$f")"); done
rm -rf "$TMP"

[ ${#hittade[@]} -eq 0 ] && { rod "Ingen värd med SSH hittad. Har burken fått nät?"; exit 1; }
echo "SSH svarar på: ${hittade[*]}"
echo

kandidater=()
for ip in "${hittade[@]}"; do
  svar=$(ssh "${SSH_OPT[@]}" "eriks@$ip" '
    echo "$(hostname)|$(test -d /opt/entilldisplay && echo entilldisplay || echo -)|$(systemctl is-active entilldisplay 2>/dev/null)|$(tailscale status >/dev/null 2>&1 && echo tailnet || echo ingen-tailnet)"
  ' 2>/dev/null) || continue
  vard="${svar%%|*}"; rest="${svar#*|}"
  har="${rest%%|*}"; rest="${rest#*|}"
  tjanst="${rest%%|*}"; ts="${rest##*|}"
  if [ "$har" = "entilldisplay" ]; then
    gron "  ★ $ip  $vard  — signage, spelare: $tjanst, $ts"
    [ "$ts" = "ingen-tailnet" ] && kandidater+=("$ip|$vard")
  else
    echo "    $ip  $vard  (inte en signage-burk)"
  fi
done

echo
if [ -z "$anslut" ]; then
  [ ${#kandidater[@]} -gt 0 ] \
    && gul "Kör med --anslut <namn> för att koppla in den på tailnet." \
    || echo "Inget att koppla in — allt hittat är redan på tailnet."
  exit 0
fi

[ ${#kandidater[@]} -eq 1 ] || { rod "Hittade ${#kandidater[@]} burkar utan tailnet — koppla in en i taget."; exit 1; }
ip="${kandidater[0]%%|*}"; vard="${kandidater[0]##*|}"
echo "Kopplar in $ip ($vard) som '$anslut'…"

# Nyckeln myntas HÄR OCH NU via .52 över tailnet. Kortets egen nyckel kan vara
# hur gammal som helst — den används inte.
KEY=$(ssh -o ConnectTimeout=10 -o BatchMode=yes eriks@entill-intern 'python3 -' \
        < "$HAR/mint-authkey.py" 2>/dev/null | tr -d ' \r\n')
[ -n "$KEY" ] || { rod "Kunde inte mynta nyckel via .52. Är tailnet uppe på macen?"; exit 1; }
gron "  färsk nyckel myntad"

ssh "${SSH_OPT[@]}" "eriks@$ip" "
  sudo -n hostnamectl set-hostname krog-$anslut 2>/dev/null || true
  sudo -n tailscale up --authkey='$KEY' --advertise-tags=tag:signage \
      --hostname=krog-$anslut --ssh --accept-dns=false
  sleep 3
  tailscale ip -4 2>/dev/null | head -1
" 2>&1 | sed 's/^/    /'

echo
gron "Klart. Kör sedan från .52:  ./bin/synka-skarm.sh $anslut"
