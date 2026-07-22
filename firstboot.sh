#!/bin/bash
# entilldisplay — TURNKEY first-boot, RETRY TILLS KLART. Körs av entilldisplay-firstboot.service
# (Restart=on-failure var 30:e s) tills ALLT lyckats: WiFi → internet → tailscale-join → bootstrap
# → player aktiv. Då sätts en klar-markör, hemligheter shreddas och tjänsten avaktiveras.
# ALDRIG någon handpåläggning: misslyckas ett steg → exit≠0 → systemd försöker igen.
#
# Konfig från boot-partitionen (bakat av prepare-card.sh):
#   entilldisplay-channel  → kanal (dorr|vagg1..5); saknas → härleds ur värdnamnet (krog-vagg3→vagg3)
#   entilldisplay-authkey  → tailscale preauth-nyckel (tag:signage)
#   entilldisplay-wifi     → fleet-WiFi-lista, en rad "SSID<TAB>PSK" per nät (roaming)
#   entilldisplay-src/     → bakade repo-skript (bootstrap.sh + bin/ + systemd/) för file://-install
set -u
BOOT=/boot/firmware; [ -d "$BOOT" ] || BOOT=/boot
LOG=/var/log/entilldisplay-firstboot.log; exec >>"$LOG" 2>&1
MARK=/var/lib/entilldisplay/firstboot.done
REPO="https://raw.githubusercontent.com/eriksjostedt/entilldisplay/main"
[ -f "$MARK" ] && { echo "$(date -Is) redan klar — inget att göra"; exit 0; }
echo "=== firstboot-försök $(date -Is) ==="

CH="$(tr -d ' \r\n' < "$BOOT/entilldisplay-channel" 2>/dev/null || true)"
[ -n "$CH" ] || CH="$(hostname | sed 's/^krog-//')"
[ -n "$CH" ] || { echo "FEL: kanal saknas och kunde ej härledas ur värdnamnet"; exit 1; }
echo "kanal=$CH  (värdnamn=$(hostname))"

have_net() { ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; }

# 0. WiFi — provisionera ALLA kända nät (roaming), add-only, sätt land + lyft rfkill.
WIFI="$BOOT/entilldisplay-wifi"
if [ -f "$WIFI" ] && command -v nmcli >/dev/null 2>&1; then
  raspi-config nonint do_wifi_country SE 2>/dev/null || iw reg set SE 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || true
  nmcli radio wifi on 2>/dev/null || true
  while IFS=$'\t' read -r SSID PSK _; do
    case "$SSID" in ''|\#*) continue;; esac
    CN="entill-$SSID"
    nmcli -g NAME con show 2>/dev/null | grep -qx "$CN" && continue           # add-only
    nmcli con add type wifi con-name "$CN" ifname wlan0 ssid "$SSID" 2>/dev/null \
      && nmcli con modify "$CN" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" connection.autoconnect yes 2>/dev/null \
      && echo "WiFi tillagt: $SSID" || echo "WiFi-tillägg misslyckades: $SSID"
  done < "$WIFI"
fi

# 1. Internet — vänta in (~45s). Ingen anslutning? → exit 1, systemd försöker igen om 30s.
if ! have_net; then
  echo "väntar på internet …"
  for _ in $(seq 1 15); do have_net && break; sleep 3; done
fi
have_net || { echo "inget internet ännu — försöker igen (retry)"; exit 1; }
echo "internet: OK"

# 2. Tailscale — installera + join (fjärrhantering). Fel → retry.
command -v tailscale >/dev/null 2>&1 || { curl -fsSL https://tailscale.com/install.sh | sh || { echo "tailscale-install fail — retry"; exit 1; }; }
KEY="$(cat "$BOOT/entilldisplay-authkey" 2>/dev/null || true)"
if [ -n "$KEY" ] && ! tailscale status >/dev/null 2>&1; then
  tailscale up --authkey="$KEY" --advertise-tags=tag:signage --hostname="$(hostname)" --ssh || echo "VARNING: tailscale up misslyckades (visning funkar ändå)"
fi

# 3. Bootstrap — i FÖRSTA hand lokalt bakade skript (file://), annars publika raw. Fel → retry.
#    Kör player som burkens FAKTISKA inloggningsanvändare (uid 1000) — oavsett vad den heter.
RUN_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"; RUN_USER="${RUN_USER:-eriks}"
echo "player-användare: $RUN_USER"
SRC="$BOOT/entilldisplay-src"
if [ -f "$SRC/bootstrap.sh" ]; then
  bash "$SRC/bootstrap.sh" --name "$CH" --user "$RUN_USER" --repo "file://$SRC" || { echo "lokal bootstrap fail — retry"; exit 1; }
else
  curl -fsSL "$REPO/bootstrap.sh" | bash -s -- --name "$CH" --user "$RUN_USER" || { echo "raw bootstrap fail — retry"; exit 1; }
fi
systemctl is-active --quiet entilldisplay || { echo "player-tjänst ej aktiv — retry"; exit 1; }
echo "player aktiv ✓"

# ===== ALLT LYCKADES → markera klart, städa, avaktivera =====
mkdir -p /var/lib/entilldisplay; date -Is > "$MARK"
for s in entilldisplay-authkey entilldisplay-wifi; do
  [ -f "$BOOT/$s" ] && { shred -u "$BOOT/$s" 2>/dev/null || rm -f "$BOOT/$s"; }
done
systemctl disable entilldisplay-firstboot.service 2>/dev/null || true

# 4. Skärmläge — EDID→native, annars 720p-fallback (om ingen manuell video= redan satt). Reboot om ändrat.
CL="$BOOT/cmdline.txt"; NEED_REBOOT=""
if [ -f "$CL" ] && ! grep -q "video=HDMI" "$CL"; then
  EDID_BYTES=0
  for e in /sys/class/drm/card*-HDMI-A-1/edid; do [ -f "$e" ] && EDID_BYTES=$(wc -c < "$e" 2>/dev/null) && break; done
  if [ "${EDID_BYTES:-0}" -lt 128 ]; then
    sed -i 's/$/ video=HDMI-A-1:1280x720@60/' "$CL"
    echo "ingen EDID (${EDID_BYTES} byte) → 720p-fallback (startar om)"; NEED_REBOOT=1
  else
    echo "EDID finns (${EDID_BYTES} byte) → KMS autodetekterar native"
  fi
fi
echo "=== firstboot KLAR (kanal=$CH) ==="
[ -n "$NEED_REBOOT" ] && { sync; sleep 2; reboot; }
exit 0
