#!/usr/bin/env bash
# entilldisplay bootstrap — gör en Raspberry Pi till en signage-skärm.
# Körs PÅ burken (som root/sudo), lokalt eller via SSH från Macen. Idempotent.
#
# Eriks flöde:
#   1. Flasha Raspberry Pi OS Lite (Imager: sätt hostname, SSH-nyckel, ev. WiFi).
#   2. Boota, kör EN gång:   sudo tailscale up --advertise-tags=tag:signage
#      (godkänn i tailnet-admin)  ← den ENDA manuella biten
#   3. Från Macen:
#        ssh eriks@<skärm>.tailf0de83.ts.net \
#          'curl -fsSL https://raw.githubusercontent.com/eriksjostedt/entilldisplay/main/bootstrap.sh | sudo bash -s -- --name <namn>'
#      (eller kör provision.sh <skärm> <namn> från repot)
#
# Användning: sudo bootstrap.sh --name <skärmnamn> [--media-base URL] [--repo URL] [--poll N]
set -euo pipefail

NAME=""
REPO="https://raw.githubusercontent.com/eriksjostedt/entilldisplay/main"
MEDIA_BASE="https://sundbrokrog.se/skarm"
POLL=60
PREFIX=/opt/entilldisplay
RUN_USER="${SUDO_USER:-eriks}"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)       NAME="$2"; shift 2;;
    --media-base) MEDIA_BASE="$2"; shift 2;;
    --repo)       REPO="$2"; shift 2;;
    --poll)       POLL="$2"; shift 2;;
    *) echo "okänt argument: $1" >&2; exit 1;;
  esac
done
[ -n "$NAME" ] || { echo "FEL: --name krävs (skärmnamn, t.ex. vagg1)" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "FEL: kör med sudo" >&2; exit 1; }

echo "==> paket (mpv, curl, network-manager)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y --no-install-recommends mpv curl network-manager

echo "==> ethernet-fallback (kabel = alltid nät, högsta prioritet)"
if command -v nmcli >/dev/null 2>&1; then
  if ! nmcli -t -f NAME con show 2>/dev/null | grep -qx "eth-fallback"; then
    nmcli con add type ethernet ifname eth0 con-name eth-fallback autoconnect yes 2>/dev/null || true
  fi
  nmcli con mod eth-fallback connection.autoconnect-priority 100 2>/dev/null || true
fi

echo "==> installera player → $PREFIX"
install -d "$PREFIX/bin"
curl -fsSL "$REPO/bin/player.sh" -o "$PREFIX/bin/player.sh"
chmod +x "$PREFIX/bin/player.sh"
bash -n "$PREFIX/bin/player.sh"   # syntaxkoll innan vi kör den

echo "==> systemd-tjänst (skärm=$NAME, media=$MEDIA_BASE, poll=${POLL}s, user=$RUN_USER)"
curl -fsSL "$REPO/systemd/entilldisplay.service" -o /etc/systemd/system/entilldisplay.service
sed -i "s#player.sh vagg5#player.sh $NAME#"                 /etc/systemd/system/entilldisplay.service
sed -i "s#^User=.*#User=$RUN_USER#"                          /etc/systemd/system/entilldisplay.service
sed -i "s#^Environment=POLL=.*#Environment=POLL=$POLL#"      /etc/systemd/system/entilldisplay.service
grep -q "MENY_BASE=" /etc/systemd/system/entilldisplay.service \
  || sed -i "/^Environment=POLL=/a Environment=MENY_BASE=$MEDIA_BASE" /etc/systemd/system/entilldisplay.service
systemctl daemon-reload
systemctl enable --now entilldisplay.service

echo "==> tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "   → kör: sudo tailscale up --advertise-tags=tag:signage"
else
  echo "   redan installerat ($(tailscale ip -4 2>/dev/null | head -1 || echo 'ej uppkopplad'))"
fi

echo
echo "==> KLART — $NAME"
systemctl --no-pager --lines=0 status entilldisplay.service 2>/dev/null | head -3 || true
echo "   media : $MEDIA_BASE/$NAME.png"
echo "   loggar: journalctl -u entilldisplay -f   (taggen 'menyskarm')"
