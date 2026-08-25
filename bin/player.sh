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

# --- RESERVKÄLLA (valfri) -------------------------------------------------
# Sätts per burk i $DIR/reserv.conf, en rad:  MENY_RESERV=http://100.x.y.z:8099
# Filen ligger i skärmens egen statemapp och överlever OTA-uppdateringar.
#
# ⭐ RESERVEN PROVAS BARA NÄR PRIMÄREN ÄR ONÅBAR. Svarar sundbrokrog.se 200
# eller 304 rörs reserven aldrig — i normaldrift finns det alltså ingen trafik
# alls mot reservvärden. Det är med flit: reserven är typiskt Eriks laptop,
# och den ska inte pollas dygnet runt av krogens skärmar.
#
# ⭐ ÄLDRE BILD PÅ RESERVEN KAN INTE SKADA. Hämtningen sker med -z (lokala
# filens mtime), så en reservbild som är äldre än den vi redan visar ger 304
# och ignoreras. Vill man medvetet köra över .56 räcker det att filen på
# reservvärden är NYARE än den skärmen har.
#
# BAKGRUND 2026-08-25: hela Knäppa föll (router utan ström) och tog .52+.56
# med sig. Krogens skärmar stod kvar med gårdagens meny och det fanns ingen
# väg att uppdatera dem alls — kvar var 50 mil bil. Reservkällan är svaret.
[ -r "$DIR/reserv.conf" ] && . "$DIR/reserv.conf"
RESERV="${MENY_RESERV:-}"
RESERV_URL="${RESERV:+${RESERV%/}/${NAME}.png}"

# Hämtar $1 till $IMG.new med conditional GET. Ekar HTTP-koden (000 = ingen
# kontakt). --max-time så en halvdöd källa inte kan låsa poll-loopen.
hamta() {
  curl -s -o "$IMG.new" -w "%{http_code}" -z "$IMG" --max-time 25 "$1" 2>/dev/null
}

# --- LOKALT SCHEMA (burken bestämmer själv) -------------------------------
# ⭐ SKÄRMEN ÄR INTE LÄNGRE DUM. Tidigare satt hela beslutet om VILKEN meny
# som ska visas på .52, och burken visade bara vad den fick serverat. När
# Knäppa föll 2026-08-25 tog .52 schemat med sig — skärmarna kunde inte byta
# till Dagens Lunch kl 10:30 hur gärna de än ville.
#
# Nu ligger schemat och alla lägesbilder lokalt i $DIR/lager, och valj.py
# väljer efter burkens egen klocka. Servern uppdaterar INNEHÅLLET; burken
# äger TIDPUNKTEN. (feedback_lokal_autonomi_vs_server: enheten äger
# funktionen, servern optimeringen.)
#
# Saknas lager eller schema faller allt tillbaka på det gamla beteendet —
# en burk som inte hunnit få lagret fungerar precis som förut.
VALJ="$DIR/valj.py"
LAGER="$DIR/lager"
SCHEMA="$DIR/schema.json"
SCHEMA_URL="${BASE%/}/${NAME}/schema.json"
LAGER_URL="${BASE%/}/${NAME}/lager"

# Ekar sökvägen till den bild som ska visas nu, eller tomt om burken inte
# kan avgöra det själv (då gäller gamla vägen).
valj_bild() {
  [ -f "$VALJ" ] || return 1
  python3 "$VALJ" "$DIR" 2>/dev/null
}

# Hämtar schema + lägesbilder från servern när den går att nå. Varje fil
# hämtas med conditional GET, så det kostar ~200 byte per fil när inget
# ändrats. Misslyckas något lämnas den befintliga filen orörd — ett halvt
# hämtat lager får aldrig ersätta ett helt.
uppdatera_lager() {
  mkdir -p "$LAGER"
  curl -fsS --max-time 25 -o "$SCHEMA.new" -z "$SCHEMA" "$SCHEMA_URL" 2>/dev/null \
    && [ -s "$SCHEMA.new" ] && mv "$SCHEMA.new" "$SCHEMA"
  rm -f "$SCHEMA.new"
  for lage in dagens fallback temadag sasong; do
    f="$LAGER/$lage.png"
    curl -fsS --max-time 40 -o "$f.new" -z "$f" "$LAGER_URL/$lage.png" 2>/dev/null \
      && [ -s "$f.new" ] && mv "$f.new" "$f"
    rm -f "$f.new"
  done
}

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
# Har burken eget schema och lager: låt den bestämma redan vid uppstart, så
# en omstart 10:31 inte visar fallbacken tills första pollen gått.
start_vald=""
[ -f "$VALJ" ] && start_vald=$(valj_bild)

if [ -n "$start_vald" ]; then
  logger -t menyskarm "startad ($NAME), lokalt beslut: $(basename "$start_vald")"
  show "$start_vald"
elif [ -s "$IMG" ]; then
  logger -t menyskarm "startad ($NAME), visar cachad bild medan källan söks"
  show "$IMG"
else
  # Ingen cache — då måste vi vänta på en första bild.
  # Hämta till .new så ett misslyckat försök aldrig kan skada en befintlig cache.
  # Kall start utan cache: primären först, reserven som andra försök. En burk
  # som startas om medan .56 är nere ska kunna få en bild ändå.
  until { curl -fsS --max-time 25 -o "$IMG.new" "$URL" && [ -s "$IMG.new" ]; } || \
        { [ -n "$RESERV_URL" ] && curl -fsS --max-time 25 -o "$IMG.new" "$RESERV_URL" && [ -s "$IMG.new" ]; }; do
    rm -f "$IMG.new"; logger -t menyskarm "väntar på nät/bild…"; sleep 10
  done
  mv "$IMG.new" "$IMG"
  logger -t menyskarm "startad ($NAME), visar första bilden"
  show "$IMG"
fi

# Innehålls-signatur, så att en bild som BYTT INNEHÅLL men behållit filnamn
# (sasong→sasong efter en omrendering) också visas om. Att bara jämföra
# filnamn missade exakt det 2026-07-13.
sig() { [ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -c1-16; }

# Kom vi hit efter ett lokalt beslut vid uppstart: notera vad som redan visas,
# annars skulle första poll-varvet starta om mpv i onödan (synligt blink).
visad_sig=""
[ -n "${start_vald:-}" ] && visad_sig="$start_vald:$(sig "$start_vald")"
varv=0

# Poll-loop: -z = If-Modified-Since (lokala filens mtime) → 304 om oförändrad.
while true; do
  sleep "$POLL"
  varv=$((varv + 1))

  # --- VÄG 1: burken bestämmer själv ------------------------------------
  # Lagret uppdateras var femte varv (≈5 min) — det är innehåll, inte
  # tidpunkt, och behöver inte gå fortare. Beslutet däremot fattas VARJE
  # varv, så bytet kl 10:30 sker på minuten även om servern är onåbar.
  if [ -f "$VALJ" ]; then
    [ $((varv % 5)) -eq 1 ] && uppdatera_lager
    vald=$(valj_bild)
    if [ -n "$vald" ]; then
      ny_sig="$vald:$(sig "$vald")"
      if [ "$ny_sig" != "$visad_sig" ]; then
        visad_sig="$ny_sig"
        logger -t menyskarm "lokalt beslut ($NAME): $(basename "$vald")"
        show "$vald"
      fi
      continue
    fi
  fi

  # --- VÄG 2: gamla vägen (ingen lokal beslutsförmåga) ------------------
  kalla="primär"
  code=$(hamta "$URL")

  # Primären onåbar? (000 = ingen kontakt, 5xx = trasig server). 200 och 304
  # betyder båda att .56 lever och har sagt sitt — då rörs inte reserven.
  case "$code" in
    200|304) ;;
    *)
      if [ -n "$RESERV_URL" ]; then
        rm -f "$IMG.new"
        code=$(hamta "$RESERV_URL")
        kalla="reserv"
      fi ;;
  esac

  if [ "$code" = "200" ] && [ -s "$IMG.new" ]; then
    mv "$IMG.new" "$IMG"
    logger -t menyskarm "ny meny hämtad ($NAME, $kalla) — visar om"
    show "$IMG"
  else
    rm -f "$IMG.new"
  fi
done
