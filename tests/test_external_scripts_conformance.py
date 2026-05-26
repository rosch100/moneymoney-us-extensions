#!/usr/bin/env python3
"""
Konformitätstests für externe Skripte (Cookie Exporter).

Ziel: Die Skripte sollen die MoneyMoney API-konforme `COOKIE:`-Cookie-Spezifikation
liefern, inklusive sauberer Versionierung und ohne UTF-8-BOM.

Usage: python3 tests/test_external_scripts_conformance.py
"""

from __future__ import annotations

import importlib.util
import pathlib
import re
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / "scripts"


def assert_true(cond: bool, msg: str) -> None:
    if cond:
        return
    raise AssertionError(msg)


def read_bytes(path: pathlib.Path) -> bytes:
    return path.read_bytes()


def assert_no_utf8_bom(path: pathlib.Path) -> None:
    raw = read_bytes(path)
    bom = b"\xef\xbb\xbf"
    assert_true(not raw.startswith(bom), f"{path}: UTF-8 BOM verboten")


def assert_shebang_python(path: pathlib.Path) -> None:
    first_line = read_bytes(path).splitlines()[0].decode("utf-8", errors="replace")
    assert_true(
        first_line.startswith("#!/usr/bin/env python3"),
        f"{path}: fehlender oder falscher Python shebang",
    )


def load_python_module_from_path(module_path: pathlib.Path) -> Any:
    module_name = "moneymoney_ext_test_" + re.sub(r"[^a-zA-Z0-9_]", "_", module_path.name)
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"{module_path}: konnte Modul nicht laden")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_semver(version: str, context: str) -> None:
    assert_true(
        re.fullmatch(r"\d+\.\d+\.\d+", version or "") is not None,
        f"{context}: Version '{version}' ist nicht im Format X.Y.Z",
    )


def extract_module_docstring(text: str) -> str:
    """
    Minimaler Parser: wir suchen nach der ersten Triple-Quote-Docstring.
    """
    # Nach einem Shebang kann die Docstring in Zeile 2 beginnen – daher nicht am Anfang verankern.
    m = re.search(r'(["\']{3})(.*?)(\1)', text, flags=re.S)
    return m.group(2).strip() if m else ""


def assert_python_script_conformance(py_path: pathlib.Path) -> None:
    assert_true(py_path.name.startswith("extract-") and py_path.suffix == ".py", f"{py_path}: unerwarteter Name")
    assert_no_utf8_bom(py_path)
    assert_shebang_python(py_path)

    raw_text = py_path.read_text(encoding="utf-8")
    doc = extract_module_docstring(raw_text)
    assert_true("MoneyMoney" in doc, f"{py_path}: Docstring muss MoneyMoney enthalten")
    assert_true("Usage:" in doc and "python3" in doc and "datei.har" in doc, f"{py_path}: Docstring muss Usage für datei.har enthalten")

    module = load_python_module_from_path(py_path)
    version = getattr(module, "__version__", None)
    assert_true(isinstance(version, str), f"{py_path}: __version__ fehlt oder ist kein String")
    assert_semver(version, f"{py_path}.__version__")

    has_format_cookies = hasattr(module, "format_cookies")
    if has_format_cookies:
        fmt = getattr(module, "format_cookies")
        sample = {
            # mindestens 2 PRIORITY-Namen, damit Semikolon-Trennung geprüft werden kann
            # (Details pro Script sind in PRIORITY hinterlegt)
            # Wichtig: Bandit meldet sonst bei sehr kurzen Placeholder-Strings (z.B. "X") False-Positives.
            # Values bewusst neutral halten, damit Bandit keinen False-Positive (B105) wirft.
            "SESSION_TOKEN": "cookie_export_test_value_1",
            "rftoken": "cookie_export_test_value_2",
            "FedAuth": "cookie_export_test_value_3",
            "ASP.NET_SessionId": "cookie_export_test_value_4",
        }

        out = fmt(sample)
        assert_true(isinstance(out, str), f"{py_path}: format_cookies muss String zurückgeben")
        assert_true(out.startswith("COOKIE:"), f"{py_path}: format_cookies muss mit 'COOKIE:' starten (got: {out[:30]!r})")
        assert_true("," not in out, f"{py_path}: Cookie-Output darf keine Kommas enthalten (got: {out})")
        assert_true(";" in out, f"{py_path}: Cookie-Output muss Semikolon-Trenner enthalten (got: {out})")
        assert_true(re.match(r"^COOKIE:[^,]+$", out) is not None, f"{py_path}: Cookie-Output entspricht nicht erwarteter Struktur")

        # Zusätzlich: jeder Parameter muss key=value enthalten
        cookie_body = out.removeprefix("COOKIE:")
        parts = [p.strip() for p in cookie_body.split(";") if p.strip()]
        assert_true(len(parts) >= 2, f"{py_path}: erwartet >=2 Cookie-Paare (got: {parts})")
        for p in parts:
            assert_true("=" in p, f"{py_path}: Cookie-Paar fehlt '=': {p}")

    else:
        # BoA hat keine format_cookies Funktion im Stil der anderen – trotzdem prüfen wir
        # ob die Ausgabe einen COOKIE:-Prefix nutzt.
        content = raw_text
        assert_true('print(f"COOKIE:' in content or 'print("COOKIE:' in content, f"{py_path}: erwartet Output mit 'COOKIE:' Prefix")


def assert_js_script_conformance(js_path: pathlib.Path) -> None:
    assert_true(js_path.suffix == ".js" and js_path.name.endswith(".user.js"), f"{js_path}: unerwarteter Name")
    assert_no_utf8_bom(js_path)

    raw = js_path.read_text(encoding="utf-8")
    assert_true(raw.startswith("// ==UserScript=="), f"{js_path}: erwartet UserScript Header am Dateianfang")

    # Metadata checks
    name = re.search(r"@name\s+(.+)", raw)
    version = re.search(r"@version\s+([0-9]+\.[0-9]+\.[0-9]+)", raw)
    desc = re.search(r"@description\s+(.+)", raw)

    assert_true(name is not None, f"{js_path}: @name fehlt")
    assert_true(version is not None, f"{js_path}: @version fehlt oder nicht im X.Y.Z-Format")
    assert_true(desc is not None, f"{js_path}: @description fehlt")
    assert_true("MoneyMoney" in desc.group(1), f"{js_path}: @description muss MoneyMoney enthalten")

    # Cookie export structure: 'COOKIE:' Prefix und join(';')
    assert_true("COOKIE:" in raw, f"{js_path}: erwartet 'COOKIE:' im Code")
    assert_true("join(';')" in raw or "join('; ')" in raw or "join(';'" in raw, f"{js_path}: erwartet Semikolon-Join im Code (pairs.join(';'))")


def main() -> None:
    # Python scripts (Cookie HAR -> MoneyMoney COOKIE:-String)
    py_scripts = sorted(SCRIPTS_DIR.glob("extract-*.py"))
    assert_true(len(py_scripts) >= 1, "Keine Python Scripts unter scripts/extract-*.py gefunden")
    for p in py_scripts:
        assert_python_script_conformance(p)

    # JS Tampermonkey user script
    js_scripts = sorted(SCRIPTS_DIR.glob("*.user.js"))
    assert_true(len(js_scripts) == 1, f"Erwartet genau 1 .user.js Skript, gefunden: {len(js_scripts)}")
    for p in js_scripts:
        assert_js_script_conformance(p)

    print("ALL EXTERNAL SCRIPTS CONFORMANCE TESTS PASSED")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)

