# MoneyMoney Extensions (US-Banken)

Inoffizielle [MoneyMoney](https://moneymoney.app)-Extensions für US-Finanzinstitute, die keinen normalen Login in Lua erlauben.

## Extensions

| Datei | Bank | Modus |
|-------|------|-------|
| `extensions/Bank of America.lua` | Bank of America | Cookie-Import |
| `extensions/Fidelity.lua` | Fidelity Investments | Cookie-Import |
| `extensions/Presidential Bank.lua` | Presidential Bank | Login + MFA oder Cookie-Import |
| `extensions/Fidelity NetBenefits.lua` | Fidelity NetBenefits | Klassischer Login (experimentell) |

## Installation

1. `.lua`-Dateien aus `extensions/` nach:

   `~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/`

   (In MoneyMoney: **Hilfe → Zeige Datenbank im Finder** → Ordner `Extensions`)

2. **Einstellungen → Erweiterungen** → Signaturprüfung deaktivieren (Extensions sind unsigniert).

3. MoneyMoney neu starten.

## Cookie-Import (BoA, Fidelity, Presidential)

Diese Banken verschlüsseln Login-Daten im Browser (RSA/JavaScript) oder blockieren Bot-Traffic. MoneyMoney kann das nicht nachbilden. Workaround: Session-Cookies aus dem Browser übernehmen.

**In MoneyMoney:**

- Benutzername: wie gewohnt
- Passwort: `COOKIE:` + Cookie-String (Semikolon-getrennt)

Beispiel: `COOKIE:SMSESSION=eyJ...;SSOTOKEN=eyJ...`

### Cookies beschaffen

**Variante A — HAR (alle Banken, inkl. HttpOnly)**

1. Im Browser einloggen, Konto/Portfolio öffnen.
2. DevTools → Network → HAR exportieren.
3. Skript ausführen:

   ```bash
   python3 scripts/extract-boa-cookies.py export.har
   python3 scripts/extract-fidelity-cookies.py export.har
   python3 scripts/extract-presidential-cookies.py export.har
   ```

4. Ausgabe als Passwort in MoneyMoney einfügen.

**Variante B — Userscript (alle Cookie-Import-Banken)**

Tampermonkey in Chrome, Firefox oder Safari. Erkennt die Bank automatisch, liest Cookies über `GM.cookie` (inkl. HttpOnly).

1. [Tampermonkey](https://www.tampermonkey.net/) installieren.
2. `scripts/moneymoney-cookie-exporter.user.js` als Userscript anlegen.
3. Bei der Bank einloggen (BoA: Kontoübersicht, Fidelity: Portfolio, Presidential: Dashboard).
4. Button **MM** (Alt+C) → **Cookies kopieren** → als Passwort in MoneyMoney einfügen.

Unterstützt: Bank of America, Fidelity, Presidential Bank.

Ohne `GM.cookie`: HAR-Export (Variante A).

**Variante C — Manuell (BoA)**

DevTools → Network → Request `account-details.go` → Request Headers → **Cookie** (vollständiger Header, nicht nur Application-Tab).

### Hinweise

- Cookies verfallen schnell (Minuten bis Stunden). Direkt nach Login kopieren.
- Bei Fehlern: Protokollfenster in MoneyMoney prüfen (**Fenster → Protokollfenster**).
- Presidential Bank: MFA-Login scheitert oft, weil `rftoken` (HttpOnly) nach MFA nicht an MoneyMoney übergeben wird. Cookie-Import aus HAR ist zuverlässiger.

## Warum der Umweg?

MoneyMoney-Extensions laufen in Lua ohne JavaScript und ohne externe Programme. Folgendes fehlt in der App:

| Fehlende Funktion | Auswirkung |
|-------------------|------------|
| JavaScript-Ausführung | Login-Flows mit clientseitiger Verschlüsselung (BoA, Fidelity) |
| Externe Prozesse (OpenSSL/Python) | RSA-Verschlüsselung vor dem Login |
| HttpOnly-Cookies nach MFA | Presidential Bank: Session nach 2FA unvollständig |
| Offizieller Cookie-/Session-Import | Workaround über Passwortfeld `COOKIE:…` |

Bis MoneyMoney das unterstützt, bleiben Cookie-Import und HAR-Extraktion der praktikable Weg.

## Entwicklung

Lokale Tests (BoA):

```bash
lua test_boa.lua
```

## Lizenz

MIT — siehe Extension-Dateien.

## Haftung

Inoffiziell, ohne Garantie. Nutzung auf eigenes Risiko.
