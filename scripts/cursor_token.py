"""Lists Cursor's local login token candidates (read-only) for the widget.

Prints one JSON line: {"candidates": [{"key": ..., "b64": ...}], "keys": [...]}
- candidates: ONLY cursorAuth/accessToken and a secret-storage entry named cursorAuth
  (encrypted values are decrypted by the widget with Cursor's own key for this user).
  Other extensions' secrets (MCP, git, ...) are never read or sent anywhere.
- keys: cursorAuth key NAMES only, for diagnostics.
The widget uses a token only to ask Cursor's own server for this account's usage.
"""
import base64
import json
import pathlib
import sqlite3
import sys

db = pathlib.Path(sys.argv[1]).resolve().as_uri() + "?mode=ro"
con = sqlite3.connect(db, uri=True, timeout=5)
try:
    rows = con.execute(
        "SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth/%' "
        "OR (key LIKE 'secret://%' AND lower(key) LIKE '%cursorauth%')"
    ).fetchall()
finally:
    con.close()


def raw_bytes(value):
    raw = value if isinstance(value, bytes) else str(value or "").encode("utf-8")
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict) and isinstance(obj.get("data"), list):  # {"type":"Buffer","data":[...]}
            return bytes(obj["data"])
        if isinstance(obj, str):
            return obj.encode("utf-8")
    except Exception:
        pass
    return raw


def wanted(key):
    # ONLY Cursor's own login token. Other extensions' secrets (MCP, git, etc.) are never read.
    k = key.lower()
    if "refresh" in k:
        return False
    return key == "cursorAuth/accessToken" or (key.startswith("secret://") and "cursorauth" in k)


cands = []
# secret-store entries first: they hold the live token in newer Cursor builds
for key, value in sorted(rows, key=lambda r: (not r[0].startswith("secret://"), r[0])):
    if value and wanted(key):
        cands.append({"key": key, "b64": base64.b64encode(raw_bytes(value)).decode("ascii")})

# The server Cursor is signed in to (a URL, not a secret); tokens are only valid there.
backend = None
for key, value in rows:
    if key == "cursorAuth/storedServerBackendUrl" and value:
        v = (value.decode("utf-8", "ignore") if isinstance(value, bytes) else str(value)).strip().strip('"')
        if v.startswith("https://"):
            backend = v.rstrip("/")

print(json.dumps({"candidates": cands, "backend": backend, "keys": sorted({k for k, _ in rows})[:20]}))
