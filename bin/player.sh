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
# VIKTIGT: TERM/INT måste AVSLUTA. Tidigare körde traphanteraren bara pkill och lät
# sedan loopen fortsätta — signalen swaldes, playern vägrade dö, och supervisorns
# "kill $pid" vid OTA hade ingen effekt. Nya versioner installerades men togs
# ALDRIG i bruk. (Upptäckt 2026-07-28: en player levde 897 s efter sitt dödsbud.)
cleanup(){ pkill -f "mpv .*${DIR}/" 2>/dev/null; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

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

# Har vi en cachad bild sedan tidigare: VISA DEN DIREKT och gå vidare till poll-loopen.
# Skärmen ska aldrig vara svart bara för att källan råkar vara onåbar vid uppstart —
# menyn från igår är oändligt mycket bättre än ingen meny. Poll-loopen hämtar nytt
# så fort källan svarar igen. (2026-07-28: exakt detta släckte vagg1 under ett
# nätavbrott hemma — burken startade om, cachen fanns, men visades aldrig.)
if [ -s "$IMG" ]; then
  logger -t menyskarm "startad ($NAME), visar cachad bild medan källan söks"
  show "$IMG"
else
  # Ingen cache — då måste vi vänta på en första bild.
  # Hämta till .new så ett misslyckat försök aldrig kan skada en befintlig cache.
  until curl -fsS -o "$IMG.new" "$URL" && [ -s "$IMG.new" ]; do
    rm -f "$IMG.new"; logger -t menyskarm "väntar på nät/bild…"; sleep 10
  done
  mv "$IMG.new" "$IMG"
  logger -t menyskarm "startad ($NAME), visar första bilden"
  show "$IMG"
fi

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
