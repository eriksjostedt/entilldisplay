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
    --user)       RUN_USER="$2"; shift 2;;
    *) echo "okänt argument: $1" >&2; exit 1;;
  esac
done
[ -n "$NAME" ] || { echo "FEL: --name krävs (skärmnamn, t.ex. vagg1)" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "FEL: kör med sudo" >&2; exit 1; }

echo "==> paket (mpv, curl, network-manager)"
export DEBIAN_FRONTEND=noninteractive
# Tålig apt: retry vid övergående nät-/spegelhicka i st f att avbryta hela bootstrap.
apt_retry() { local i; for i in 1 2 3 4 5; do "$@" && return 0; echo "   apt-försök $i misslyckades — väntar 10s"; sleep 10; done; return 1; }
apt_retry apt-get update -q
# imagemagick: panelen gor om HEIC/JPEG fran telefonen till PNG.
apt_retry apt-get install -y --no-install-recommends mpv curl network-manager imagemagick

echo "==> ethernet-fallback (kabel = alltid nät, högsta prioritet)"
if command -v nmcli >/dev/null 2>&1; then
  if ! nmcli -t -f NAME con show 2>/dev/null | grep -qx "eth-fallback"; then
    nmcli con add type ethernet ifname eth0 con-name eth-fallback autoconnect yes 2>/dev/null || true
  fi
  nmcli con mod eth-fallback connection.autoconnect-priority 100 2>/dev/null || true
fi

# Hämta med FALLBACK: prova $REPO (ofta file:// = bakat på kortet) → faller tillbaka på publika
# GitHub-raw om filen saknas/är tom. Skyddar mot FAT-korruption (fsck döpte om en bakad fil till
# FSCK0000.000 → file:// hittade den ej → bootstrap loopade). Detta var den riktiga roten på vagg5.
REPO_RAW="https://raw.githubusercontent.com/eriksjostedt/entilldisplay/main"
fetch() { # $1=relativ sökväg  $2=målfil
  curl -fsSL "$REPO/$1" -o "$2" 2>/dev/null && [ -s "$2" ] && return 0
  echo "   ⚠ $REPO/$1 saknas/trasig → hämtar publikt: $REPO_RAW/$1"
  curl -fsSL "$REPO_RAW/$1" -o "$2" && [ -s "$2" ]
}

echo "==> installera supervisor + player + valj → $PREFIX"
install -d "$PREFIX/bin"
for f in supervisor.sh player.sh; do
  fetch "bin/$f" "$PREFIX/bin/$f"
  chmod +x "$PREFIX/bin/$f"
  bash -n "$PREFIX/bin/$f"   # syntaxkoll innan vi kör
done
# valj.py maste med redan har. Utan den star ett nybrant kort kvar i gammalt
# "dumt" lage tills nagon rakar pusha lagret - och nya skarmar ska fa SAMMA
# version som de befintliga, inte en aldre. (Erik 2026-08-31.)
fetch "bin/valj.py" "$PREFIX/bin/valj.py"
chmod +x "$PREFIX/bin/valj.py"
python3 -m py_compile "$PREFIX/bin/valj.py" && rm -rf "$PREFIX/bin/__pycache__"

echo "==> systemd-tjänst (skärm=$NAME, media=$MEDIA_BASE, poll=${POLL}s, user=$RUN_USER)"
fetch "systemd/entilldisplay.service" /etc/systemd/system/entilldisplay.service
sed -i "s#supervisor.sh vagg5#supervisor.sh $NAME#"         /etc/systemd/system/entilldisplay.service
sed -i "s#^User=.*#User=$RUN_USER#"                          /etc/systemd/system/entilldisplay.service
sed -i "s#^Environment=POLL=.*#Environment=POLL=$POLL#"      /etc/systemd/system/entilldisplay.service
grep -q "MENY_BASE=" /etc/systemd/system/entilldisplay.service \
  || sed -i "/^Environment=POLL=/a Environment=MENY_BASE=$MEDIA_BASE" /etc/systemd/system/entilldisplay.service
fetch "systemd/entilldisplay-panel.service" /etc/systemd/system/entilldisplay-panel.service
sed -i "s#^Environment=SKARM_NAMN=.*#Environment=SKARM_NAMN=$NAME#" /etc/systemd/system/entilldisplay-panel.service
sed -i "s#^User=.*#User=$RUN_USER#"                                  /etc/systemd/system/entilldisplay-panel.service

systemctl daemon-reload
systemctl enable --now entilldisplay.service
systemctl enable --now entilldisplay-panel.service

echo "==> tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "   → kör: sudo tailscale up --advertise-tags=tag:signage"
else
  echo "   redan installerat ($(tailscale ip -4 2>/dev/null | head -1 || echo 'ej uppkopplad'))"
fi

# ── ÅTKOMST — LAG för varje skärm, inga undantag (se ATKOMST.md) ──────────────
# Skärmarna är ETT enhetligt system. Varje burk ska nås likadant, från både Macen
# och .52: användare `eriks` (sudo) + `root`, båda över Tailscale-SSH.
# Bakgrund: krog-dorr byggdes utan detta och blev en snöflinga som kostade en
# halv kväll att ta sig in på. Det ska inte kunna hända igen.

echo "==> åtkomst: användare eriks + nycklar"
if ! id eriks >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo eriks
  echo "   användare eriks skapad"
fi
echo 'eriks ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/eriks
chmod 440 /etc/sudoers.d/eriks
install -d -m 700 -o eriks -g eriks /home/eriks/.ssh
# Nycklar: Eriks MacBook + entill-intern (.52). Båda MÅSTE finnas — annars går burken
# bara att nå från ett håll, och den dagen det hållet strular är den oåtkomlig.
cat > /home/eriks/.ssh/authorized_keys <<'NYCKLAR'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIbvxaf+eWyGygpuP3Jq8DZ6jM5c/sZrd8UT3nXgoo+z eriksjostedt@MacBook-Pro.local
NYCKLAR
if [ -n "${EXTRA_KEY:-}" ]; then echo "$EXTRA_KEY" >> /home/eriks/.ssh/authorized_keys; fi
chmod 600 /home/eriks/.ssh/authorized_keys
chown -R eriks:eriks /home/eriks/.ssh

echo "==> åtkomst: Tailscale-SSH"
if tailscale status >/dev/null 2>&1; then
  # Panelen nabar pa tailnet-namnet: https://<burk>.<tailnet>.ts.net
  # Ingen port att komma ihag, riktigt cert, och inget oppnas mot LAN.
  # ⚠️ FALLA: serve-konfigurationen sitter pa NODNAMNET. Doper man om noden
  # slutar den fungera tyst (se reference_node_rename_broke_serve).
  tailscale serve --bg --https=443 http://127.0.0.1:8099 2>/dev/null \
    || tailscale serve https / http://127.0.0.1:8099 2>/dev/null \
    || echo "   VARNING: kunde inte satta upp tailscale serve for panelen"

  tailscale set --ssh --accept-risk=lose-ssh 2>/dev/null \
    && echo "   Tailscale-SSH på" \
    || echo "   VARNING: kunde inte sätta --ssh — kör manuellt: sudo tailscale set --ssh"
else
  echo "   VARNING: tailscale ej uppkopplad än — kör efter 'tailscale up': sudo tailscale set --ssh"
fi

echo "==> åtkomst: tidszon (svensk tid, se TIDSZON.md)"
timedatectl set-timezone Europe/Stockholm 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true

echo
echo "==> KLART — $NAME"
systemctl --no-pager --lines=0 status entilldisplay.service 2>/dev/null | head -3 || true
echo "   media : $MEDIA_BASE/$NAME.png"
echo "   loggar: journalctl -u entilldisplay -f   (taggen 'menyskarm')"
echo "   logga in: ssh eriks@$(hostname)      (reserv: ssh root@$(hostname))"
echo "   VERIFIERA från BÅDE Macen och .52 innan du lämnar burken — och lägg till"
echo "   den i NODER-listan i bin/skarm-access.sh, annars vaktas den inte."
