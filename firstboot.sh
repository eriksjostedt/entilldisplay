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

# 1. Tailscale — installera + join (fjärrhantering)
command -v tailscale >/dev/null 2>&1 || { curl -fsSL https://tailscale.com/install.sh | sh || true; }
if [ -n "$KEY" ]; then
  tailscale up --authkey="$KEY" --advertise-tags=tag:signage --hostname="$(hostname)" || \
    echo "VARNING: tailscale up misslyckades (visning funkar ändå via publik WiFi)"
fi

# 2. Bootstrap — player + supervisor + systemd (visar kanalen; publik WiFi räcker)
curl -fsSL "$REPO/bootstrap.sh" | bash -s -- --name "$CH" || echo "FEL: bootstrap misslyckades"

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

# 4. Städa authkey + kör bara en gång (oneshot-läget)
if [ -n "$KEY" ]; then shred -u "$BOOT/entilldisplay-authkey" 2>/dev/null || rm -f "$BOOT/entilldisplay-authkey"; fi
systemctl disable entilldisplay-firstboot.service 2>/dev/null || true
echo "=== firstboot klar (kanal=$CH) ==="

# 5. Reboot sist om 720p-fallback lades till (så nya läget + player kommer upp rätt)
[ -n "$REBOOT" ] && { sync; sleep 2; reboot; }
