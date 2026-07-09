#!/usr/bin/env bash
# Kör FRÅN Macen: provisionera en ny skärm som redan är på tailnet.
# Förutsätter att burken bootat och du kört `sudo tailscale up` på den.
#
# Användning: provision.sh <tailnet-host> <skärmnamn> [media-base]
#   ex: provision.sh skarm1.tailf0de83.ts.net vagg1
set -euo pipefail
HOST="${1:?ange tailnet-host, t.ex. skarm1.tailf0de83.ts.net}"
NAME="${2:?ange skärmnamn, t.ex. vagg1}"
MEDIA="${3:-https://sundbrokrog.se/skarm}"
REPO="https://raw.githubusercontent.com/eriksjostedt/entilldisplay/main"

echo "==> provisionerar $NAME på $HOST …"
ssh "eriks@$HOST" "curl -fsSL $REPO/bootstrap.sh | sudo bash -s -- --name '$NAME' --media-base '$MEDIA'"
echo "==> klart. Kolla loggar:  ssh eriks@$HOST 'journalctl -u entilldisplay -n 20'"
