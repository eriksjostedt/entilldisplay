#!/usr/bin/env bash
# entilldisplay supervisor — skyddsnätet. systemd kör DENNA (stabil, ändras sällan).
# Den kör i sin tur player-current.sh och vakar över den:
#   • OTA:      pollar repo/bin/player.sh → ny version → bash -n → tas i bruk → starta om.
#   • Rollback: kraschar aktuell player upprepat inom kort → hoppa till senast "good".
#   • Good:     en version som kört stabilt > GOOD_AFTER sek stämplas "good".
#
# Så du vågar skjuta ut en ny player: failar den, självläker skärmen tillbaka.
#
# Användning: supervisor.sh <skärmnamn>
set -u
NAME="${1:-vagg5}"
BASE_RAW="${REPO_RAW:-https://raw.githubusercontent.com/eriksjostedt/entilldisplay/main}"
PLAYER_URL="$BASE_RAW/bin/player.sh"
STATE="${STATE_DIR:-$HOME/.entilldisplay}"
VERD="$STATE/versions"
CUR="$VERD/player-current.sh"      # symlänk → aktiv version
GOOD="$VERD/player-good.sh"        # senast kända fungerande
POLL_UPDATE="${POLL_UPDATE:-300}"  # OTA-koll var 5:e min
GOOD_AFTER="${GOOD_AFTER:-300}"    # stabil i 5 min → good
MIN_RUN="${MIN_RUN:-60}"           # kortare körning än så = krasch
MAX_FAILS="${MAX_FAILS:-3}"        # så många snabba krascher → rollback
mkdir -p "$VERD"

log(){ logger -t entilldisplay-sup "$*" 2>/dev/null; echo "[sup] $*"; }

install_player(){  # $1 = källfil → ny current (versionerad + symlänk)
  local src="$1" ts; ts=$(date +%s)
  local dst="$VERD/player-$ts.sh"
  cp "$src" "$dst"; chmod +x "$dst"; ln -sf "$dst" "$CUR"
  # behåll bara de 5 senaste versionerna
  ls -1t "$VERD"/player-[0-9]*.sh 2>/dev/null | tail -n +6 | xargs -r rm -f
  log "player installerad: $(basename "$dst")"
}

# Bootstrap första gången: ta den bootstrap la i /opt, annars hämta från repo.
if [ ! -e "$CUR" ]; then
  if [ -x /opt/entilldisplay/bin/player.sh ]; then install_player /opt/entilldisplay/bin/player.sh
  else
    tmp=$(mktemp); curl -fsSL "$PLAYER_URL" -o "$tmp" && bash -n "$tmp" && install_player "$tmp"; rm -f "$tmp"
  fi
fi
[ -e "$GOOD" ] || cp "$(readlink -f "$CUR")" "$GOOD"   # initial good = current

fetch_update(){  # 0 om en ny, syntax-ren version installerades
  local tmp; tmp=$(mktemp)
  if curl -fsSL "$PLAYER_URL" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if ! cmp -s "$tmp" "$(readlink -f "$CUR")"; then
      if bash -n "$tmp" 2>/dev/null; then install_player "$tmp"; rm -f "$tmp"; return 0
      else log "ny player har SYNTAXFEL — ignoreras"; fi
    fi
  fi
  rm -f "$tmp"; return 1
}

fails=0; last_update=$(date +%s)
while true; do
  start=$(date +%s)
  "$CUR" "$NAME" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    # stabil länge nog → stämpla nuvarande som good
    if [ $((now-start)) -ge "$GOOD_AFTER" ] && ! cmp -s "$(readlink -f "$CUR")" "$GOOD"; then
      cp "$(readlink -f "$CUR")" "$GOOD"; log "version stämplad GOOD"
    fi
    # OTA
    if [ $((now-last_update)) -ge "$POLL_UPDATE" ]; then
      last_update=$now
      if fetch_update; then log "ny player → startar om"; kill "$pid" 2>/dev/null; fi
    fi
    sleep 5
  done
  wait "$pid" 2>/dev/null; rc=$?
  run=$(( $(date +%s) - start ))
  if [ "$run" -lt "$MIN_RUN" ]; then
    fails=$((fails+1)); log "player dog efter ${run}s (rc=$rc) — fails=$fails/$MAX_FAILS"
    if [ "$fails" -ge "$MAX_FAILS" ] && ! cmp -s "$(readlink -f "$CUR")" "$GOOD"; then
      log "ROLLBACK → good"; ln -sf "$(readlink -f "$GOOD")" "$CUR"; fails=0
    fi
  else
    fails=0
  fi
  sleep 2
done
