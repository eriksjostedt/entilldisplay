#!/usr/bin/env python3
"""mint-authkey.py — körs PÅ .52 (har tailscale-behörigheten). Myntar en FÄRSK
preauth-nyckel (tag:signage, reusable, preauthorized, kort livslängd) och skriver
nyckeln till stdout. prepare-card.sh kör den via `ssh … 'python3 -' < mint-authkey.py`.

Föredrar en ICKE-UTGÅENDE OAuth-klient om den finns → evig järnkoll, inga datum att bevaka:
    ~/.config/entill/tailscale-oauth   (rad 1 = client_id, rad 2 = client_secret)
Annars faller den tillbaka på PAT:en (~/.config/entill/tailscale-api-key) som UTGÅR.
"""
import base64, json, os, sys, urllib.parse, urllib.request

CONF = os.path.expanduser("~/.config/entill")
KEYS_URL = "https://api.tailscale.com/api/v2/tailnet/-/keys"
TOKEN_URL = "https://api.tailscale.com/api/v2/oauth/token"
BODY = {"capabilities": {"devices": {"create": {
    "reusable": True, "ephemeral": False, "preauthorized": True,
    "tags": ["tag:signage"]}}},
    "expirySeconds": 86400, "description": "entilldisplay signage firstboot"}


def _post(url, data_bytes, headers):
    req = urllib.request.Request(url, data=data_bytes, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def main():
    oauth = os.path.join(CONF, "tailscale-oauth")
    if os.path.exists(oauth):
        lines = [l.strip() for l in open(oauth) if l.strip()]
        cid, csec = lines[0], lines[1]
        tok = _post(TOKEN_URL,
                    urllib.parse.urlencode({"client_id": cid, "client_secret": csec}).encode(),
                    {"Content-Type": "application/x-www-form-urlencoded"})["access_token"]
        res = _post(KEYS_URL, json.dumps(BODY).encode(),
                    {"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    else:
        api = open(os.path.join(CONF, "tailscale-api-key")).read().strip()
        auth = base64.b64encode((api + ":").encode()).decode()
        res = _post(KEYS_URL, json.dumps(BODY).encode(),
                    {"Authorization": "Basic " + auth, "Content-Type": "application/json"})
    sys.stdout.write(res["key"])


if __name__ == "__main__":
    main()
