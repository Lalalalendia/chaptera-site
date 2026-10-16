#!/usr/bin/env python3
"""Nonbillable, content-free Gemini models.list check on the actual VPS.

The protected credential is read from stdin, never printed or written to disk.
Only numeric HTTP status and public model IDs/support flags are emitted.
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

key = sys.stdin.readline(4096).rstrip("\n")
if not key or "\r" in key or len(key) > 1024:
    print("models_list_error=invalid_or_absent_key", file=sys.stderr)
    raise SystemExit(2)

request = urllib.request.Request(
    "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000",
    headers={"x-goog-api-key": key, "Accept": "application/json"},
    method="GET",
)
del key
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        status = response.status
        raw = response.read(2_000_001)
except urllib.error.HTTPError as exc:
    print(f"models_list_http={exc.code}")
    print("models_list_result=DENIED_OR_ERROR")
    raise SystemExit(1)
except (urllib.error.URLError, TimeoutError) as exc:
    print(f"models_list_transport_error={type(exc).__name__}")
    raise SystemExit(1)
if status != 200 or len(raw) > 2_000_000:
    print(f"models_list_http={status}")
    print("models_list_result=UNEXPECTED_RESPONSE")
    raise SystemExit(1)
try:
    payload = json.loads(raw)
    models = payload["models"]
    assert isinstance(models, list)
except (ValueError, KeyError, TypeError, AssertionError):
    print("models_list_result=MALFORMED_RESPONSE")
    raise SystemExit(1)

supported = {
    m.get("name", "").removeprefix("models/")
    for m in models
    if isinstance(m, dict)
    and "generateContent" in m.get("supportedGenerationMethods", [])
    and isinstance(m.get("name"), str)
}
print("models_list_http=200")
print("models_list_result=PASS")
print(f"generation_models_count={len(supported)}")
for name in ("gemini-2.5-flash", "gemini-3.8-flash", "gemini-3.6-flash",
             "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"):
    print(f"model_{name.replace('-', '_')}={'listed_generateContent' if name in supported else 'not_listed_for_generation'}")
for name in sorted(m for m in supported if m.startswith("gemini-") and "flash" in m)[:24]:
    print(f"candidate_flash_model={name}")
print("note=models_list_does_not_prove_generation_entitlement")
print("paid_generate_content_requests=0")
