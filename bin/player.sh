#!/usr/bin/env bash
# Menyskärm-player (pilot) — ersätter pisignage-mellanhanden.
# Hjärnan (VILKEN meny som ska visas) sitter på .52; den här skärmen är "dum":
# den pollar sin egen bild-URL med conditional GET och visar den fullskärm via
# mpv/DRM (ingen desktop krävs; funkar på Pi 3B/4/5 med KMS).
#
# Mobildata: så länge menyn är oförändrad svarar servern 304 Not Modified
# (~200 byte per poll). Full bild (~2–3 MB) hämtas bara när menyn faktiskt byts.
#
# Användning: player.sh <skärmnamn>     (default: vagg5)
set -u
NAME="${1:-vagg5}"
BASE="${MENY_BASE:-https://sundbrokrog.se/skarm}"
URL="$BASE/${NAME}.png"
DIR="${STATE_DIR:-$HOME/.entilldisplay}"
IMG="$DIR/${NAME}.png"
POLL="${POLL:-60}"          # sekunder mellan pollar
mkdir -p "$DIR"

# Städa mpv-barnen när playern avslutas (t.ex. när supervisorn startar om oss).
trap 'pkill -f "mpv .*${DIR}/" 2>/dev/null' EXIT INT TERM

show() {
  pkill -f "mpv .*${DIR}/" 2>/dev/null
  sleep 0.3
  local f="$1"
  local common=(--vo=drm --fullscreen --no-osc --no-input-default-bindings --no-terminal --really-quiet)
  case "${f,,}" in
    *.mp4|*.mkv|*.mov|*.webm|*.m4v)
      # Video: loopa, hårdvaruavkodning (3B/4/5).
      mpv "${common[@]}" --loop-file=inf --hwdec=auto "$f" >/dev/null 2>&1 & ;;
    *)
      # Stillbild: visa oändligt.
      mpv "${common[@]}" --image-display-duration=inf --loop-file=inf --no-audio "$f" >/dev/null 2>&1 & ;;
  esac
}

# Initial hämtning — blockera tills vi fått en bild (tål att nätet inte är uppe vid boot).
until curl -fsS -o "$IMG" "$URL"; do logger -t menyskarm "väntar på nät/bild…"; sleep 10; done
logger -t menyskarm "startad ($NAME), visar första bilden"
show "$IMG"

# Poll-loop: -z = If-Modified-Since (lokala filens mtime) → 304 om oförändrad.
while true; do
  sleep "$POLL"
  code=$(curl -s -o "$IMG.new" -w "%{http_code}" -z "$IMG" "$URL" 2>/dev/null)
  if [ "$code" = "200" ] && [ -s "$IMG.new" ]; then
    mv "$IMG.new" "$IMG"
    logger -t menyskarm "ny meny hämtad ($NAME) — visar om"
    show "$IMG"
  else
    rm -f "$IMG.new"
  fi
done
