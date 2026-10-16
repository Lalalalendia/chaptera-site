#!/usr/bin/env python3
"""Bounded *offline* structural stress test using a real Chinese chapter.

The provider is a local HTTP mock that returns Cyrillic placeholders, NEVER a
literary translation. No API credentials, text, prompts or responses are logged.
"""
from __future__ import annotations

import argparse
import asyncio
from html import escape
import json
from pathlib import Path
import re
import resource
import sys
from tempfile import TemporaryDirectory
from time import monotonic

import httpx
from bs4 import BeautifulSoup

from chaptera_server.provider import GeminiProvider
from chaptera_server.storage import JobSpec, QueueStore
from chaptera_server.worker import TranslationWorker

_CJK = re.compile(r"[\u3400-\u9fff]")
_MAX_SOURCE_BYTES = 30_000
_MAX_PROMPT_CHARS = 200_000
_MAX_MOCK_REQUESTS = 20


def _simulated_cyrillic(source: str) -> str:
    """Preserve structure and character counts; no source-language output."""
    return _CJK.sub("а", source)


async def _exercise(html: str, transport: str) -> dict:
    requests = 0
    prompt_chars_max = 0

    def respond(request: httpx.Request) -> httpx.Response:
        nonlocal requests, prompt_chars_max
        requests += 1
        if requests > _MAX_MOCK_REQUESTS:
            return httpx.Response(429, json={"error": "offline_request_budget"})
        if request.method != "POST" or request.url.host != "generativelanguage.googleapis.com":
            return httpx.Response(400, json={"error": "offline_endpoint_mismatch"})
        prompt = json.loads(request.content)["contents"][0]["parts"][0]["text"]
        prompt_chars_max = max(prompt_chars_max, len(prompt))
        if len(prompt) > _MAX_PROMPT_CHARS:
            return httpx.Response(413, json={"error": "offline_prompt_budget"})
        if "SOURCE ATOMS JSON:\n" in prompt:
            packet = json.loads(prompt.rsplit("SOURCE ATOMS JSON:\n", 1)[1])
            rows = [dict(zip(packet["columns"], row)) for row in packet["rows"]]
            segments = []
            for atom in rows:
                if not segments or atom["render_domain_id"] != segments[-1]["domain"]:
                    segments.append({"domain": atom["render_domain_id"], "covers": [], "translation": ""})
                segments[-1]["covers"].append(atom["atom_id"])
                segments[-1]["translation"] += _simulated_cyrillic(atom["source_text"])
            answer = json.dumps(
                {"segments": [
                    {"covers": segment["covers"], "translation": segment["translation"]}
                    for segment in segments
                ]}, ensure_ascii=False,
            )
        else:
            if "SOURCE HTML:\n" not in prompt:
                return httpx.Response(400, json={"error": "offline_source_missing"})
            answer = _simulated_cyrillic(prompt.rsplit("SOURCE HTML:\n", 1)[1])
        return httpx.Response(200, json={
            "candidates": [{
                "finishReason": "STOP",
                "content": {"parts": [{"text": answer}]},
            }]
        })

    started = monotonic()
    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        provider = GeminiProvider("offline-fixture-only", "gemini-3.8-flash", client=client)
        with TemporaryDirectory(prefix="chaptera-real-chapter-offline-") as directory:
            store = QueueStore(Path(directory) / "jobs.sqlite3")
            job = store.create_job(
                "offline-probe",
                JobSpec("chapter-086", html, transport=transport, max_attempts=1),
            )
            claimed = await TranslationWorker(store, provider).run_once()
            saved = store.get_job(job["id"])
            completed = bool(claimed and saved and saved["status"] == "completed")
            translated = saved["translated_html"] if completed else ""
            rendered = BeautifulSoup(translated, "html.parser").get_text(" ", strip=True)
            safe = (
                completed and len(rendered) >= 1200
                and bool(re.search(r"[А-Яа-яЁё]", rendered))
                and not _CJK.search(rendered)
            )
            return {
                "transport": transport,
                "status": "PASS" if safe else "FAIL",
                "provider_http_mock_requests": requests,
                "prompt_chars_max": prompt_chars_max,
                "unit_count": saved["unit_count"] if completed else 0,
                "result_visible_chars": len(rendered),
                "elapsed_seconds": round(monotonic() - started, 2),
                "peak_rss_mib": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, 1),
            }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chapter", type=Path)
    args = parser.parse_args()
    raw = args.chapter.read_bytes()
    if not 3000 <= len(raw) <= _MAX_SOURCE_BYTES:
        raise SystemExit("error=offline_fixture_size_out_of_bounds")
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise SystemExit("error=offline_fixture_not_utf8") from None
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not 30 <= len(lines) <= 500 or len(_CJK.findall(text)) < 1200:
        raise SystemExit("error=offline_fixture_incomplete")
    html = "<body>" + "".join(f"<p>{escape(line)}</p>" for line in lines) + "</body>"
    if len(html) > 90_000:
        raise SystemExit("error=offline_html_budget_exceeded")
    results = asyncio.run(_run_both(html))
    report = {
        "schema": "chaptera-real-source-offline-v1",
        "fixture": "med-xianjie-jijian-chapter-086",
        "source_utf8_bytes": len(raw),
        "source_nonempty_lines": len(lines),
        "input_html_chars": len(html),
        "mock_response_kind": "CYRILLIC_PLACEHOLDERS_NOT_REAL_TRANSLATION",
        "gemini_network_calls": 0,
        "permanent_service_changes": 0,
        "results": results,
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0 if all(item["status"] == "PASS" for item in results) else 1


async def _run_both(html: str) -> list[dict]:
    results = []
    for transport in ("html_v0", "atoms_v1"):
        results.append(await _exercise(html, transport))
    return results


if __name__ == "__main__":
    sys.exit(main())
