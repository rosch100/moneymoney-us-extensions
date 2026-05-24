#!/usr/bin/env python3
"""Presidential-Bank-Cookies aus HAR für MoneyMoney. Usage: python3 extract-presidential-cookies.py datei.har"""

__version__ = "1.0.0"

import json
import subprocess
import sys


PRIORITY = [
    "SESSION_TOKEN", "SESSION", "FMISSESSIONID",
    "tkt", "at", "ag", "rftoken", "USPIBID",
    "__cf_bm", "_cfuvid", "cf_clearance",
]


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


def collect_cookies(har_path):
    with open(har_path, encoding="utf-8") as f:
        entries = json.load(f)["log"]["entries"]

    cookies = {}
    for entry in entries:
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
    for name, value in cookies.items():
        if name not in used:
            ordered.append(f"{name}={value}")
    return "COOKIE:" + ";".join(ordered)


def main(har_path):
    cookies = collect_cookies(har_path)
    if not cookies:
        print("Keine Cookies in der HAR-Datei.", file=sys.stderr)
        sys.exit(1)

    if "SESSION_TOKEN" not in cookies:
        print("Hinweis: SESSION_TOKEN fehlt — HAR nach Login aufnehmen.", file=sys.stderr)

    result = format_cookies(cookies)
    print(result)

    try:
        subprocess.run(["pbcopy"], input=result, text=True, check=True)
        print("In Zwischenablage kopiert.", file=sys.stderr)
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <har>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
