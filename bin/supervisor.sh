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
VALJ_URL="$BASE_RAW/bin/valj.py"
STATE="${STATE_DIR:-$HOME/.entilldisplay}"
VERD="$STATE/versions"
CUR="$VERD/player-current.sh"      # symlänk → aktiv version
GOOD="$VERD/player-good.sh"        # senast kända fungerande
POLL_UPDATE="${POLL_UPDATE:-300}"  # OTA-koll var 5:e min
OTA_FRAN="${OTA_FRAN:-14}"         # uppdateringar tas i bruk tidigast kl
OTA_TILL="${OTA_TILL:-23}"         # ...och senast kl
PROV_TID="${PROV_TID:-120}"        # sa lange far en ny version bevisa att den VISAR nagot
GOOD_AFTER="${GOOD_AFTER:-300}"    # stabil i 5 min → good
MIN_RUN="${MIN_RUN:-60}"           # kortare körning än så = krasch
MAX_FAILS="${MAX_FAILS:-3}"        # så många snabba krascher → rollback
mkdir -p "$VERD"

log(){ logger -t entilldisplay-sup "$*" 2>/dev/null; echo "[sup] $*"; }

larma(){  # $1=rubrik $2=text — bast mojliga: ntfy om konfig finns, annars logg
  local url topic
  url=$(sudo -n grep -h '^NTFY_URL=' /etc/entill-sentinel/sentinel.conf 2>/dev/null | cut -d= -f2- | tr -d '"')
  topic=$(sudo -n grep -h '^NTFY_TOPIC=' /etc/entill-sentinel/sentinel.conf 2>/dev/null | cut -d= -f2- | tr -d '"')
  [ -n "$url" ] && [ -n "$topic" ] || return 0
  curl -fsS -m 20 -H "Title: $1" -H "Priority: high" -d "$2" "${url%/}/$topic" >/dev/null 2>&1
}

# ── Sjalvlakning: racker det att processen lever? Nej. ──────────────────────
# Erik 2026-08-31: "om den nya versionen inte visar vasentlig bild for den
# skarmen, sa skulle den kunna backa tillbaka till forra versionen och meddela
# att det var problem. Jag ar 1 mil eller 50 mil ifran restaurangen."
#
# Kriteriet ar darfor VISAS NAGOT, inte lever processen. En player kan leva och
# anda visa svart - det ar precis vad som hander om mpv dor tyst (den startas
# med >/dev/null 2>&1 &).
#
# UNDANTAG som maste finnas: ar ingen skarm ansluten KAN mpv omojligt kora. Da
# ar det inte versionens fel, och att rulla tillbaka vore ett falsklarm som
# doljer det verkliga problemet. Dorrskylten stod utan HDMI 2026-08-31 - hade
# vi rullat tillbaka dar hade vi jagat en programvarubugg som inte fanns.
skarm_ansluten(){
  grep -qx connected /sys/class/drm/card*-HDMI-A-*/status 2>/dev/null
}
visar_nagot(){
  pgrep -f "mpv .*$STATE/" >/dev/null 2>&1
}

# ── EN aterrullning for alla lagen ─────────────────────────────────────────
# Erik 2026-08-31: "da ska vi nog anvanda samma funktion for aterrullning,
# bara att kunna anvanda den i fler situationer."
# Skalet foljer med rakt ut i loggen OCH notisen, sa den som ar fem mil bort
# far veta VARFOR och inte bara ATT det hande.
#
# Skyddet mot slinga: kor vi redan good finns inget att backa till. Utan den
# kollen skulle en burk med trasig HARDVARA (t.ex. urkopplad HDMI) rulla
# tillbaka om och om igen och larma varje gang.
rulla_tillbaka(){  # $1 = skal, i klartext
  local skal="$1"
  if cmp -s "$(readlink -f "$CUR")" "$(readlink -f "$GOOD")" 2>/dev/null; then
    log "återrullning begärd ($skal) men vi kör redan good — låter den vara"
    return 1
  fi
  log "ÅTERRULLNING → good: $skal"
  ln -sf "$(readlink -f "$GOOD")" "$CUR"
  fails=0; pa_prov=""
  larma "Skärm $NAME rullade tillbaka" \
        "$skal — kör nu senast kända fungerande version. Behöver ses över."
  kill "$pid" 2>/dev/null
  return 0
}

# Att ta en ny version i bruk startar om spelaren - en synlig blink pa en skarm
# som gaster tittar pa. Det far inte hanta mitt i lunchserveringen.
# Erik 2026-08-31: "Garna nar de ar igang, efter lunchtid."
# Utanfor fonstret hamtar vi ingenting alls; forsta cykeln efter kl 14 tar det.
# Burkarna kor Europe/Stockholm, sa klockan har ar lokal tid (till skillnad fran
# servrarna som kor UTC - jfr reference_tidszon_svtid).
ota_tillaten(){
  local h; h=$(date +%-H)
  [ "$h" -ge "$OTA_FRAN" ] && [ "$h" -lt "$OTA_TILL" ]
}

# valj.py ar hjarnan som avgor VILKEN meny som visas. Den kom tidigare BARA med
# lager-pushen (skyltpush packar den i tarren) - vilket betydde tva saker:
#   1. En uppdatering i git nadde aldrig en burk av sig sjalv.
#   2. Ett nybrant kort saknade den helt tills nagon rakade pusha lagret, och
#      stod till dess kvar i gammalt "dumt" lage.
# Nu foljer den samma OTA-vag som player.sh: hamtas fran git, syntaxkollas,
# och byts bara om den faktiskt skiljer sig. En trasig valj.py far aldrig
# installeras - da ar det battre att kora vidare pa den gamla.
hamta_valj(){
  local tmp; tmp=$(mktemp)
  if curl -fsSL "$VALJ_URL" -o "$tmp" 2>/dev/null && [ -s "$tmp" ] \
     && python3 -m py_compile "$tmp" 2>/dev/null; then
    if ! cmp -s "$tmp" "$STATE/valj.py" 2>/dev/null; then
      cp "$tmp" "$STATE/valj.py" && chmod +x "$STATE/valj.py" \
        && log "valj.py uppdaterad via OTA"
    fi
  fi
  rm -f "$tmp" "${tmp}c" 2>/dev/null
  rm -rf "$(dirname "$tmp")/__pycache__" 2>/dev/null
}

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

fails=0; last_update=$(date +%s); pa_prov=""
while true; do
  start=$(date +%s)
  "$CUR" "$NAME" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    # stabil länge nog → stämpla nuvarande som good
    # En version som visar SVART far aldrig stamplas GOOD - da har vi inget
    # friskt att rulla tillbaka till nasta gang. Saknas skarm helt kan vi inte
    # doma, och da racker det att den ar stabil.
    if [ $((now-start)) -ge "$GOOD_AFTER" ] && ! cmp -s "$(readlink -f "$CUR")" "$GOOD"; then
      if visar_nagot || ! skarm_ansluten; then
        cp "$(readlink -f "$CUR")" "$GOOD"; log "version stämplad GOOD"
      else
        log "visar inget — stämplar INTE GOOD"
      fi
    fi

    # 2. Ny version pa prov: visar den nagot inom PROV_TID? Annars tillbaka.
    if [ -n "${pa_prov:-}" ] && [ $((now-pa_prov)) -ge "$PROV_TID" ]; then
      if skarm_ansluten && ! visar_nagot; then
        rulla_tillbaka "Ny version visade ingen bild på ${PROV_TID}s trots ansluten skärm"
      elif ! skarm_ansluten; then
        log "kan inte döma ny version — ingen skärm ansluten"
      else
        log "ny version visar bild ✓"
      fi
      pa_prov=""
    fi
    # OTA
    if [ $((now-last_update)) -ge "$POLL_UPDATE" ]; then
      last_update=$now
      if ota_tillaten; then
        hamta_valj
        if fetch_update; then
        pa_prov=$(date +%s)   # nu ska den bevisa att den visar nagot
        log "ny player → startar om"
        kill "$pid" 2>/dev/null
        # Eskalera. En player kan sitta fast i en lång curl-timeout (~135 s) och
        # hinner då inte reagera på TERM — eller vara en gammal version vars trap
        # inte avslutar alls. Utan detta installeras nya versioner utan att någonsin
        # tas i bruk, och OTA:n är i praktiken död.
        for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        if kill -0 "$pid" 2>/dev/null; then
          log "player svarade ej på TERM efter 20 s — SIGKILL"
          pkill -f "mpv .*$STATE/" 2>/dev/null
          kill -9 "$pid" 2>/dev/null
        fi
        fi
      fi
    fi
    sleep 5
  done
  wait "$pid" 2>/dev/null; rc=$?
  run=$(( $(date +%s) - start ))
  if [ "$run" -lt "$MIN_RUN" ]; then
    fails=$((fails+1)); log "player dog efter ${run}s (rc=$rc) — fails=$fails/$MAX_FAILS"
    if [ "$fails" -ge "$MAX_FAILS" ]; then
      rulla_tillbaka "Spelaren kraschade $fails gånger i rad (senast efter ${run}s)"
    fi
  else
    fails=0
  fi
  sleep 2
done
