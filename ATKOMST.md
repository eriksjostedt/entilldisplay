# ÅTKOMST — så loggar du in på skärmarna

> **Att kunna nå skärmarna via SSH är en av de viktigaste delarna i entilldisplay.**
> Burkarna sitter i restaurangen, inte där du kommer åt dem. Går inloggningen inte,
> går det inte att felsöka när något brinner.
>
> **Skärmarna är ETT enhetligt system, inte enskilda datorer.** Alla burkar loggas in
> på exakt samma sätt. Avviker en burk är det ett fel att åtgärda — inte en egenhet
> att dokumentera.

## Så loggar du in

```bash
ssh eriks@krog-vagg5      # eller krog-vagg1, krog-dorr
ssh root@krog-dorr        # reservväg, samma på alla
```

**Det är hela sanningen.** `eriks` är den primära vägen (har sudo utan lösenord),
`root` är reserven. Båda fungerar på **alla** burkar. Inget annat användarnamn ska behövas.

| | |
|---|---|
| **Användare** | `eriks` (primär, sudo) och `root` (reserv) — identiskt på varje burk |
| **Mekanism** | Tailscale-SSH (`tailscale set --ssh`) — tar över port 22 för tailnet-trafik |
| **Vem släpps in** | Tailnet-ACL:n avgör. Nycklarna i `/home/eriks/.ssh/authorized_keys` (Eriks Mac + .52) |
| **Lösenord** | Fungerar **aldrig** — burkarna kör `PasswordAuthentication no`. Lösenordet från Imager är för konsol/tangentbord på plats |
| **Nätväg** | Bara tailnet. Burkarna sitter i restaurangens nät, servrarna på lantstället — inget LAN emellan |

## Fallgropar (verkliga, kostade tid 2026-08-10)

1. **Gissa inte användarnamn.** Burkarna hade från början en användare som hette som noden
   (`krog-dorr@krog-dorr`) — den finns kvar som *tjänsteanvändare* för playern, men är inte
   inloggningsvägen. Använd `eriks`.
2. **`eriks` nekades förr med "tailnet policy does not permit".** Det var inte ACL:n som sa nej —
   användaren fanns inte på burken. ACL:n tillåter `eriks`; användaren måste bara skapas.
3. **`pi` finns inte** och kommer aldrig att fungera.
4. **En burk kan vara avstängd** (nattavstängning) — det är inte ett åtkomstfel. Timeout = burken
   sover; "Permission denied" = du är utelåst. Vakten nedan skiljer på dem.

## Övervakning — `bin/skarm-access.sh`

Testar varje inloggningsväg på varje burk och larmar via vakt-ntfy när en slutar fungera,
**så en trasig väg upptäcks innan du behöver den**. Kör dagligen via cron på .52.

```bash
./bin/skarm-access.sh            # tyst när allt är grönt, larmar vid fel
./bin/skarm-access.sh --alltid   # kvitto även när allt fungerar
```

Larmnivåer: *reservvägen nekar* (en väg kvar — åtgärda i lugn och ro) och
*UTELÅST* (ingen väg in — akut). Avstängda burkar rapporteras men larmar inte.

## Ny burk — så blir den standard

`bootstrap.sh` sätter upp det automatiskt (Tailscale-SSH + `eriks` med nycklar). Verifiera
alltid efteråt, och lägg till burken i `NODER`-listan i `bin/skarm-access.sh`:

```bash
ssh eriks@<ny-nod> 'whoami; sudo -n true && echo "sudo OK"; timedatectl | grep "Time zone"'
```

Tidszonen ska vara **Europe/Stockholm** med NTP-synk — se `TIDSZON.md` i sundbrokrog-repot.

## Om du någon gång blir utelåst från alla vägar

Burkarnas supervisor hämtar `bin/player.sh` från GitHub `main` var 5:e minut och kör den
(med syntaxkontroll och rollback). En tillfällig rad där kan lägga tillbaka en nyckel på
samtliga burkar utan fysisk åtkomst. Ta bort raden direkt efteråt.

> Samma mekanism betyder att den som kan pusha till `entilldisplay`-repot kör kod på alla
> skärmar. Värt att veta.

**Vid ändring av tailscale-inställningar på en burk:** armera alltid ett skyddsnät först,
annars kan du låsa ut dig (tailnet är enda vägen in):

```bash
ssh eriks@<nod> 'rm -f /tmp/ssh-bekraftad; nohup sh -c "sleep 600; \
  [ -f /tmp/ssh-bekraftad ] || sudo -n tailscale set --ssh=false" >/dev/null 2>&1 &'
# gör ändringen, verifiera att du kommer in igen, sedan:
ssh eriks@<nod> 'touch /tmp/ssh-bekraftad'
```
