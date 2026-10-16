#!/usr/bin/env python3
"""One live, explicitly billable Gemini call for a pinned chapter; redacted report.

The report does not prove literary quality. The HTML is intended for manual QA.
The caller controls the temporary private output directory.
"""
from __future__ import annotations

import argparse
import asyncio
import httpx
from hashlib import sha1
from html import escape
import json
import os
from pathlib import Path
import re
import resource
import sys
from tempfile import TemporaryDirectory
from time import monotonic

from bs4 import BeautifulSoup

from chaptera_server.provider import GeminiProvider
from chaptera_server.smoke import MeteredProvider
from chaptera_server.storage import JobSpec, QueueStore
from chaptera_server.worker import TranslationWorker

_EXPECTED_BLOB = "db53f9b07821d4a28ba35badb0da362613a39e50"
_CJK = re.compile(r"[\u3400-\u9fff]")


def _read_exact_source(path: Path) -> tuple[str, bytes, int]:
    raw = path.read_bytes()
    if not 3000 <= len(raw) <= 30000:
        raise ValueError("unexpected_source_size")
    blob = sha1(b"blob " + str(len(raw)).encode("ascii") + b"\x00" + raw).hexdigest()
    if blob != _EXPECTED_BLOB:
        raise ValueError("source_blob_hash_mismatch")
    text = raw.decode("utf-8-sig")
    nonempty = [line.strip() for line in text.splitlines() if line.strip()]
    if not 30 <= len(nonempty) <= 500 or len(_CJK.findall(text)) < 1200:
        raise ValueError("source_shape_mismatch")
    html = "<body>" + "".join(f"<p>{escape(line)}</p>" for line in nonempty) + "</body>"
    if len(html) > 90000:
        raise ValueError("html_payload_exceeds_limit")
    return html, raw, len(nonempty)


class _CappedClient:
    """Delegate to httpx while enforcing a provider-side maxOutputTokens cap."""

    def __init__(self, client: httpx.AsyncClient):
        self.client = client

    async def post(self, url: str, *, headers: dict, json: dict):
        payload = dict(json)
        config = dict(payload.get("generationConfig") or {})
        config["maxOutputTokens"] = 16384
        payload["generationConfig"] = config
        return await self.client.post(url, headers=headers, json=payload)


async def _run(html: str, *, key: str) -> tuple[dict, str]:
    if not key:
        raise ValueError("missing_api_key")
    async with httpx.AsyncClient(timeout=160) as client:
        provider = MeteredProvider(GeminiProvider(
            key, "gemini-3.8-flash", client=_CappedClient(client), timeout_seconds=160,
        ), 1)
        with TemporaryDirectory(prefix="chaptera-billable-pilot-") as folder:
            queue = QueueStore(Path(folder) / "chapter-pilot.sqlite3")
            job = queue.create_job("explicit-pilot", JobSpec(
                chapter_id="086",
                source_html=html,
                transport="html_v0",
                max_attempts=1,
            ))
            started = monotonic()
            claimed = await TranslationWorker(queue, provider).run_once()
            saved = queue.get_job(job["id"])
            completed = bool(claimed and saved and saved["status"] == "completed")
            translated = saved["translated_html"] if completed else ""
            visible = BeautifulSoup(translated, "html.parser").get_text(" ", strip=True)
            remaining_cjk = len(_CJK.findall(visible))
            has_russian = bool(re.search(r"[А-Яа-яЁё]", visible))
            report = {
                "schema": "chaptera-full-chapter-live-pilot-v1",
                "source_book": "xianjie-jijian",
                "chapter_number": 86,
                "model": "gemini-3.8-flash",
                "transport": "html_v0",
                "mode": "ONE_EXPLICITLY_AUTHORIZED_LIVE_CALL",
                "provider_requests": provider.requests,
                "provider_successful_responses": provider.responses,
                "job_status": saved["status"] if saved else "missing",
                "structural_qa_passed": completed,
                "russian_character_signal": has_russian,
                "remaining_source_cjk_chars": remaining_cjk,
                "output_visible_chars": len(visible),
                "unit_count": saved["unit_count"] if completed else None,
                "provider_token_usage": provider.usage or None,
                "elapsed_seconds": round(monotonic() - started, 2),
                "peak_rss_mib": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, 1),
                "literary_quality_checked": False,
                "pass_for_manual_review": completed and has_russian,
                "failure_category": provider.failure or (
                    "worker_or_structure_qa" if not completed else None
                ),
            }
            return report, translated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorize-billable", action="store_true")
    parser.add_argument("--chapter", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if not args.authorize_billable or os.environ.get("CHAPTERA_FULL_CHAPTER_ALLOW_BILLABLE") != "YES":
        raise SystemExit("error=explicit_paid_authorization_required")
    try:
        html, raw, line_count = _read_exact_source(args.chapter)
    except (OSError, ValueError, UnicodeError) as exc:
        raise SystemExit(f"error={type(exc).__name__}_invalid_source") from None
    # Read a single API key from authenticated SSH stdin, not CLI args,
    # environment, plaintext files or logs.
    key = sys.stdin.readline().strip()
    if not 20 <= len(key) <= 500 or any(ch.isspace() for ch in key):
        raise SystemExit("error=missing_or_invalid_gemini_key")
    # A one-request model call, no automatic retry or backend services.
    report, translation = asyncio.run(_run(html, key=key))
    key = ""
    report["source_utf8_bytes"] = len(raw)
    report["source_nonempty_lines"] = line_count
    output = args.output_dir
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    if translation:
        rendered = BeautifulSoup(translation, "html.parser").get_text("\n", strip=True)
        (output / "translation-review.txt").write_text(rendered + "\n", encoding="utf-8")
        os.chmod(output / "translation-review.txt", 0o600)
    os.chmod(output / "report.json", 0o600)
    return 0 if report["pass_for_manual_review"] else 1


if __name__ == "__main__":
    sys.exit(main())
