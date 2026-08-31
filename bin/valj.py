#!/usr/bin/env python3
# =====================================================================
# valj.py — BURKEN BESTÄMMER SJÄLV vilken meny som ska visas
# =====================================================================
# Skriver ut namnet på den bild som ska visas just nu, t.ex. "dagens.png".
# Exit 0 = beslut fattat. Exit 1 = kan inte besluta (playern behåller då
# sitt gamla beteende och visar det som hämtats utifrån).
#
# ⭐ VARFÖR DEN HÄR FILEN FINNS
# Skärmen var byggd "dum" med flit: hjärnan satt på .52 och burken visade
# bara vad den fick. Det höll tills 2026-08-25, då hela Knäppa föll och
# .52 tog schemat med sig i graven. Skärmarna stod kvar i fel läge utan
# att kunna göra något åt det — mitt i en lunchservering hade det betytt
# reklamskylten "Varje vardag 11.00-14.00" i stället för dagens rätt.
#
# Det bryter mot husets doktrin (feedback_lokal_autonomi_vs_server):
# ENHETEN ÄGER FUNKTIONEN, SERVERN ÄGER OPTIMERINGEN. Den lokala regeln
# är golvet — aldrig bara en kopia av något som bor någon annanstans.
#
# Så nu: burken har alla bilderna och schemat liggande, och väljer själv
# efter klockan. .52 uppdaterar INNEHÅLLET när den kan nås. Kan den inte
# nås visas gårdagens innehåll — men vid RÄTT tid på dygnet.
#
# ⚠️ TIDSZON: burkarna kör Europe/Stockholm, så lokal tid ÄR svensk tid.
# Servrarna kör UTC och måste gå via svtid.js — den fällan finns inte här,
# men flyttas den här koden till en server måste tidszonen hanteras.
# (Se reference_tidszon_svtid.)
#
# Logiken är en trogen kopia av decide() i vagg5-scheduler.js:
#   1. TEMADAG  — datumintervall OCH klockslag
#   2. SÄSONG   — datumintervall (hela dygnet)
#   3. DAGENS   — publicerad idag OCH veckodag OCH inom lunchfönster
#   4. FALLBACK — annars
# =====================================================================
import json
import sys
from datetime import datetime
from pathlib import Path

STATE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / ".entilldisplay"
SCHEMA = STATE / "schema.json"
LAGER = STATE / "lager"


def las(p, standard=None):
    try:
        return json.loads(p.read_text())
    except Exception:
        return standard


def minuter(t, standard=0):
    """'10:30' -> 630. Trasig indata ger standardvärdet i stället för krasch —
    ett felskrivet klockslag i schemat får aldrig släcka skylten."""
    try:
        bitar = str(t).split(":")
        return int(bitar[0]) * 60 + (int(bitar[1]) if len(bitar) > 1 else 0)
    except Exception:
        return standard


def besluta_regler(regler, nu):
    """Generell väg: en lista regler i PRIORITETSORDNING, första träffen vinner.

    Tre regeltyper räcker för alla skärmar vi har:
      intervall  — datumintervall, valfritt även klockslag
                   (temadag, säsong, helgöppet, tillfälligt stängt)
      dagsfarsk  — innehåll som bara gäller EN dag: kräver att `publicerad`
                   är dagens datum, plus veckodag och tidsfönster
                   (Dagens Lunch — utan detta annonseras gårdagens rätt som färsk)
      fallback   — matchar alltid, ligger sist

    Skärmarna skiljer sig bara i vilka lägen de har: vagg5 kör
    temadag/sasong/dagens/fallback, dorr kör stangt/helg/standard.
    """
    idag = nu.strftime("%Y-%m-%d")
    nu_min = nu.hour * 60 + nu.minute
    vd = nu.isoweekday() % 7

    for r in regler:
        if not isinstance(r, dict):
            continue
        lage = r.get("lage")
        if not lage:
            continue
        typ = r.get("typ", "intervall")

        if typ == "fallback":
            return lage, f"{lage}.png"

        if typ == "intervall":
            start = r.get("startdate") or r.get("date")
            slut = r.get("enddate") or r.get("date") or start
            if not start or not (start <= idag <= slut):
                continue
            if minuter(r.get("starttime"), 0) <= nu_min <= minuter(r.get("endtime"), 1439):
                return lage, f"{lage}.png"
            continue

        if typ == "dagsfarsk":
            if r.get("publicerad") != idag:
                continue
            if vd not in (r.get("weekdays") or [1, 2, 3, 4, 5]):
                continue
            if minuter(r.get("start"), 630) <= nu_min <= minuter(r.get("end"), 840):
                return lage, f"{lage}.png"
            continue

    # Ingen regel matchade och ingen fallback fanns — säg ifrån hellre än att gissa.
    return None, None


def besluta(schema, nu):
    idag = nu.strftime("%Y-%m-%d")
    nu_min = nu.hour * 60 + nu.minute
    # Samma veckodagsnumrering som JS getDay(): 0=söndag, 1=måndag ... 6=lördag.
    vd = nu.isoweekday() % 7

    # 1. TEMADAG — kräver BÅDE datum och klockslag. En temadag som pågår
    #    18-22 ska inte ta över frukosten.
    t = schema.get("temadag") or {}
    t_start = t.get("startdate") or t.get("date")
    t_slut = t.get("enddate") or t.get("date") or t_start
    if t_start and t_start <= idag <= t_slut:
        if minuter(t.get("starttime"), 0) <= nu_min <= minuter(t.get("endtime"), 1439):
            return "temadag", "temadag.png"

    # 2. SÄSONG — bara datumintervall, gäller hela dygnet.
    s = schema.get("sasong") or {}
    if s.get("startdate") and s.get("enddate") and s["startdate"] <= idag <= s["enddate"]:
        return "sasong", "sasong.png"

    # 3. DAGENS — tre villkor som alla måste hålla:
    #    publicerad för IDAG (annars visar vi gårdagens rätt som om den gällde),
    #    rätt veckodag, och inom lunchfönstret.
    d = schema.get("dagens") or {}
    fonster = schema.get("dagensWindow") or {}
    veckodagar = fonster.get("weekdays") or [1, 2, 3, 4, 5]
    i_fonster = (
        vd in veckodagar
        and minuter(fonster.get("start"), 630) <= nu_min <= minuter(fonster.get("end"), 840)
    )
    if d.get("publicerad") == idag and i_fonster:
        return "dagens", "dagens.png"

    # 4. FALLBACK
    return "fallback", "fallback.png"


def main():
    schema = las(SCHEMA)
    if not isinstance(schema, dict):
        # Inget schema → burken har inte fått lagret ännu. Säg ifrån så
        # playern kör vidare på gamla sättet i stället för att gissa.
        print("inget schema", file=sys.stderr)
        return 1

    # VALJ_NU låter tester ställa klockan ("2026-08-26 11:00"). Sätts aldrig
    # i drift — utan den gäller burkens egen klocka.
    import os

    nu_str = os.environ.get("VALJ_NU")
    nu = datetime.strptime(nu_str, "%Y-%m-%d %H:%M") if nu_str else datetime.now()

    # Nytt format (regellista) om det finns, annars det ursprungliga vagg5-formatet.
    # Båda vägarna behålls med flit: vagg5 gick i drift på det gamla formatet och
    # ska inte tvingas byta bara för att dorr kom till.
    if isinstance(schema.get("regler"), list):
        lage, bild = besluta_regler(schema["regler"], nu)
    else:
        lage, bild = besluta(schema, nu)

    if not bild:
        print("ingen regel matchade", file=sys.stderr)
        return 1

    fil = LAGER / bild

    if not fil.is_file() or fil.stat().st_size == 0:
        # Beslutet pekar på en bild vi inte har. Att visa fel bild vore värre
        # än att låta playern behålla det den redan visar.
        print(f"vald bild saknas: {fil}", file=sys.stderr)
        return 1

    print(fil)
    if "--verbose" in sys.argv:
        print(f"läge: {lage}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
