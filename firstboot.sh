#!/bin/bash
# entilldisplay — TURNKEY first-boot (körs EN gång av entilldisplay-firstboot.service,
# After=network-online). Joinar tailnet via authkey (för FJÄRRHANTERING; ej krav för
# visning — menybilderna är publika) och kör bootstrap (player+supervisor+systemd).
# Städar bort authkey från kortet och avaktiverar sig själv efteråt. Inget tangentbord.
#
# Konfig läses från boot-partitionen (lagd dit av prepare-card.sh på Macen):
#   entilldisplay-channel   → kanalnamn (dorr | vagg1..vagg5)
#   entilldisplay-authkey   → tailscale preauth-nyckel (tag:signage)
set -u
BOOT=/boot/firmware; [ -d "$BOOT" ] || BOOT=/boot
LOG=/var/log/entilldisplay-firstboot.log; exec >>"$LOG" 2>&1
echo "=== firstboot $(date -Is) ==="
KEY="$(cat "$BOOT/entilldisplay-authkey" 2>/dev/null || true)"
CH="$(tr -d ' \r\n' < "$BOOT/entilldisplay-channel" 2>/dev/null || true)"
REPO="https://raw.githubusercontent.com/eriksjostedt/entilldisplay/main"
[ -n "$CH" ] || { echo "FEL: kanal saknas (entilldisplay-channel)"; exit 1; }

# 1. Tailscale — installera vid behov + join (fjärrhantering; SSH/config över tailnet)
command -v tailscale >/dev/null 2>&1 || { curl -fsSL https://tailscale.com/install.sh | sh || true; }
if [ -n "$KEY" ]; then
  tailscale up --authkey="$KEY" --advertise-tags=tag:signage --hostname="$(hostname)" || \
    echo "VARNING: tailscale up misslyckades (visning funkar ändå via publik WiFi)"
fi

# 2. Bootstrap — player + supervisor + systemd-tjänst; visar kanalen direkt (publik WiFi räcker)
curl -fsSL "$REPO/bootstrap.sh" | bash -s -- --name "$CH" || echo "FEL: bootstrap misslyckades"

# 3. Städa — ta bort authkey från kortet + kör bara en gång
if [ -n "$KEY" ]; then shred -u "$BOOT/entilldisplay-authkey" 2>/dev/null || rm -f "$BOOT/entilldisplay-authkey"; fi
systemctl disable entilldisplay-firstboot.service 2>/dev/null || true
echo "=== firstboot klar (kanal=$CH) ==="
