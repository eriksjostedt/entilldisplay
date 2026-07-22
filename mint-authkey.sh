#!/bin/sh
# mint-authkey.sh — körs PÅ .52 (har tailscale-behörigheten). Myntar en FÄRSK
# preauth-nyckel (tag:signage, reusable, preauthorized, kort livslängd) och skriver
# den till stdout. prepare-card.sh kör detta över ssh och bakar nyckeln på kortet.
#
# Föredrar en ICKE-UTGÅENDE OAuth-klient om den finns → evig järnkoll, inga datum att bevaka:
#   ~/.config/entill/tailscale-oauth  (rad 1 = client_id, rad 2 = client_secret)
# Annars faller den tillbaka på PAT:en (~/.config/entill/tailscale-api-key) som UTGÅR.
set -eu
CONF="$HOME/.config/entill"
BODY='{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":false,"preauthorized":true,"tags":["tag:signage"]}}},"expirySeconds":86400,"description":"entilldisplay firstboot (mint-on-demand)"}'
API="https://api.tailscale.com/api/v2/tailnet/-/keys"

if [ -f "$CONF/tailscale-oauth" ]; then
  CID=$(sed -n 1p "$CONF/tailscale-oauth"); CSEC=$(sed -n 2p "$CONF/tailscale-oauth")
  TOK=$(curl -s -d "client_id=$CID" -d "client_secret=$CSEC" \
        https://api.tailscale.com/api/v2/oauth/token \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
  JSON=$(curl -s -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d "$BODY" "$API")
else
  KEY=$(cat "$CONF/tailscale-api-key")
  JSON=$(curl -s -u "$KEY:" -H "Content-Type: application/json" -d "$BODY" "$API")
fi
printf '%s' "$JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])'
