#!/usr/bin/env bash
# synka-skarm.sh — ser till att en burk har SAMMA version som de andra.
#
# Erik 2026-08-31: "Vi kommer förstås att behöva installera vagg1 vid något
# tillfälle när den är påslagen."
#
# Att komma ihåg det är fel lösning. En avstängd skärm ska hämta ikapp av sig
# själv nästa gång den syns — precis som lagret redan gör. Skriptet är därför
# idempotent och ofarligt att köra om: har burken redan rätt version händer
# ingenting.
#
# Varför inte bootstrap.sh? Den gör HELA installationen (apt, tailscale,
# player-unit) och är rätt för ett nytt kort. Här vill vi bara lyfta
# panel-lagret på en burk som redan är i drift, utan att röra det som fungerar.
#
#   ./bin/synka-skarm.sh                 alla kända skärmar
#   ./bin/synka-skarm.sh vagg1           en enda
#   ./bin/synka-skarm.sh --torr          visa vad som skulle göras
#   ./bin/synka-skarm.sh --nu            strunta i tidsfönstret
#
# ⚠️ Byte av supervisor.sh startar om spelaren = synlig blink. Därför sker det
# bara i fönstret 14–23 (samma som OTA:n), om inte --nu anges.
set -uo pipefail
HAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SKARMAR=("vagg1:100.73.2.58" "vagg5:100.118.2.93" "dorr:100.84.39.72")
SSH_OPT=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
FRAN="${OTA_FRAN:-14}"; TILL="${OTA_TILL:-23}"

gron(){ printf '\033[32m%s\033[0m\n' "$*"; }
rod(){  printf '\033[31m%s\033[0m\n' "$*"; }
gul(){  printf '\033[33m%s\033[0m\n' "$*"; }

torr=0; nu=0; valda=()
for a in "$@"; do
  case "$a" in
    --torr) torr=1 ;;
    --nu)   nu=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) valda+=("$a") ;;
  esac
done

i_fonster(){ h=$(date +%-H); [ "$h" -ge "$FRAN" ] && [ "$h" -lt "$TILL" ]; }

andrat=0; hoppade=0; fel=0
for par in "${SKARMAR[@]}"; do
  namn="${par%%:*}"; ip="${par##*:}"
  if [ ${#valda[@]} -gt 0 ]; then
    med=0; for v in "${valda[@]}"; do [ "$v" = "$namn" ] && med=1; done
    [ "$med" = 1 ] || continue
  fi

  if ! ssh "${SSH_OPT[@]}" "eriks@$ip" true 2>/dev/null; then
    gul "  $namn: avstängd eller onåbar — hämtar ikapp nästa gång den syns"
    hoppade=$((hoppade+1)); continue
  fi

  # Vad saknas? Vi jämför innehåll, inte versionsnummer — då kan skriptet
  # aldrig tro att något är uppdaterat bara för att en siffra stämmer.
  behovs=""
  for f in panel.py valj.py supervisor.sh; do
    lokal=$(sha256sum "$HAR/bin/$f" | cut -c1-16)
    fjarr=$(ssh "${SSH_OPT[@]}" "eriks@$ip" "sha256sum /opt/entilldisplay/bin/$f 2>/dev/null | cut -c1-16")
    [ "$lokal" != "$fjarr" ] && behovs="$behovs $f"
  done
  fjarr_bg=$(ssh "${SSH_OPT[@]}" "eriks@$ip" "sha256sum /opt/entilldisplay/assets/bakgrund.png 2>/dev/null | cut -c1-16")
  [ "$(sha256sum "$HAR/assets/bakgrund.png" | cut -c1-16)" != "$fjarr_bg" ] && behovs="$behovs assets"
  ssh "${SSH_OPT[@]}" "eriks@$ip" "systemctl is-enabled entilldisplay-panel >/dev/null 2>&1" || behovs="$behovs panel-tjanst"

  if [ -z "$behovs" ]; then
    gron "  $namn: redan aktuell ✓"; continue
  fi
  echo "  $namn: behöver$behovs"
  if [ "$torr" = 1 ]; then continue; fi

  # Supervisor-byte blinkar till på skärmen. Vänta till efter lunch.
  if [[ "$behovs" == *supervisor.sh* ]] && [ "$nu" = 0 ] && ! i_fonster; then
    gul "    väntar till kl $FRAN (byte av supervisor startar om spelaren)"
    hoppade=$((hoppade+1)); continue
  fi

  for f in panel.py valj.py supervisor.sh; do
    scp -q "${SSH_OPT[@]}" "$HAR/bin/$f" "eriks@$ip:/tmp/$f" || { rod "    kunde inte kopiera $f"; fel=1; continue; }
  done
  scp -q "${SSH_OPT[@]}" "$HAR/assets/"* "eriks@$ip:/tmp/" 2>/dev/null
  scp -q "${SSH_OPT[@]}" "$HAR/systemd/entilldisplay-panel.service" "eriks@$ip:/tmp/" 2>/dev/null

  ssh "${SSH_OPT[@]}" "eriks@$ip" "
    set -e
    python3 -m py_compile /tmp/panel.py /tmp/valj.py || exit 1
    bash -n /tmp/supervisor.sh || exit 1
    rm -rf /tmp/__pycache__
    command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 || \
      sudo -n apt-get install -y --no-install-recommends imagemagick fonts-dejavu-core >/dev/null 2>&1 || true
    sudo -n install -m 0755 /tmp/panel.py /tmp/valj.py /tmp/supervisor.sh -t /opt/entilldisplay/bin/
    sudo -n install -m 0755 -o krog-$namn -g krog-$namn /tmp/valj.py /home/krog-$namn/.entilldisplay/valj.py
    sudo -n mkdir -p /opt/entilldisplay/assets
    sudo -n install -m 0644 /tmp/bakgrund.png /tmp/SairaCondensed-*.ttf /opt/entilldisplay/assets/ 2>/dev/null || true
    sudo -n cp /tmp/entilldisplay-panel.service /etc/systemd/system/
    sudo -n sed -i 's#^User=.*#User=krog-$namn#; s#^Environment=SKARM_NAMN=.*#Environment=SKARM_NAMN=$namn#' \
      /etc/systemd/system/entilldisplay-panel.service
    sudo -n systemctl daemon-reload
    sudo -n systemctl enable --now entilldisplay-panel >/dev/null 2>&1
    sudo -n systemctl restart entilldisplay-panel
    sudo -n tailscale serve --bg --https=443 http://127.0.0.1:8099 >/dev/null 2>&1 || true
  " 2>&1 | sed 's/^/    /' || { rod "    installationen föll"; fel=1; continue; }

  if [[ "$behovs" == *supervisor.sh* ]]; then
    ssh "${SSH_OPT[@]}" "eriks@$ip" "sudo -n systemctl restart entilldisplay" 2>/dev/null
    echo "    spelaren omstartad (ny supervisor)"
  fi
  gron "  $namn: uppdaterad ✓  https://krog-$namn.tailf0de83.ts.net"
  andrat=$((andrat+1))
done

echo
echo "$andrat uppdaterade, $hoppade väntar, $fel fel."
exit $fel
