#!/usr/bin/env bash
# prepare-card.sh — kör PÅ MACEN direkt efter att Pi Imager flashat SD-kortet
# (låt kortet sitta kvar monterat). Gör kortet TURNKEY: bakar in kanal + tailscale-
# authkey + firstboot, och installerar en network-online oneshot via Imagers firstrun.sh.
# Efteråt: sätt i kortet i Pi:n och slå på → den bootar, joinar tailnet och visar sin
# kanal HELT UTAN tangentbord.
#
# FÖRKRAV i Pi Imager (kugghjulet "OS-anpassning") INNAN du flashar:
#   • Värdnamn (t.ex. krog-dorr / krog-vagg5)
#   • Aktivera SSH → "Tillåt endast med publik nyckel" (klistra din Mac-nyckel)
#   • Konfigurera WiFi:  Tele2Internet_1CE0A  (lösen finns i .52:~/.config/entill/sundbrokrog-wifi.conf)
#   • Ange användarnamn + lösenord  ← detta TAR BORT första-boot-prompten (det du fastnade på)
#   • Land/tangentbord: SE
# (Utan OS-anpassning skapas ingen firstrun.sh och skriptet stoppar.)
#
# Användning:  ./prepare-card.sh <kanal>        kanal = dorr | vagg1 | vagg2 | vagg3 | vagg4 | vagg5
set -euo pipefail
CH="${1:?ange kanal: dorr eller vagg1..vagg5}"
case "$CH" in dorr|vagg1|vagg2|vagg3|vagg4|vagg5) ;; *) echo "✗ ogiltig kanal: $CH (dorr|vagg1..vagg5)"; exit 1;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"

# 1. Hitta boot-partitionen (Bookworm: bootfs)
BOOT=""; for v in /Volumes/bootfs /Volumes/boot; do [ -d "$v" ] && BOOT="$v" && break; done
[ -n "$BOOT" ] || { echo "✗ Hittar ingen boot-partition (/Volumes/bootfs). Flasha med Imager och låt kortet sitta i."; exit 1; }
[ -f "$BOOT/firstrun.sh" ] || { echo "✗ $BOOT/firstrun.sh saknas — du måste sätta OS-anpassning (värdnamn/WiFi/SSH/användare) i Imager innan du flashar."; exit 1; }

# 2. MYNTA en FÄRSK authkey on-demand via .52 ÖVER TAILSCALE (kortet får aldrig en gammal nyckel
#    → ingen utgångs-tracking på kortsidan). OBS: vid kort-tillverkning sitter vi INTE på lokalt nät
#    → helt beroende av tailnet. Kräver att Macens Tailscale är uppe. FQDN + bare-fallback.
command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 || \
  echo "⚠ Verkar inte ha Tailscale uppe på Macen — kör 'tailscale status' och starta vid behov."
echo "==> myntar färsk tailscale-authkey via .52 över tailnet …"
KEY=""
for H in entill-intern.tailf0de83.ts.net entill-intern; do
  KEY="$(ssh -o ConnectTimeout=10 -o BatchMode=yes eriks@"$H" 'bash -s' < "$HERE/mint-authkey.sh" 2>/dev/null | tr -d ' \r\n' || true)"
  [ -n "$KEY" ] && break
done
[ -n "$KEY" ] || { echo "✗ Kunde inte mynta authkey via .52 över Tailscale. Är tailnet uppe? (tailscale status) Har PAT/OAuth gått ut? (se järnkoll i README)"; exit 1; }

# 3. Skriv kanal + authkey + firstboot till kortet
printf '%s'   "$KEY" > "$BOOT/entilldisplay-authkey"
printf '%s\n' "$CH"  > "$BOOT/entilldisplay-channel"
cp "$HERE/firstboot.sh" "$BOOT/entilldisplay-firstboot.sh"
chmod 600 "$BOOT/entilldisplay-authkey" 2>/dev/null || true

# 4. Injicera en network-online oneshot via Imagers firstrun.sh (prepend efter shebang; körs som root)
if ! grep -q "entilldisplay-firstboot" "$BOOT/firstrun.sh"; then
  TMP="$(mktemp)"
  {
    head -n1 "$BOOT/firstrun.sh"
    cat <<'BLOCK'
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
    tail -n +2 "$BOOT/firstrun.sh"
  } > "$TMP"
  mv "$TMP" "$BOOT/firstrun.sh"
  echo "==> firstrun.sh injicerad (oneshot installeras + aktiveras vid första boot)"
else
  echo "==> firstrun.sh redan injicerad — hoppar"
fi

sync
echo
echo "✓ Kort klart för kanal: $CH"
echo "  Mata ut kortet, sätt i Pi:n, slå på. Den:"
echo "   1) joinar WiFi + tailnet (authkey), 2) hämtar bootstrap, 3) visar $CH — utan tangentbord."
echo "  Authkey raderas från kortet automatiskt efter första boot."
echo "  Felsök (över tailnet):  ssh eriks@<värdnamn>  ·  sudo cat /var/log/entilldisplay-firstboot.log"
