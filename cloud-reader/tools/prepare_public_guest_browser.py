#!/usr/bin/env python3
"""Adapt a pinned rar2 physical Chromium acceptance to the trusted public origin.

This is test-only: the original upstream script is preserved. Every intentional
change is exact-match and fail-closed, so upstream test evolution requires review.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

PUBLIC_ORIGIN = "https://reader.chaptera.online"


def one(source: str, expected: str, replacement: str, label: str) -> str:
    count = source.count(expected)
    if count != 1:
        raise ValueError(f"{label}: expected exactly one upstream marker, got {count}")
    return source.replace(expected, replacement)


def adapt(source: str) -> str:
    for marker in (
        'const exportTarget = process.argv.includes("--target")',
        '"tools/verify_editable_export_geometry.py"',
        '"tools/verify_temporary_guest_pdf_geometry.py"',
        'page.locator("#temporary-delete").click()',
        'page.locator("#temporary-start").click()',
        'page.waitForEvent("download"',
        'changed_download_geometry_proven:true',
        'same_browser_session_delete_proven:true',
        'v0_go:false',
    ):
        if marker not in source:
            raise ValueError("upstream acceptance no longer proves " + marker)
    source = one(
        source,
        r'/^https:\/\/reader\.chaptera\.test:\d+$/.test(origin)',
        'origin !== "https://reader.chaptera.online"',
        "exact production origin",
    )
    source = one(
        source,
        '  headless: true, args: [\n'
        '    "--no-proxy-server",\n'
        '    "--host-resolver-rules=MAP reader.chaptera.test 127.0.0.1",\n'
        '  ],',
        '  headless: true,',
        "real public resolver and transport",
    )
    source = one(
        source, '  ignoreHTTPSErrors: true,',
        '  ignoreHTTPSErrors: false,',
        "trusted TLS only",
    )
    source = one(
        source, '    tls_caddy:true,rust_server:true,isolated_worker:true,',
        '    tls_public_trusted:true,rust_server:true,isolated_worker:true,',
        "correct physical receipt provenance",
    )
    source = one(
        source, '// Physical guest V0 acceptance: real Chromium -> TLS/Caddy -> Rust -> isolated',
        '// Public FirstVDS acceptance: real Chromium -> trusted TLS/Nginx -> Rust -> isolated',
        "correct trust boundary comment",
    )
    # Failed acceptance may leave a test session live. Best-effort DELETE is
    # cleanup only; it never makes a failed acceptance PASS.
    cleanup = '''} finally {
  try {
    await page.evaluate(async () => {
      const stored = sessionStorage.getItem("chaptera.temporary-edit.v0");
      if (!stored) return;
      const session = JSON.parse(stored);
      if (!/^tempedit:[0-9a-f]{32}$/.test(session.session_id) ||
          !/^[0-9a-f]{64}$/.test(session.access_token)) return;
      const values = crypto.getRandomValues(new Uint8Array(16));
      const csrf = [...values].map(v => v.toString(16).padStart(2, "0")).join("");
      await fetch("/v1/editor/temporary-sessions/" + session.session_id, {
        method: "DELETE", credentials: "omit", cache: "no-store",
        redirect: "error", referrerPolicy: "no-referrer",
        headers: { "x-chaptera-reader-session": session.access_token,
          "x-csrf-token": csrf, "accept": "application/json" },
      });
    });
  } catch { /* original failure remains authoritative; TTL still applies */ }
  await browser.close();
}'''
    source = one(source, '} finally {\n  await browser.close();\n}', cleanup, "failure cleanup")
    if "reader.chaptera.test" in source or "ignoreHTTPSErrors: true" in source:
        raise ValueError("local-only TLS bypass remains in public browser suite")
    if "tls_caddy:true" in source or "host-resolver-rules" in source:
        raise ValueError("local origin or local receipt provenance remains")
    if PUBLIC_ORIGIN not in source:
        raise ValueError("trusted public origin is absent")
    return source


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.upstream.resolve() == args.output.resolve():
        raise SystemExit("upstream test may not be overwritten")
    source = args.upstream.read_text(encoding="utf-8")
    result = adapt(source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(result, encoding="utf-8")
    print("public browser consumer sha256=" + hashlib.sha256(result.encode()).hexdigest())


if __name__ == "__main__":
    main()
