#!/bin/bash
# entilldisplay — TURNKEY first-boot (körs EN gång via cloud-init runcmd ELLER
# entilldisplay-firstboot.service). Joinar tailnet (authkey) + kör bootstrap (player),
# säkerställer skärmläge (EDID→native, annars 720p-fallback), städar authkey. Inget tangentbord.
#
# Konfig från boot-partitionen (lagd dit av prepare-card.sh):
#   entilldisplay-channel  → kanalnamn (dorr|vagg1..5). Saknas den → härleds ur värdnamnet.
#   entilldisplay-authkey  → tailscale preauth-nyckel (tag:signage)
set -u
BOOT=/boot/firmware; [ -d "$BOOT" ] || BOOT=/boot
LOG=/var/log/entilldisplay-firstboot.log; exec >>"$LOG" 2>&1
echo "=== firstboot $(date -Is) ==="
KEY="$(cat "$BOOT/entilldisplay-authkey" 2>/dev/null || true)"
CH="$(tr -d ' \r\n' < "$BOOT/entilldisplay-channel" 2>/dev/null || true)"
# Härdning: saknas kanalfilen (kan tappas vid eject) → härled ur värdnamnet (krog-dorr → dorr)
[ -n "$CH" ] || CH="$(hostname | sed 's/^krog-//')"
REPO="https://raw.githubusercontent.com/eriksjostedt/entilldisplay/main"
[ -n "$CH" ] || { echo "FEL: kanal saknas och kunde ej härledas ur värdnamnet"; exit 1; }
echo "kanal=$CH  (värdnamn=$(hostname))"

# 0. WiFi — provisionera ALLA kända nät via nmcli (roaming mellan platser: Sundbrokrog/Knäppa/entill).
#    Litar ej på Imagers WiFi. add-only (raderar aldrig ett fungerande nät). Sätt land + lyft rfkill
#    (vanligaste tysta felet). NM ansluter automatiskt till det nät som finns i räckvidd.
#    Format i entilldisplay-wifi: en rad per nät, "SSID<TAB>PSK".
have_net() { ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; }
WIFI="$BOOT/entilldisplay-wifi"
if [ -f "$WIFI" ] && command -v nmcli >/dev/null 2>&1; then
  raspi-config nonint do_wifi_country SE 2>/dev/null || iw reg set SE 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || true
  nmcli radio wifi on 2>/dev/null || true
  while IFS=$'\t' read -r SSID PSK _; do
    case "$SSID" in ''|\#*) continue;; esac
    CN="entill-$SSID"
    nmcli -g NAME con show 2>/dev/null | grep -qx "$CN" && { echo "WiFi finns redan: $SSID"; continue; }
    if nmcli con add type wifi con-name "$CN" ifname wlan0 ssid "$SSID" 2>/dev/null \
       && nmcli con modify "$CN" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" connection.autoconnect yes 2>/dev/null; then
      echo "WiFi tillagt: $SSID"
    else
      echo "WiFi-tillägg misslyckades: $SSID"
    fi
  done < "$WIFI"
fi
# säkerställ internet innan bootstrap (vänta in om nyss uppkopplat)
have_net || { echo "väntar på internet …"; for _ in $(seq 1 20); do have_net && break; sleep 3; done; }
have_net && echo "internet: OK" || echo "VARNING: fortfarande inget internet"

# 1. Tailscale — installera + join (fjärrhantering)
command -v tailscale >/dev/null 2>&1 || { curl -fsSL https://tailscale.com/install.sh | sh || true; }
if [ -n "$KEY" ]; then
  tailscale up --authkey="$KEY" --advertise-tags=tag:signage --hostname="$(hostname)" || \
    echo "VARNING: tailscale up misslyckades (visning funkar ändå via publik WiFi)"
fi

# 2. Bootstrap — player + supervisor + systemd. Kör i FÖRSTA hand från de LOKALT bakade
#    skripten på kortet (självförsörjande first boot, inget GitHub-beroende vid start).
#    Faller tillbaka på publika raw om bakningen saknas. (OTA sköts sen av supervisorn mot raw.)
SRC="$BOOT/entilldisplay-src"
if [ -f "$SRC/bootstrap.sh" ]; then
  echo "bootstrap: lokal baked kopia ($SRC)"
  bash "$SRC/bootstrap.sh" --name "$CH" --repo "file://$SRC" || echo "FEL: lokal bootstrap misslyckades"
else
  echo "bootstrap: ingen baked kopia → hämtar från raw"
  curl -fsSL "$REPO/bootstrap.sh" | bash -s -- --name "$CH" || echo "FEL: bootstrap (raw) misslyckades"
fi

# 3. Skärmläge — AUTOMATIK: EDID→native (rör inget), annars 720p-fallback.
#    Manuellt override (prepare-card --mode) syns som färdig video=HDMI i cmdline → rör vi ej.
CL="$BOOT/cmdline.txt"; REBOOT=""
if [ -f "$CL" ] && ! grep -q "video=HDMI" "$CL"; then
  EDID_BYTES=0
  for e in /sys/class/drm/card*-HDMI-A-1/edid; do [ -f "$e" ] && EDID_BYTES=$(wc -c < "$e" 2>/dev/null) && break; done
  if [ "${EDID_BYTES:-0}" -lt 128 ]; then
    sed -i 's/$/ video=HDMI-A-1:1280x720@60/' "$CL"
    echo "ingen EDID (${EDID_BYTES} byte) → 720p-fallback satt i cmdline (startar om)"
    REBOOT=1
  else
    echo "EDID finns (${EDID_BYTES} byte) → låter KMS autodetektera native-läge"
  fi
fi

# 4. Städa hemligheter (authkey + WiFi-cred) + kör bara en gång (oneshot-läget)
for s in entilldisplay-authkey entilldisplay-wifi; do
  [ -f "$BOOT/$s" ] && { shred -u "$BOOT/$s" 2>/dev/null || rm -f "$BOOT/$s"; }
done
systemctl disable entilldisplay-firstboot.service 2>/dev/null || true
echo "=== firstboot klar (kanal=$CH) ==="

# 5. Reboot sist om 720p-fallback lades till (så nya läget + player kommer upp rätt)
[ -n "$REBOOT" ] && { sync; sleep 2; reboot; }
