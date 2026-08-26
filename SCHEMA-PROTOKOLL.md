# Schema-protokollet — vad en skärm behöver, och vem som levererar det

Sedan 2026-08-25 **bestämmer burken själv vilken meny som visas.** Servern
levererar innehåll; burken äger klockan. Det här dokumentet är kontraktet
mellan de två, så att .52/.56 — eller en helt ny burk — kan tas i drift utan
att någon behöver minnas hur det hänger ihop.

## Varför

Knäppa föll 2026-08-25 och tog .52 + .56 med sig. Krogens skärmar stod kvar i
fel läge och kunde inte byta till Dagens Lunch kl 07:00, eftersom hela
beslutet bodde på .52. Doktrinen i huset är den omvända: **enheten äger
funktionen, servern äger optimeringen.** Den lokala regeln är golvet — aldrig
bara en kopia av något som bor någon annanstans.

Praktisk konsekvens: en skärm utan nät visar fortfarande *rätt bild vid rätt
klockslag*. Den visar bara inte *färskt innehåll*.

## Vad burken har lokalt

```
~/.entilldisplay/
  valj.py            beslutaren (hämtas inte OTA — läggs dit vid installation)
  schema.json        beslutsunderlaget
  lager/
    dagens.png       Dagens Lunch
    fallback.png     visas utanför lunchtid
    temadag.png      valfri
    sasong.png       valfri
  <namn>.png         GAMLA vägen — används bara om lager/valj.py saknas
```

`player.sh` hämtas OTA från detta repo av `supervisor.sh` var femte minut,
med syntaxkontroll och rollback. Den behöver aldrig installeras för hand.

## schema.json

```json
{
  "dagensWindow": { "start": "07:00", "end": "14:00", "weekdays": [1,2,3,4,5] },
  "dagens":  { "publicerad": "2026-08-26", "rubrik": "Onsdag 26 augusti" },
  "temadag": { "startdate": "", "enddate": "", "starttime": "", "endtime": "" },
  "sasong":  { "startdate": "2026-07-07", "enddate": "2026-08-09" },
  "genererad": "2026-08-25T18:33:00.000Z"
}
```

- `weekdays` följer JS `getDay()`: **0 = söndag**, 1 = måndag … 6 = lördag.
- `dagens.publicerad` är det datum dagens-bilden **gäller för**. Är det inte
  dagens datum visas fallbacken — annars skulle gårdagens rätt annonseras som
  färsk. Detta är hela poängen med fältet.
- Datum är `YYYY-MM-DD`, klockslag `HH:MM`, båda i **svensk tid**. Burkarna kör
  Europe/Stockholm, så deras lokala tid är svensk tid. Servrarna kör UTC och
  måste gå via `svtid.js` innan de skriver hit.
- ⚠️ Lunchfönstret på Sundbro krog är **07:00–14:00**, inte 10:30 som
  defaultvärdet i koden antyder.

## Beslutsordning (valj.py)

1. **Temadag** — om `idag` ligger i datumintervallet **och** klockan i
   `starttime`–`endtime`.
2. **Säsong** — om `idag` ligger i datumintervallet (hela dygnet).
3. **Dagens** — om `dagens.publicerad == idag` **och** veckodagen finns i
   `weekdays` **och** klockan är inom fönstret.
4. **Fallback** — annars.

Saknas `schema.json`, eller pekar beslutet på en bild som inte finns, säger
`valj.py` ifrån (exit 1) och playern kör vidare på det gamla sättet. Att visa
fel bild vore värre än att behålla den som redan står på skärmen.

## Pull är primärt, push är komplement

**En push når bara en PÅSLAGEN skärm.** Krogen stänger av apparaterna vid
stängning; vagg1 var avstängd 2026-08-25 och missade innehållet helt, hur många
gånger man än pushade. Hämtar burken själv fixar den sig när den vaknar — det
är samma princip som att den äger sitt schema.

- **Pull (normalläget):** burken hämtar schema + lager från `<BASE>` var 5:e
  minut. Fungerar även för en skärm som varit avstängd i en vecka.
- **Push (`skyltpush.sh`):** omedelbar effekt när man står och väntar på
  resultatet, och **reservväg när Knäppa är nere**. Rapporterar per skärm om
  burken valde rätt bild och att mpv kör den. Den kontrollerar om pull-källan
  svarar: gör den det är en avstängd skärm ofarlig, annars sägs det rakt ut att
  skärmen missar innehållet.

## 🟡 Serversidan — KODAD, väntar driftsättning (.52/.56 nere sedan 2026-08-25)

Burken hämtar, med conditional GET (`If-Modified-Since`), var femte minut:

```
<BASE>/<skärm>/schema.json
<BASE>/<skärm>/lager/dagens.png
<BASE>/<skärm>/lager/fallback.png
<BASE>/<skärm>/lager/temadag.png
<BASE>/<skärm>/lager/sasong.png
```

där `BASE` är `https://sundbrokrog.se/skarm` (`MENY_BASE`).

✅ **Koden finns** (repo `entillmeny`, pushad 2026-08-26):
`publish-skarm.sh --med-lager` kör `bygg-lager.js --ut=<webbrot>` för vagg5 och
dorr, och rsync:ar hela `skarm/`-trädet till .56. Anropas från `distribute.js`,
dvs vid publicering — **aldrig i cron**, eftersom det renderar åtta 4K-PNG genom
Chromium. Cron-körningen (utan flagga) speglar bara.

Verifierat att den producerade strukturen matchar `SCHEMA_URL`/`LAGER_URL` i
`player.sh`.

**Kvar att göra när .52/.56 är uppe:**
1. `git pull` på .52 så den får `bygg-lager.js` + nya `publish-skarm.sh`.
2. Kör `publish-skarm.sh --med-lager` en gång och kontrollera att
   `https://sundbrokrog.se/skarm/vagg5/schema.json` svarar 200 med korrekt
   `Last-Modified` (annars faller conditional GET och varje poll drar hela
   bildmängden).
3. `vagg5-scheduler.js` / `dorr-scheduler.js` byter roll: sluta *bestämma* åt
   skärmen, bara *generera lagret*. Tidsbeslutet ägs av burken.
4. Den gamla `<BASE>/<skärm>.png` **behålls** — burkar utan lager faller
   tillbaka på den. Ta bort först när alla skärmar är omställda.

Filerna måste ha korrekt `Last-Modified`, annars fungerar inte den
villkorade hämtningen och varje poll drar hela bildmängden.

## Reservväg när Knäppa är nere

`skyltpush.sh` (repo `entillmeny`) pushar lager och schema direkt till
burkarna över tailnet-SSH. Bilderna ligger i Dropbox
(`~/Library/CloudStorage/Dropbox/sundbroskyltar/`), så de följer med vid
datorbyte.

Burkarna kan **inte** hämta från Macen: macOS-brandväggen (Little Snitch +
stealth mode) släpper inte in TCP utifrån. SSH ut från Macen fungerar
däremot, så flödet vändes.

## Ta en ny burk i drift

1. Installera `entilldisplay.service` → `supervisor.sh <namn>`. Playern hämtas
   OTA från detta repo automatiskt.
2. Lägg `valj.py`, `schema.json` och `lager/` i `~/.entilldisplay/`
   (`skyltpush.sh` gör det, eller så hämtas de från servern när den är uppe).
3. Klart. Utan steg 2 fungerar burken ändå — då på gamla vägen.

## Vad som INTE går att verifiera på distans

`mpv --vo=drm` ritar direkt på DRM-planet, förbi `/dev/fb0`. `fbcat` ger
därför bara konsolen, inte menyn. Att rätt fil ligger på burken och att mpv
kör med den går att bevisa — att den *syns* kräver ögon på plats.
