# MoneyMoney Extensions (US-Banken)

Inoffizielle [MoneyMoney](https://moneymoney.app)-Extensions für US-Banken ohne Lua-Login (RSA, Bot-Schutz).

## Extensions

| Datei | Bank | Modus |
|-------|------|-------|
| `extensions/Bank of America.lua` | Bank of America | Cookie-Import |
| `extensions/Fidelity.lua` | Fidelity | Cookie-Import |
| `extensions/Presidential Bank.lua` | Presidential Bank | Cookie-Import |
| `extensions/Fidelity NetBenefits.lua` | Fidelity NetBenefits | Login (experimentell) |

## Installation

1. `.lua` aus `extensions/` nach  
   `~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/`
2. MoneyMoney: Signaturprüfung für Extensions deaktivieren, neu starten.

## Cookie-Import

Passwort in MoneyMoney: `COOKIE:name=value;name2=value2`

Session-Cookies sind oft **HttpOnly** — nicht per `document.cookie` lesbar.

### Userscript (Chrome, Firefox, Edge)

Nur **[Tampermonkey](https://www.tampermonkey.net/)** mit `GM.cookie`. Violentmonkey/Greasemonkey reichen nicht.

| Browser | HttpOnly | Erweiterung |
|---------|----------|-------------|
| Chrome | Ja | [Tampermonkey](https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo) |
| Edge | Ja | [Tampermonkey](https://microsoftedge.microsoft.com/addons/detail/tampermonkey/iikmkjmpaadaobahmlepeloendndfphd) |
| Firefox | Ja | [Tampermonkey](https://addons.mozilla.org/firefox/addon/tampermonkey/) |
| Safari | Nein | [Tampermonkey](https://apps.apple.com/app/tampermonkey/id1482490089) — HttpOnly blockiert ([#2252](https://github.com/Tampermonkey/tampermonkey/issues/2252)) |

Tampermonkey: **Erweitert → Sicherheit → Cookie-Zugriff: Alle**.

1. `scripts/moneymoney-cookie-exporter.user.js` installieren
2. Einloggen, passende Seite öffnen:
   - BoA: `secure.bankofamerica.com` (Kontoübersicht)
   - Fidelity: `digital.fidelity.com`
   - Presidential: `www.presidentialpcbanking.com`
3. **MM** (Alt+C) → Cookies kopieren → als Passwort einfügen

### Safari und Fallback

| Methode | Browser |
|---------|---------|
| HAR + `scripts/extract-*-cookies.py` | alle |
| [Get cookies.txt LOCALLY](https://github.com/kairi003/Get-cookies.txt-LOCALLY) | Chrome, Firefox |
| [crul](https://github.com/KieranHunt/crul) | Chrome, Firefox, Safari |
| DevTools → Network → Cookie-Header | alle |

HAR:

```bash
python3 scripts/extract-boa-cookies.py export.har
python3 scripts/extract-fidelity-cookies.py export.har
python3 scripts/extract-presidential-cookies.py export.har
```

crul (Safari):

```bash
npx --yes @kieranhunt/crul --url https://secure.bankofamerica.com --browsers safari
```

BoA manuell: Network → `account-details.go` → Request Header **Cookie**.

Cookies nach Login zeitnah exportieren. Presidential: MFA in MoneyMoney liefert oft kein `rftoken` — Cookie-Import nötig.

## Hintergrund

MoneyMoney-Lua: kein JavaScript, keine externen Prozesse, kein Session-Import. Workaround: `COOKIE:` im Passwortfeld.

## Lizenz

MIT
