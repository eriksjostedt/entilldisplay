#!/usr/bin/env bash
# prepare-card.sh — kör PÅ MACEN direkt efter att Pi Imager flashat SD-kortet
# (låt kortet sitta kvar monterat). Gör kortet TURNKEY: bakar in kanal + tailscale-
# authkey + firstboot, och kopplar in vår firstboot i first-boot-provisioneringen.
# Efteråt: sätt i kortet i Pi:n och slå på → den bootar, joinar tailnet och visar sin
# kanal HELT UTAN tangentbord.
#
# Stödjer BÅDA Imager-mekanismerna:
#   • cloud-init (nyare Trixie/Imager v2): user-data → lägger till en runcmd.
#   • firstrun.sh (äldre): injicerar en network-online oneshot.
#
# FÖRKRAV i Pi Imager (OS-anpassning) INNAN du flashar:
#   • Värdnamn (t.ex. krog-dorr / krog-vagg5)
#   • SSH → publik nyckel (din Mac-nyckel)
#   • WiFi:  Tele2Internet_1CE0A  (lösen i .52:~/.config/entill/sundbrokrog-wifi.conf)
#   • Användarnamn + lösen  ← tar bort första-boot-prompten (SSH-user = det du väljer)
#   • Land/tangentbord: SE
#
# Vid kort-tillverkning sitter vi INTE på lokalt nät → allt mot .52 går via Tailscale.
#
# Användning:  ./prepare-card.sh <kanal> [skärmläge]
#   kanal    = dorr | vagg1..vagg5
#   skärmläge= valfritt, t.ex. 1920x1080@60 → tvingar HDMI-läget. Utelämnas → firstboot
#              autodetekterar via EDID, och faller tillbaka på 720p om EDID saknas.
set -euo pipefail
CH="${1:?ange kanal: dorr eller vagg1..vagg5}"
case "$CH" in dorr|vagg1|vagg2|vagg3|vagg4|vagg5) ;; *) echo "✗ ogiltig kanal: $CH (dorr|vagg1..vagg5)"; exit 1;; esac
MODE="${2:-}"   # valfritt manuellt skärmläge, t.ex. 1920x1080@60. Utelämnas → firstboot autodetekterar
HERE="$(cd "$(dirname "$0")" && pwd)"

# 1. Hitta boot-partitionen (Bookworm/Trixie: bootfs)
BOOT=""; for v in /Volumes/bootfs /Volumes/boot; do [ -d "$v" ] && BOOT="$v" && break; done
[ -n "$BOOT" ] || { echo "✗ Hittar ingen boot-partition (/Volumes/bootfs). Flasha med Imager och låt kortet sitta i."; exit 1; }

# Mekanism: cloud-init (user-data) eller legacy (firstrun.sh)?
MODE=""
[ -f "$BOOT/user-data" ] && MODE="cloudinit"
[ -z "$MODE" ] && [ -f "$BOOT/firstrun.sh" ] && MODE="firstrun"
[ -n "$MODE" ] || { echo "✗ Varken user-data (cloud-init) eller firstrun.sh på $BOOT — sätt OS-anpassning i Imager innan du flashar."; exit 1; }
echo "==> provisioneringsmekanism: $MODE"

# 2. Mynta färsk tailscale-authkey via .52 ÖVER TAILSCALE (kortet får aldrig en gammal nyckel).
command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 || \
  echo "⚠ Verkar inte ha Tailscale uppe på Macen — kör 'tailscale status' och starta vid behov."
echo "==> myntar färsk tailscale-authkey via .52 över tailnet …"
KEY=""
for H in entill-intern.tailf0de83.ts.net entill-intern; do
  KEY="$(ssh -o ConnectTimeout=10 -o BatchMode=yes eriks@"$H" 'python3 -' < "$HERE/mint-authkey.py" 2>/dev/null | tr -d ' \r\n' || true)"
  [ -n "$KEY" ] && break
done
[ -n "$KEY" ] || { echo "✗ Kunde inte mynta authkey via .52 över Tailscale. Är tailnet uppe? (tailscale status)"; exit 1; }

# 3. Skriv kanal + authkey + firstboot till kortet
printf '%s'   "$KEY" > "$BOOT/entilldisplay-authkey"
printf '%s\n' "$CH"  > "$BOOT/entilldisplay-channel"
cp "$HERE/firstboot.sh" "$BOOT/entilldisplay-firstboot.sh"
chmod 600 "$BOOT/entilldisplay-authkey" 2>/dev/null || true

# 3b. Valfritt: tvinga skärmläge (override av firstboots EDID-autodetect+720p-fallback)
if [ -n "$MODE" ] && [ -f "$BOOT/cmdline.txt" ]; then
  if grep -q "video=HDMI" "$BOOT/cmdline.txt"; then
    echo "==> video= finns redan i cmdline — rör ej"
  else
    CUR="$(tr -d '\r\n' < "$BOOT/cmdline.txt")"
    printf '%s video=HDMI-A-1:%s\n' "$CUR" "$MODE" > "$BOOT/cmdline.txt"
    echo "==> manuellt skärmläge tvingat: $MODE"
  fi
fi

# 4. Koppla in firstboot i provisioneringen
if [ "$MODE" = "cloudinit" ]; then
  UD="$BOOT/user-data"
  if grep -q "entilldisplay-firstboot" "$UD"; then
    echo "==> user-data redan injicerad — hoppar"
  elif grep -q "^runcmd:" "$UD"; then
    awk '{print} /^runcmd:/ && !d {print "  - [ bash, /boot/firmware/entilldisplay-firstboot.sh ]"; d=1}' "$UD" > "$UD.tmp" && mv "$UD.tmp" "$UD"
    echo "==> runcmd tillagd i user-data (cloud-init kör firstboot vid första boot)"
  else
    printf '\nruncmd:\n  - [ bash, /boot/firmware/entilldisplay-firstboot.sh ]\n' >> "$UD"
    echo "==> runcmd-block tillagt i user-data"
  fi
else
  FR="$BOOT/firstrun.sh"
  if grep -q "entilldisplay-firstboot" "$FR"; then
    echo "==> firstrun.sh redan injicerad — hoppar"
  else
    TMP="$(mktemp)"
    { head -n1 "$FR"; cat <<'BLOCK'
# --- entilldisplay turnkey first-boot (auto-injicerad av prepare-card.sh) ---
cat > /etc/systemd/system/entilldisplay-firstboot.service <<'UNIT'
[Unit]
Description=entilldisplay first-boot (tailscale join + bootstrap)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash /boot/firmware/entilldisplay-firstboot.sh
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable entilldisplay-firstboot.service || true
# --- /entilldisplay ---
BLOCK
      tail -n +2 "$FR"; } > "$TMP"
    mv "$TMP" "$FR"
    echo "==> firstrun.sh injicerad (network-online oneshot)"
  fi
fi

sync
echo
echo "✓ Kort klart för kanal: $CH  (mekanism: $MODE)"
echo "  Mata ut, sätt i Pi:n, slå på → joinar WiFi + tailnet + visar $CH utan tangentbord."
echo "  Authkey raderas från kortet efter första boot. SSH-user = det du satte i Imager (t.ex. krog-dorr)."
echo "  Felsök över tailnet:  ssh <user>@<värdnamn>  ·  sudo cat /var/log/entilldisplay-firstboot.log"
