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

## 🔴 Vad servern ska leverera (ej byggt än — planerat helgen 29–30 aug 2026)

Burken hämtar, med conditional GET (`If-Modified-Since`), var femte minut:

```
<BASE>/<skärm>/schema.json
<BASE>/<skärm>/lager/dagens.png
<BASE>/<skärm>/lager/fallback.png
<BASE>/<skärm>/lager/temadag.png
<BASE>/<skärm>/lager/sasong.png
```

där `BASE` är `https://sundbrokrog.se/skarm` (`MENY_BASE`).

**.56** ska publicera den strukturen. Behåll den gamla
`<BASE>/<skärm>.png` — burkar utan lager faller tillbaka på den.

**.52** ska sluta *bestämma* åt skärmen. `vagg5-scheduler.js` byter roll: i
stället för att välja bild och swappa den, ska den *generera lagret*
(`bygg-lager.js` i repot `entillmeny` gör redan exakt detta) och skicka det
till .56. Tidsbeslutet ägs av burken.

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
