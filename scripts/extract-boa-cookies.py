#!/usr/bin/env python3
"""BoA-Cookies aus HAR für MoneyMoney. Usage: python3 extract-boa-cookies.py datei.har"""

__version__ = "1.0.0"

import json
import sys


def main(har_file):
    with open(har_file, encoding="utf-8") as f:
        entries = json.load(f).get("log", {}).get("entries", [])

    cookie_header = None
    for entry in reversed(entries):
        url = entry.get("request", {}).get("url", "")
        if "secure.bankofamerica.com" not in url or "account-details.go" not in url:
            continue
        for header in entry.get("request", {}).get("headers", []):
            if header.get("name", "").lower() == "cookie":
                cookie_header = header.get("value", "")
                break
        if cookie_header:
            break

    if not cookie_header:
        print("Kein Cookie-Header für account-details.go in der HAR-Datei.", file=sys.stderr)
        sys.exit(1)

    names = [p.split("=", 1)[0].strip() for p in cookie_header.split(";") if "=" in p]
    missing = [n for n in ("SMSESSION", "SSOTOKEN", "LSESSIONID") if n not in names]

    print(f"COOKIE:{cookie_header}")
    if missing:
        print(f"Hinweis: fehlend: {', '.join(missing)}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <har>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
