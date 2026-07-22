# entilldisplay

Självhostat digital signage för Raspberry Pi — ersätter pisignage som mellanhand.
Skärmarna är "dumma": hjärnan (vilken meny/bild som ska visas, schemat) sitter på
**entill-intern (.52)**; varje skärm pollar sitt innehåll och visar det fullskärm.

> **Status:** pilot körs på `entill-vakt (.48)`. Player + bandbredds-snål poll +
> server-endpoint verifierade. Supervisor (OTA/rollback) och WiFi-failsafe är
> specificerade nedan och byggs härnäst. Se [Status & TODO](#status--todo).

---

## Varför

pisignage kostar ~1 000 kr/år och är i praktiken bara **(a)** en fullskärms-bildvisare
och **(b)** en molnmötespunkt som når skärmar bakom mobilt nät. Allt det svåra
(menygenerering, schemaläggning, `decide()`-logiken, webb-rendering) gör redan .52.
Det som återstår äger vi enkelt själva — utan årsavgift och utan mellanhand.

## Principer

1. **En fjärrskärm får aldrig kunna bli obrukbar.** Annars = bilresa + tangentbord.
   Allt nedan (rollback, WiFi-failsafe, "radera aldrig ett fungerande nät") följer av det.
2. **Skärmen pollar (pull), aldrig push.** Då spelar mobilt nät/CGNAT ingen roll —
   skärmen behöver bara *utgående* internet.
3. **Bilder publikt, kontroll privat.** Menybilder är offentliga → publik URL med
   bandbredds-snål poll. WiFi-lösen/kommandon/skript-uppdateringar → privat över Tailscale.
4. **Headless.** Ingen desktop. `mpv --vo=drm` ritar rakt på KMS/DRM. Pi OS Lite.
5. **Stå på färdiga system.** mpv (bild+video), NetworkManager (WiFi), Tailscale (mesh/SSH),
   Caddy (ETag/304). Vi hemkodar bara det tunna limmet.
6. **Kabel = räddningslina.** En inkopplad nätverkskabel ska *alltid* ge nät (ethernet
   autoconnect, högsta prioritet). Det är den ultimata failsafe:n: även om WiFi är helt dött
   och Tailscale inte når ut, räcker det att koppla in en kabel för att burken ska komma
   online igen och bli nåbar för fjärrfix. Löser WiFi-moment-22:et.

## Arkitektur

```
                       ┌─────────────────────────────────────────┐
   entill-intern (.52) │  decide()  → vilken meny/bild per skärm  │
        "hjärnan"      │  genererar PNG/MP4, skriver config       │
                       └───────────────┬─────────────────────────┘
                       publik (bild)   │   privat (config/wifi/skript)
             via Caddy/.56 med ETag    │   via Tailscale (tag:signage)
                                       │
   ┌───────────────────────────────────┼───────────────────────────────┐
   │  Raspberry Pi (3B / 4 / 5), Pi OS Lite, headless                   │
   │                                                                   │
   │  systemd: entilldisplay.service → supervisor.sh  (STABIL)         │
   │     ├─ kör player-current.sh                                      │
   │     ├─ OTA: hämtar ny player, bash -n-kollar, tar i bruk          │
   │     ├─ rollback: kraschar ny version → hoppa till senaste "good"  │
   │     └─ heartbeat → .52 (syns i vakt-panelen)                      │
   │                                                                   │
   │  player-current.sh  (UPPDATERBAR)                                 │
   │     ├─ pollar media (conditional GET → 304 om oförändrad)         │
   │     ├─ visar via mpv --vo=drm  (bild: still, .mp4: loop+hwdec)    │
   │     └─ tillämpar WiFi-lista via nmcli (failsafe, se nedan)        │
   └───────────────────────────────────────────────────────────────────┘
```

### Två lager: supervisor + player

- **`supervisor.sh`** ändras nästan aldrig och är skyddsnätet. Den kör player:n,
  hämtar nya player-versioner (OTA), `bash -n`-syntaxkollar dem *före* de tas i bruk,
  och **rullar tillbaka** till senast kända fungerande version om en ny kraschar
  upprepat. En version stämplas `good` först efter stabil drift (t.ex. 5 min).
- **`player-current.sh`** är den fria, uppdaterbara logiken. Symlänk `player-current.sh`
  → `player-<version>.sh`; de N senaste versionerna sparas för rollback.

### Bandbredd (mobildata)

Skärmen pollar ofta (default 60 s) men skickar `If-Modified-Since`/ETag. Caddy svarar
**`304 Not Modified` (~200 byte)** så länge menyn är oförändrad. Själva bilden (~2–3 MB)
laddas bara ner när menyn **faktiskt byts**. Mätt:

| Situation | Nedladdat |
|-----------|-----------|
| Oförändrad meny (304) | **0 byte** (bara ~200 B headers) |
| Meny byts (200) | ~2,76 MB (en gång) |

≈ 5–10 MB/månad för pollandet + bildbyten (samma storleksordning som pisignage, ofta mindre).
Menybilder kan sänkas till JPG/1080p för att spara mer.

## Nätverk & säkerhet

- Alla skärmar i **samma tailnet** (gratisplanen rymmer 100 enheter; vi ligger på ~7).
  Inget separat konto — det skulle ställa skärmarna utom räckhåll för .52.
- Skärmarna taggas **`tag:signage`** via en återanvändbar **auth key** → maskin-enheter
  (ingen nyckel-utgång, inget manuellt godkännande per skärm).
- **ACL** isolerar dem: `tag:signage` når bara .52:s config/heartbeat-portar; admin (du)
  når `tag:signage` via SSH. Skärmarna kan inte snoka i resten av nätet.
- **SSH aldrig exponerat publikt** — bara nåbart inifrån tailnet. Så du felsöker en skärm
  från soffan (`ssh eriks@skarm1.tailf0de83.ts.net`) oavsett var den sitter, utan öppen port.

### ACL-tillägg (exempel)

```jsonc
// i tailnet-policyn
"tagOwners": { "tag:signage": ["autogroup:admin"] },
"acls": [
  // skärmar → .52 config/heartbeat
  { "action": "accept", "src": ["tag:signage"], "dst": ["100.93.153.23:443,8790"] },
  // admin → SSH in till skärmarna
  { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:signage:22"] }
]
```

## WiFi — ändra på distans + failsafe

Via `nmcli` (NetworkManager, standard på Pi OS Bookworm+). Regeln:

> **Lägg till nytt nät → verifiera internet inom X sek → först då ev. nedprioritera det
> gamla. Ett fungerande nät raderas ALDRIG.**

- Flera sparade nät med `autoconnect-priority` → NetworkManager failar automatiskt över
  till bästa tillgängliga vid boot/tapp. Lägg gärna in en **mobil-hotspot som backup**.
- Ny WiFi-config kommer via kontroll-kanalen (Tailscale). Playern applicerar den med
  verifiering; misslyckas det nya nätet, behålls det gamla och skärmen förblir nåbar.
- Moment 22: om skärmen tappar **all** internet når ingen fjärrlösning fram (gäller alla).
  Därför är "behåll alltid ett fungerande nät + backup-hotspot" kärnan i failsafe:n.

### Ethernet — alltid nät (räddningslina)

En inkopplad kabel ska alltid ge internet, oberoende av WiFi-krångel. NetworkManager gör
det nästan automatiskt (default "Wired connection" med autoconnect), men vi sätter det
explicit i bootstrap/image så det är garanterat och prioriterat:

```bash
nmcli con add type ethernet ifname eth0 con-name eth-fallback autoconnect yes
nmcli con mod eth-fallback connection.autoconnect-priority 100   # högre än allt WiFi
```

Så: WiFi trasslar → koppla in kabel → burken online → Tailscale når ut → du SSH:ar in och rättar.
Det gör att en burk aldrig behöver skruvas ner så länge man kommer åt en nätverksport.

## Video

`mpv` är en videospelare — samma `--vo=drm` visar både stillbild och film.
Playern väljer flaggor efter filändelse: bild → `--image-display-duration=inf`,
`.mp4`/video → `--loop-file=inf --hwdec=auto` (hårdvaruavkodning på 3B/4/5).
1080p H.264 går bra även på 3B; 4K är tungt på 3B (sikta 1080p där).

## RPi 3B / 4 / 5

På Raspberry Pi OS **Bookworm+** använder alla tre KMS/DRM + NetworkManager → mpv/drm
och nmcli fungerar identiskt. **Villkor:** kör samma OS-generation på alla, annars spretar det.

## Sätta upp en ny skärm

Målet är att du bara gör den *minimala* manuella biten; resten körs från Macen över tailnet.

1. **Flasha Raspberry Pi OS Lite** (64-bit, Bookworm+) — i Raspberry Pi Imager: sätt hostname
   (`skarm1`), lägg in din SSH-nyckel, ev. WiFi. Sätt i kortet, boota.
2. **Aktivera Tailscale** på burken (den enda manuella biten):
   ```bash
   sudo tailscale up --advertise-tags=tag:signage
   ```
   Godkänn i tailnet-admin. Nu är burken nåbar över tailnet.
3. **Provisionera från Macen** — kör (eller be Claude köra):
   ```bash
   ./provision.sh skarm1.tailf0de83.ts.net vagg1
   ```
   Det SSH:ar in och kör `bootstrap.sh`, som installerar `mpv`/`curl`/`network-manager`,
   sätter **ethernet-fallback** (kabel = alltid nät), lägger `player.sh` + `entilldisplay.service`
   och kör `systemctl enable --now`.
4. Klart. Skärmen visar sin meny och är nåbar via SSH över tailnet för all framtida fjärrfix.

> `bootstrap.sh` är idempotent — kan köras om när som helst (t.ex. för att byta `--media-base`
> eller `--poll`). Den kan också köras lokalt på burken om du hellre vill.

## Egen distribution (prepp:ad image)

Målet är **"flasha → boot → funkar"** utan handpåläggning. Två nivåer:

**Steg 1 — bootstrap (finns snart):** Pi OS Lite + en bootstrap-rad (ovan). Snabbt att
komma igång, kräver ett kommando per burk.

**Steg 2 — egen image (målet):** en färdig `entilldisplay-v<X>.img` som bara flashas.
Byggs med **[`sdm`](https://github.com/gitbls/sdm)** ovanpå officiell Pi OS Lite (sdm är
byggt just för att baka in paket + skript + first-boot-logik i en Pi-image utan att sätta
upp hela `pi-gen`). Imagen innehåller:

- Förinstallerat: `mpv`, `curl`, `network-manager`, `tailscale`.
- `supervisor.sh` + `player.sh` + `entilldisplay.service` (enabled).
- Ethernet-fallback-anslutningen (kabel = alltid nät).
- En **first-boot-hook** som per burk: sätter hostname, joinar tailnet med `tag:signage`
  (auth key bakad in eller angiven i Imager), och drar igång tjänsten.

Bygg-nod: en Linux/ARM-maskin med `sdm` (helst en Pi för native ARM, annars x86 +
`qemu-user-static`). Resultat: en versionerad image i git/release som klonar en ny skärm
på minuter. Unika värden (hostname, tailscale-identitet) genereras vid first boot, inte
bakade i imagen — så samma image kan flashas på hur många kort som helst.

## Server-sida (.52 / .56)

- `https://sundbrokrog.se/skarm/<namn>.png|mp4` — media (publikt, Caddy sätter ETag).
  .52:s scheduler skriver rätt bild dit (samma `decide()` som vägg5).
- `<tailnet>/skarm/<namn>.json` — privat config (media-URL, WiFi-lista, poll-intervall,
  önskad player-version). Hämtas över Tailscale.
- `<tailnet>/skarm/player.sh` — senaste player-version (OTA-källa).
- Heartbeat-endpoint på .52 — skärmar rapporterar version/IP/senast-sedd → vakt-panelen.

## Status & TODO

- [x] `player.sh` — poll + conditional GET (304) + mpv/drm-visning (bild), video-stöd.
- [x] Server-endpoint på .56 med ETag; 304-beteende verifierat.
- [x] Pilot installerad på .48 (`entilldisplay.service`, ej auto-enabled).
- [x] `bootstrap.sh` — installerar mpv/curl/network-manager, player + systemd, tailscale.
- [x] `provision.sh` — kör bootstrap på en ny skärm från Macen över tailnet.
- [x] Ethernet-fallback-anslutning (kabel = alltid nät) i bootstrap.
- [x] `supervisor.sh` — OTA (conditional GET + `bash -n`) + rollback + good-stämpling.
- [ ] WiFi-funktioner i player (`nmcli`, failsafe, verifiering) + privat config-poll över Tailscale.
- [ ] Heartbeat → .52 + koppling till vakt-panelen.
- [ ] Egen image via `sdm` — flasha-och-kör, first-boot-hook.
- [ ] Privat config-poll över Tailscale (`.json` per skärm).
- [ ] Heartbeat → .52 + koppling till vakt-panelen (Pi Watchguard).
- [ ] Tailscale `tag:signage` + ACL + återanvändbar auth key.
- [ ] Byt .48-piloten till en riktig 3B/4 + rulla ut på restaurangens skärmar; säg upp pisignage.

## Turnkey-flöde (image utan tangentbord) — `prepare-card.sh`

Mål: flasha ett kort → sätt i Pi → den bootar, joinar tailnet och visar sin kanal, **utan
tangentbord**. En gemensam bas; kanal + värdnamn sätts per kort (INTE en image per skärm).

1. **Pi Imager v2 → OS-anpassning** (kugghjulet), innan flash:
   - Värdnamn: `krog-dorr`, `krog-vagg5`, …
   - SSH: *tillåt endast publik nyckel* → klistra Macens nyckel
   - WiFi: `Tele2Internet_1CE0A` (lösen i `.52:~/.config/entill/sundbrokrog-wifi.conf`)
   - Användarnamn + lösen ← **tar bort första-boot-prompten**
   - Land/tangentbord: SE
2. `./prepare-card.sh <kanal>` på Macen medan kortet sitter i (`dorr` | `vagg1`…`vagg5`).
   Myntar en **färsk** tailscale-authkey via `.52` (över tailnet), bakar in kanal + authkey +
   `firstboot.sh` på bootfs och injicerar en network-online oneshot i Imagers `firstrun.sh`.
3. Mata ut → sätt i Pi → slå på. `firstboot.sh` joinar tailnet + kör `bootstrap.sh` och
   raderar authkey:en från kortet. Felsök: `ssh eriks@<värdnamn>` → `sudo cat /var/log/entilldisplay-firstboot.log`.

> **Vid kort-tillverkning är vi INTE på lokalt nät** → allt mot `.52` går via **Tailscale**
> (Macens tailnet måste vara uppe).

### ⚠️ Järnkoll: tailscale-behörighet utgår
Authkeys och PAT:en (`~/.config/entill/tailscale-api-key`) **utgår ~2026-10-08**. `prepare-card.sh`
myntar färsk nyckel per kort, men **mynt-behörigheten (PAT) utgår också**. Permanent fix: skapa en
**OAuth-klient** (utgår aldrig) i Tailscale-adminen (scope Auth Keys=write, tag:signage) och lägg
`client_id`/`client_secret` i `.52:~/.config/entill/tailscale-oauth` (två rader). `mint-authkey.sh`
väljer då den automatiskt — inga datum att bevaka mer.
