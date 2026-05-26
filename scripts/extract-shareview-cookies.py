#!/usr/bin/env python3
"""Shareview-Cookies aus HAR für MoneyMoney. Usage: python3 extract-shareview-cookies.py datei.har"""

__version__ = "1.0.0"

import json
import subprocess  # nosec B404
import sys


PRIORITY = [
    "FedAuth",
    "ASP.NET_SessionId",
    "SPStsAuthContext_7PortfolioDefault",
    "WSS_FullScreenMode",
    "locatecc_DefaultPortfolio",
    "IsPrivacyOn",
    "ILiveInUKStatement",
    "IsHtmlElementContentReplacerActive",
]

CRITICAL = ["FedAuth", "ASP.NET_SessionId", "SPStsAuthContext_7PortfolioDefault"]

ALLOWED_HOST_SUFFIXES = ("shareview.co.uk",)


def parse_cookie_header(value):
    cookies = {}
    for pair in value.split(";"):
        pair = pair.strip()
        if "=" in pair:
            name, val = pair.split("=", 1)
            cookies[name.strip()] = val.strip()
    return cookies


def parse_set_cookie(value):
    first = value.split(";")[0].strip()
    if "=" not in first:
        return {}
    name, val = first.split("=", 1)
    return {name.strip(): val.strip()}


def is_shareview_url(url):
    return any(suffix in url for suffix in ALLOWED_HOST_SUFFIXES)


def collect_cookies(har_path):
    with open(har_path, encoding="utf-8") as f:
        entries = json.load(f)["log"]["entries"]

    cookies = {}
    for entry in entries:
        url = entry.get("request", {}).get("url", "")
        if not is_shareview_url(url):
            continue
        for header in entry.get("request", {}).get("headers", []):
            if header.get("name", "").lower() == "cookie":
                cookies.update(parse_cookie_header(header.get("value", "")))
        for header in entry.get("response", {}).get("headers", []):
            if header.get("name", "").lower() == "set-cookie":
                cookies.update(parse_set_cookie(header.get("value", "")))
        for item in entry.get("request", {}).get("cookies", []):
            cookies[item["name"]] = item["value"]
    return cookies


def format_cookies(cookies):
    ordered = []
    used = set()
    for name in PRIORITY:
        if name in cookies:
            ordered.append(f"{name}={cookies[name]}")
            used.add(name)
    for name in sorted(cookies):
        if name not in used:
            ordered.append(f"{name}={cookies[name]}")
    return "COOKIE:" + ";".join(ordered)


def main(har_path):
    cookies = collect_cookies(har_path)
    if not cookies:
        print("Keine Shareview-Cookies in der HAR-Datei gefunden.", file=sys.stderr)
        sys.exit(1)

    missing = [name for name in CRITICAL if name not in cookies]
    if missing:
        print(
            "Warnung: Wichtige Cookies fehlen: " + ", ".join(missing),
            file=sys.stderr,
        )
        print(
            "Bitte HAR nach dem Login (auf der Holdings-Seite) erneut aufnehmen.",
            file=sys.stderr,
        )

    result = format_cookies(cookies)
    print(result)

    try:
        subprocess.run(["pbcopy"], input=result, text=True, check=True)  # nosec B603,B607
        print("In Zwischenablage kopiert.", file=sys.stderr)
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <har>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
