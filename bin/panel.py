#!/usr/bin/env python3
# =====================================================================
# panel.py — burkens egen sida: "vad visas, vad kommer, och låt mig byta"
# =====================================================================
# Erik 2026-08-31: "Jag skulle gärna vilja ha hängslen och livrem. När jag
# besöker webbadressen skulle jag vilja att raspberryn visade upp en webbsida
# med den bild som visas för stunden och den som är schemalagd att visas
# härnäst och när det kommer att bli. Men jag skulle också vilja ha en
# upload-knapp där jag kan ladda upp vad fan som helst."
#
# ⭐ VARFÖR DEN BOR PÅ BURKEN
# Samma doktrin som valj.py: ENHETEN ÄGER FUNKTIONEN. Sidan ska svara även när
# .52 OCH macen är nere — det är då man som mest behöver veta vad skärmen
# visar, och kunna byta det. En panel som hostas på servern vore värdelös
# exakt när den behövs.
#
# Beslutet dupliceras ALDRIG här. Sidan frågar valj.py, som är den enda
# platsen där "vilken bild gäller" avgörs. Två svar på samma fråga blir
# förr eller senare två olika svar.
#
# Nås via tailscale serve → https://krog-<namn>.<tailnet>.ts.net
# Lyssnar därför bara på localhost: inget öppnas mot LAN eller internet.
# =====================================================================
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

NAMN = os.environ.get("SKARM_NAMN", sys.argv[1] if len(sys.argv) > 1 else "vagg5")
STATE = Path(os.environ.get("STATE_DIR", Path.home() / ".entilldisplay"))
VALJ = STATE / "valj.py"
LAGER = STATE / "lager"
OVERRIDE_JSON = STATE / "override.json"
OVERRIDE_PNG = STATE / "override.png"
PORT = int(os.environ.get("PANEL_PORT", "8099"))
MAX_UPP = 40 * 1024 * 1024  # 40 MB räcker för en 4K-PNG med marginal


def kor_valj(*extra):
    """Fråga valj.py. Den är enda sanningen om vad som ska visas."""
    if not VALJ.is_file():
        return None
    try:
        r = subprocess.run([sys.executable, str(VALJ), str(STATE), *extra],
                           capture_output=True, text=True, timeout=20)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def las_override():
    try:
        return json.loads(OVERRIDE_JSON.read_text(encoding="utf-8"))
    except Exception:
        return None


def status():
    nu_fil = kor_valj()
    nasta = kor_valj("--nasta")
    ov = las_override()
    manuell = bool(nu_fil and Path(nu_fil).name == "override.png")

    n_lage = n_bild = n_tid = None
    if nasta and "\t" in nasta:
        bitar = nasta.split("\t")
        if bitar[0] and bitar[0] != "oforandrat":
            n_lage, n_bild, n_tid = (bitar + ["", "", ""])[:3]

    # Kör mpv med rätt fil? Det är skillnaden mellan "borde visas" och "visas".
    syns = False
    try:
        r = subprocess.run(["pgrep", "-a", "mpv"], capture_output=True, text=True, timeout=5)
        syns = bool(nu_fil) and nu_fil in r.stdout
    except Exception:
        pass

    return {
        "skarm": NAMN,
        "nu_fil": nu_fil,
        "nu_namn": Path(nu_fil).name if nu_fil else None,
        "manuell": manuell,
        "override": ov if manuell else None,
        "nasta_lage": n_lage,
        "nasta_bild": n_bild,
        "nasta_tid": n_tid,
        "syns": syns,
        "tid": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "lager": sorted(p.name for p in LAGER.glob("*.png")) if LAGER.is_dir() else [],
    }


# ─────────────────────────────────────────────────────────────────────────
# NORMALISERING: vad som än kommer in ska bli en PNG som heter override.png
# ─────────────────────────────────────────────────────────────────────────
# Erik 2026-08-31: "Eftersom jag ofta skulle göra sådana här bilder i iphonen
# så måste bilden få ett nytt namn och filtyp när den laddas upp. Det kan vara
# si och så från telefonen."
#
# Telefonen skickar HEIC eller JPEG, ibland med EXIF-rotation och alltid med
# ett eget filnamn. Filändelsen som följer med är inte att lita på — vi tittar
# på de faktiska bytesen i stället (magiska tal), för ett felaktigt namn får
# aldrig avgöra vad vi tror att filen är.
def sniffa(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data[4:8] == b"ftyp" and data[8:12] in (b"heic", b"heix", b"hevc", b"mif1", b"msf1"):
        return "heic"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    if data.startswith(b"GIF8"):
        return "gif"
    return None


def till_png(data, typ, mal):
    """(ok, beskrivning). Skriver alltid via .ny och byter på plats."""
    tmp = mal.with_suffix(".ny")

    if typ == "png":
        tmp.write_bytes(data)
        os.replace(tmp, mal)
        return True, "PNG"

    # -auto-orient rättar EXIF-rotationen: en bild tagen med telefonen på
    # högkant hamnar annars liggande på skärmen.
    forsok = (
        ["magick", "-", "-auto-orient", "png:-"],
        ["convert", "-", "-auto-orient", "png:-"],
        ["heif-convert", "-q", "90", "/dev/stdin", "/dev/stdout"],
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
         "-frames:v", "1", "-f", "image2", "-vcodec", "png", "pipe:1"],
    )
    for kmd in forsok:
        try:
            r = subprocess.run(kmd, input=data, capture_output=True, timeout=120)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        if r.returncode == 0 and r.stdout.startswith(b"\x89PNG"):
            tmp.write_bytes(r.stdout)
            os.replace(tmp, mal)
            return True, f"{typ.upper()} → PNG via {kmd[0]}"

    # Ingen omvandlare fanns. mpv visar JPEG utmärkt, så hellre rätt bild med
    # fel filformat än ingen bild alls — men säg tydligt ifrån.
    if typ == "jpeg":
        tmp.write_bytes(data)
        os.replace(tmp, mal)
        return True, "JPEG (ingen omvandlare på burken — visas ändå)"
    return False, f"kan inte omvandla {typ} — installera imagemagick på burken"


# ─────────────────────────────────────────────────────────────────────────
# TEXTBILD: skriv i stället för att ladda upp
# ─────────────────────────────────────────────────────────────────────────
# Erik 2026-08-31: "när jag är 50 mil bort och kocken säger att texten är för
# liten, eller vi måste iaf få 10 kr för en burgare, eller att jag har stavat
# hammburgare med två mm."
#
# Att göra om en bild i telefonen för en felstavning är onödigt krångel. Skriv
# texten i stället, så ritar burken bilden. Då är en rättelse tre tryck: texten
# ligger kvar ifylld, man ändrar ett tecken och skickar om.
HUS_BAKGRUND = "#1b6891"
HUS_TEXT = "#fdfaf3"
HUS_UNDER = "#e8d9b0"


def _magick():
    for k in ("magick", "convert"):
        try:
            subprocess.run([k, "-version"], capture_output=True, timeout=10)
            return k
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    return None


def _typsnitt():
    """ImageMagick har inget forvalt typsnitt for caption: - det MASTE anges,
    annars faller anropet med "unable to read font". Vi letar efter en riktig
    fontfil i stallet for ett namn, eftersom namnlistan skiljer sig mellan
    Debian och macOS."""
    kandidater = (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",   # Raspberry Pi OS
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",       # macOS
        "/System/Library/Fonts/Helvetica.ttc",
    )
    for f in kandidater:
        if Path(f).is_file():
            return f
    return None


def gor_textbild(rubrik, underrad, mal):
    """Ritar en 16:9-bild i husets färger. (ok, beskrivning)."""
    k = _magick()
    if not k:
        return False, "imagemagick saknas på burken"
    typsnitt = _typsnitt()
    if not typsnitt:
        return False, "inget typsnitt hittades (installera fonts-dejavu-core)"
    tmp = mal.with_suffix(".ny")
    kmd = [k, "-size", "3840x2160", f"canvas:{HUS_BAKGRUND}"]
    # caption: bryter raderna själv och krymper tills texten får plats, sa
    # en lang mening blir aldrig avklippt.
    kmd += ["(", "-background", "none", "-fill", HUS_TEXT, "-font", typsnitt,
            "-size", "3200x1100", "-gravity", "center", f"caption:{rubrik}", ")",
            "-gravity", "center", "-geometry", "+0-140" if underrad else "+0+0",
            "-composite"]
    if underrad:
        kmd += ["(", "-background", "none", "-fill", HUS_UNDER, "-font", typsnitt,
                "-size", "2900x420", "-gravity", "center", f"caption:{underrad}", ")",
                "-gravity", "center", "-geometry", "+0+560", "-composite"]
    kmd += [f"png:{tmp}"]
    try:
        r = subprocess.run(kmd, capture_output=True, timeout=120)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False, "kunde inte rita bilden"
    if r.returncode != 0 or not tmp.is_file() or tmp.stat().st_size < 100:
        try:
            tmp.unlink()
        except OSError:
            pass
        return False, "kunde inte rita bilden"
    os.replace(tmp, mal)
    return True, "ritad på skärmen"


def dela_multipart(kropp, granslinje):
    delar = {}
    for bit in kropp.split(b"--" + granslinje):
        if b"\r\n\r\n" not in bit:
            continue
        huvud, data = bit.split(b"\r\n\r\n", 1)
        m = re.search(r'name="([^"]+)"', huvud.decode("utf-8", "replace"))
        if not m:
            continue
        if data.endswith(b"\r\n"):
            data = data[:-2]
        delar[m.group(1)] = data
    return delar


def berakna_till(val, nu=None, befintlig=None):
    """Hur länge ska den manuella bilden gälla?

    Erik: "ibland är det bara 'Tills något av systemen säger något annat'.
    Typ 'Tillsvidare'." Det är förstavalet och betyder till=None — då lever
    bilden tills servern eller macen skickar nytt innehåll. Den kan alltså
    aldrig bli glömd och permanent.
    """
    nu = nu or datetime.now()
    # "behall" = byt bara ut bilden, ror inte schemat. Erik 2026-08-31: "jag
    # ska inte behova ta bort den redan publicerade bilden och gora en ny bild
    # med en ny schemalaggning". Rattar man en felstavning ska deadline ligga
    # kvar dar den lag - den flyttar sig inte for att man bytte bild.
    if val == "behall":
        return befintlig
    if val == "tillsvidare":
        return None
    if val == "ikvall":
        return nu.replace(hour=23, minute=59, second=0).strftime("%Y-%m-%d %H:%M")
    if val.startswith("timmar:"):
        try:
            return (nu + timedelta(hours=float(val.split(":", 1)[1]))).strftime("%Y-%m-%d %H:%M")
        except ValueError:
            return None
    if val.startswith("till:"):
        return val.split(":", 1)[1].strip() or None
    return None


SIDA = """<!doctype html><html lang="sv"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%(skarm)s — skärmen</title><style>
*{box-sizing:border-box}
body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
  background:#fdfaf3;color:#2c2a26}
.topp{background:#1b6891;color:#fff;padding:1rem 1.2rem}
.topp h1{margin:0;font-size:1.2rem;letter-spacing:.02em}
.topp .tid{opacity:.8;font-size:.82rem}
.inne{max-width:640px;margin:0 auto;padding:1.2rem}
.kort{background:#fff;border-radius:14px;padding:1rem 1.1rem;margin-bottom:1rem;
  box-shadow:0 2px 10px rgba(0,0,0,.06)}
.kort h2{margin:0 0 .6rem;font-size:.78rem;text-transform:uppercase;
  letter-spacing:.09em;color:#8a8377}
img.forhands{width:100%%;border-radius:10px;display:block;background:#eee;
  aspect-ratio:16/9;object-fit:contain}
.rad{display:flex;justify-content:space-between;gap:.6rem;padding:.42rem 0;
  border-bottom:1px solid #f0ece2}
.rad:last-child{border-bottom:none}
.rad b{font-weight:600}
.mrk{color:#6b6459}
.banner{background:#fbf5e8;border-left:4px solid #c98a1e;border-radius:10px;
  padding:.85rem 1rem;margin-bottom:1rem}
.banner b{color:#a8720f}
.gron{color:#3f7d4e;font-weight:600}
.rod{color:#a8322b;font-weight:600}
label{display:block;margin:.7rem 0 .25rem;font-size:.88rem;font-weight:600}
input[type=file],select,input[type=text]{width:100%%;padding:.6rem;
  border:1px solid #ddd6c8;border-radius:8px;background:#fdfaf3;font-size:.95rem}
button{width:100%%;margin-top:.9rem;padding:.75rem;border:none;border-radius:9px;
  background:#1b6891;color:#fff;font-size:1rem;font-weight:600;cursor:pointer}
button:hover{background:#155473}
button.av{background:#a8322b}button.av:hover{background:#8b2822}
.fot{font-size:.78rem;color:#8a8377;text-align:center;padding:0 1rem 2rem}
</style></head><body>
<div class="topp"><h1>%(skarm)s</h1><div class="tid">%(tid)s</div></div>
<div class="inne">
%(banner)s
<div class="kort"><h2>Visas just nu</h2>
  <img class="forhands" src="/nu.png?t=%(cache)s" alt="Det som visas nu">
  <div class="rad"><span class="mrk">Bild</span><b>%(nu_namn)s</b></div>
  <div class="rad"><span class="mrk">På skärmen</span>%(syns)s</div>
</div>
<div class="kort"><h2>Härnäst</h2>%(nasta)s</div>
<div class="kort"><h2>Skriv en text</h2>
  <form method="post" action="/text">
    <label>Text</label>
    <input type="text" name="rubrik" value="%(rubrik)s" required
           placeholder="Ikväll bjuder vi barnen på hamburgare">
    <label>Underrad (valfritt)</label>
    <input type="text" name="underrad" value="%(underrad)s" placeholder="t.ex. 10 kr styck">
    <label>Hur länge?</label>
    <select name="hurlange">%(valt)s</select>
    <button type="submit">%(textknapp)s</button>
  </form>
</div>
<div class="kort"><h2>…eller ladda upp en bild</h2>
  <form method="post" action="/upload" enctype="multipart/form-data">
    <label>Bild (PNG eller JPG, gärna 16:9)</label>
    <input type="file" name="fil" accept="image/png,image/jpeg" required>
    <label>Hur länge?</label>
    <select name="hurlange">%(valt_upp)s</select>
    <label>Vad är det? (syns bara här)</label>
    <input type="text" name="text" placeholder="t.ex. Ikväll bjuder vi barnen på hamburgare">
    <button type="submit">%(uppknapp)s</button>
  </form>
</div>
</div>
<p class="fot">Sidan bor på skärmen själv och svarar även när servern är nere.<br>
Uppladdad bild ersätts automatiskt när nytt innehåll kommer.</p>
</body></html>"""


VAL = (("tillsvidare", "Tillsvidare — tills något av systemen säger annat"),
       ("ikvall", "Resten av kvällen (till 23:59)"),
       ("timmar:2", "2 timmar"), ("timmar:4", "4 timmar"), ("timmar:24", "Ett dygn"))


def val_lista(valt, befintlig_till=None, aktiv=False):
    poster = list(VAL)
    if aktiv:
        nar = befintlig_till or "tills något av systemen säger annat"
        poster.insert(0, ("behall", f"Behåll nuvarande schema ({nar})"))
        valt = "behall"
    return "".join(
        f'<option value="{v}"{" selected" if v == valt else ""}>{t}</option>'
        for v, t in poster)


def _fly(t):
    return (t or "").replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;")


class Panel(BaseHTTPRequestHandler):
    server_version = "entilldisplay-panel"

    def log_message(self, *a):
        pass

    def _svara(self, kod, typ, kropp):
        self.send_response(kod)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(kropp)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(kropp)

    def do_GET(self):
        vag = self.path.split("?")[0]
        if vag == "/api/status":
            return self._svara(200, "application/json; charset=utf-8",
                               json.dumps(status(), ensure_ascii=False).encode())
        if vag == "/nu.png":
            s = status()
            f = Path(s["nu_fil"]) if s["nu_fil"] else None
            if f and f.is_file():
                typ = "image/png" if f.suffix.lower() == ".png" else "image/jpeg"
                return self._svara(200, typ, f.read_bytes())
            return self._svara(404, "text/plain; charset=utf-8", b"ingen bild")
        if vag == "/":
            return self._svara(200, "text/html; charset=utf-8", self._sida())
        return self._svara(404, "text/plain; charset=utf-8", b"finns inte")

    def _sida(self):
        s = status()
        if s["manuell"]:
            ov = s["override"] or {}
            till = ov.get("till") or "tills något av systemen säger annat"
            banner = ('<div class="banner"><b>Manuell bild visas</b><br>'
                      f'{ov.get("text") or "uppladdad bild"}<br>'
                      f'<span class="mrk">Gäller: {till} · {ov.get("format","")}</span>'
                      '<form method="post" action="/avbryt">'
                      '<button class="av" type="submit">Avbryt och återgå till schemat</button>'
                      '</form></div>')
        else:
            banner = ""

        if s["nasta_tid"]:
            nasta = (f'<div class="rad"><span class="mrk">Byter till</span><b>{s["nasta_bild"]}</b></div>'
                     f'<div class="rad"><span class="mrk">Klockan</span><b>{s["nasta_tid"]}</b></div>'
                     f'<div class="rad"><span class="mrk">Läge</span>{s["nasta_lage"]}</div>')
        elif s["manuell"]:
            nasta = ('<div class="rad"><span class="mrk">Schemat är pausat</span>'
                     '<span>medan den manuella bilden gäller</span></div>')
        else:
            nasta = ('<div class="rad"><span class="mrk">Oförändrat</span>'
                     '<span>de närmaste 48 timmarna</span></div>')

        syns = ('<span class="gron">visas ✓</span>' if s["syns"]
                else '<span class="rod">mpv kör den inte</span>')
        return (SIDA % {
            "skarm": s["skarm"], "tid": s["tid"], "banner": banner,
            "nu_namn": s["nu_namn"] or "—", "syns": syns, "nasta": nasta,
            "cache": datetime.now().strftime("%H%M%S"),
            "rubrik": _fly((s["override"] or {}).get("rubrik", "")),
            "underrad": _fly((s["override"] or {}).get("underrad", "")),
            "valt": val_lista((s["override"] or {}).get("hurlange", "tillsvidare"),
                              (s["override"] or {}).get("till"), s["manuell"]),
            "valt_upp": val_lista((s["override"] or {}).get("hurlange", "tillsvidare"),
                                  (s["override"] or {}).get("till"), s["manuell"]),
            "uppknapp": "Byt ut bilden" if s["manuell"] else "Ladda upp och visa nu",
            "textknapp": ("Uppdatera texten" if (s["override"] or {}).get("kalla") == "text"
                          else "Skapa och visa nu"),
        }).encode("utf-8")

    def do_POST(self):
        vag = self.path.split("?")[0]
        if vag == "/avbryt":
            for f in (OVERRIDE_JSON, OVERRIDE_PNG):
                try:
                    f.unlink()
                except OSError:
                    pass
            return self._omdirigera()

        if vag == "/text":
            langd = int(self.headers.get("Content-Length", "0"))
            if langd <= 0 or langd > 20000:
                return self._svara(400, "text/plain; charset=utf-8", b"fel formular")
            from urllib.parse import parse_qs
            f = parse_qs(self.rfile.read(langd).decode("utf-8", "replace"))
            rubrik = (f.get("rubrik", [""])[0]).strip()
            underrad = (f.get("underrad", [""])[0]).strip()
            if not rubrik:
                return self._svara(400, "text/plain; charset=utf-8", b"tom text")
            ok, hur = gor_textbild(rubrik, underrad, OVERRIDE_PNG)
            if not ok:
                return self._svara(500, "text/plain; charset=utf-8", hur.encode())
            val = f.get("hurlange", ["tillsvidare"])[0]
            gammal = las_override() or {}
            if val == "behall":
                val = gammal.get("hurlange", "tillsvidare")
                nytt_till = gammal.get("till")
            else:
                nytt_till = berakna_till(val)
            OVERRIDE_JSON.write_text(json.dumps({
                "skapad": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "till": nytt_till,
                "hurlange": val,
                "kalla": "text",
                "rubrik": rubrik,
                "underrad": underrad,
                "text": rubrik + (f" — {underrad}" if underrad else ""),
                "format": hur,
            }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            return self._omdirigera()

        if vag != "/upload":
            return self._svara(404, "text/plain; charset=utf-8", b"finns inte")

        typ = self.headers.get("Content-Type", "")
        if "boundary=" not in typ:
            return self._svara(400, "text/plain; charset=utf-8", "fel formulär".encode())
        langd = int(self.headers.get("Content-Length", "0"))
        if langd <= 0 or langd > MAX_UPP:
            return self._svara(413, "text/plain; charset=utf-8", "för stor fil".encode())

        granslinje = typ.split("boundary=")[1].strip().strip('"').encode()
        delar = dela_multipart(self.rfile.read(langd), granslinje)
        bild = delar.get("fil")
        if not bild or len(bild) < 100:
            return self._svara(400, "text/plain; charset=utf-8", b"ingen bild")

        typ = sniffa(bild)
        if not typ:
            return self._svara(415, "text/plain; charset=utf-8",
                               "känner inte igen filen som en bild".encode())
        ok, hur = till_png(bild, typ, OVERRIDE_PNG)
        if not ok:
            return self._svara(415, "text/plain; charset=utf-8", hur.encode())

        val = (delar.get("hurlange") or b"tillsvidare").decode("utf-8", "replace")
        text = (delar.get("text") or b"").decode("utf-8", "replace").strip()
        gammal = las_override() or {}
        if val == "behall":
            val = gammal.get("hurlange", "tillsvidare")
            nytt_till = gammal.get("till")
            text = text or gammal.get("text", "")
        else:
            nytt_till = berakna_till(val)
        OVERRIDE_JSON.write_text(json.dumps({
            "skapad": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "till": nytt_till,
            "hurlange": val,
            "text": text or "manuellt uppladdad bild",
            "format": hur,
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return self._omdirigera()

    def _omdirigera(self):
        self.send_response(303)
        self.send_header("Location", "/")
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    # Bara localhost: tailscale serve står för åtkomsten utifrån, så inget
    # öppnas mot LAN eller internet.
    ThreadingHTTPServer(("127.0.0.1", PORT), Panel).serve_forever()
