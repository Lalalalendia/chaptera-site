#!/usr/bin/env python3
"""RE-02: prove the PINNED installed wheel can import an actual Full Cycle ZIP.

Only synthetic text. All archive inputs and SQLite state are disposable and
local. Any attempted network connection fails. This runs on the stage-only VPS
path; it never touches the running service, its database, Gemini or Drive.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import io
import json
import socket
import sys
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile

FIXTURE_SHA256 = "b23df10ca7abd4e155cfdf38e7203a55e58554e7034ae9787394dbb2de7d146a"


def refuse_network(*_args: object, **_kwargs: object) -> None:
    raise AssertionError("Network call during offline Full Cycle ZIP proof")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: verify-full-cycle-zip-offline.py FIXTURE_B64 DISPOSABLE_DIR")
    fixture = Path(sys.argv[1])
    scratch = Path(sys.argv[2]).resolve()
    if not fixture.is_file() or not scratch.is_dir():
        raise RuntimeError("Missing verified archive fixture or disposable directory")

    import chaptera_server
    from chaptera_server.book_import import parse_book_import
    from chaptera_server.import_sessions import ImportSessions
    from chaptera_server.library import BookLibrary
    from chaptera_server.storage import QueueStore

    # Protect against running this proof against an editable Git checkout:
    # the deployed wheel, not a source tree, must own the imported package.
    installed = Path(chaptera_server.__file__ or "").resolve()
    if not installed.is_relative_to(Path(sys.prefix).resolve()):
        raise AssertionError("Package did not load from the staged wheel venv")

    b64 = "".join(fixture.read_text(encoding="ascii").split())
    raw = base64.b64decode(b64, validate=True)
    if hashlib.sha256(raw).hexdigest() != FIXTURE_SHA256:
        raise AssertionError("Full Cycle exporter ZIP SHA-256 differs from accepted fixture")
    with ZipFile(io.BytesIO(raw)) as package:
        manifest = json.loads(package.read("manifest.json"))
        assert manifest["format"] == "full_cycle_app.chapter_exchange"
        assert manifest["version"] == 1 and manifest["kind"] == "source"
        assert [row["chapter_index"] for row in manifest["chapters"]] == [7, 9, 10]
        for row in manifest["chapters"]:
            for version in ("original", "working"):
                content = package.read(row[f"{version}_file"])
                assert hashlib.sha256(content).hexdigest() == row[f"{version}_sha256"]

    # No external calls, including DNS lookup; no production secrets or DB.
    with (
        patch("socket.socket.connect", refuse_network),
        patch("socket.socket.connect_ex", refuse_network),
        patch("socket.create_connection", refuse_network),
        patch("socket.getaddrinfo", refuse_network),
    ):
        preview, parsed, prefix = parse_book_import("full-cycle-export.zip", raw)
        assert preview["source_archive"]["boundaries"] == "manifest"
        assert preview["chapter_count"] == 3
        assert preview["source_archive"]["missing_positions"] == [[8, 8]]
        assert [item["suggested_index"] for item in preview["chapters"]] == [7, 9, 10]
        assert len(parsed) == 3 and prefix == ""
        assert parsed[1].archive["original_text"] != parsed[1].archive["working_text"]
        store = QueueStore(scratch / "full-cycle-zip-disposable.sqlite3")
        library = BookLibrary(store)  # creates the books schema before confirmation
        sessions = ImportSessions(store)
        stage = sessions.stage("operator", "full-cycle-export.zip", raw)
        assert stage["preview"]["chapter_count"] == 3
        with store._connect() as conn:
            assert conn.execute("SELECT COUNT(*) FROM books").fetchone()[0] == 0
        choices = [
            {
                "sequence": index + 1,
                "action": "create",
                "chapter_id": f"chapter-{number}",
                "chapter_index": number,
                "chapter_path": f"chapters/{number}.xhtml",
                "expected_revision": 0,
            }
            for index, number in enumerate((7, 9, 10))
        ]
        receipt = sessions.confirm(
            "operator",
            stage["stage_id"],
            {
                "book_id": "full-cycle-disposable",
                "book_mode": "create",
                "title": "Offline fixture only",
                "prefix_policy": "reject",
                "chapters": choices,
            },
        )
        assert receipt["imported_count"] == 3
        assert "第999章" in library.get_chapter(
            "full-cycle-disposable", "chapter-7"
        )["source_html"]
        readback = ImportSessions(QueueStore(store.db_path)).archive_original(
            "full-cycle-disposable", "chapter-9"
        )
        assert readback["source_revision"] == 1
        assert readback["source_index"] == 9
        assert readback["original_text"] == "原文九.\n\nАбзац два."
        assert readback["working_text"] == "手工 исправленный текст.\n\nАбзац два."
        assert readback["original_sha256"] != readback["working_sha256"]

    # The stage must also prove the same operator-facing HTTP API the browser
    # uses, not only the underlying importer. ASGITransport stays in-process:
    # no listener, DNS, real site, OAuth token or production database.
    import httpx
    from chaptera_server.api import create_app
    from chaptera_server.config import Settings

    http_store = QueueStore(scratch / "full-cycle-http-disposable.sqlite3")
    http_settings = Settings(
        db_path=http_store.db_path,
        team_tokens={
            "chief": "offline-chief-fixture-only",
            "operator": "offline-operator-fixture-only",
            "other": "offline-other-fixture-only",
        },
        admin_member_id="chief",
    )
    app = create_app(http_settings, http_store)
    files = {"file": ("full-cycle-export.zip", raw, "application/zip")}
    headers = {"X-API-Key": "offline-operator-fixture-only"}
    untrusted = {"X-API-Key": "offline-other-fixture-only"}

    async def exercise_http_import() -> None:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://offline-stage.invalid",
        ) as client:
            noauth = await client.post("/v1/imports/preview", files=files)
            assert noauth.status_code == 401, noauth.text
            preview_http = await client.post(
                "/v1/imports/preview", files=files, headers=headers
            )
            assert preview_http.status_code == 200, preview_http.text
            details = preview_http.json()
            assert details["source_archive"]["boundaries"] == "manifest"
            assert details["chapter_count"] == 3 and details["stored"] is False
            with http_store._connect() as db:
                assert db.execute("SELECT COUNT(*) FROM books").fetchone()[0] == 0
            uploaded = await client.post(
                "/v1/imports/stages",
                files=files,
                headers={**headers, "Idempotency-Key": "fullcycle-offline-stage"},
            )
            assert uploaded.status_code == 201, uploaded.text
            stage_id = uploaded.json()["stage_id"]
            assert uploaded.json()["preview"]["chapter_count"] == 3
            foreign = await client.get(
                f"/v1/imports/stages/{stage_id}", headers=untrusted
            )
            assert foreign.status_code == 404, foreign.text
            chapter_decisions = [
                {
                    "sequence": i + 1, "action": "create",
                    "chapter_id": f"http-{number}",
                    "chapter_index": number,
                    "chapter_path": f"chapters/{number}.xhtml",
                    "expected_revision": 0,
                }
                for i, number in enumerate((7, 9, 10))
            ]
            confirmed = await client.post(
                f"/v1/imports/stages/{stage_id}/confirm",
                headers=headers,
                json={
                    "book_id": "full-cycle-http-disposable",
                    "book_mode": "create",
                    "title": "Offline Full Cycle test only",
                    "prefix_policy": "reject",
                    "owner_member_id": "operator",
                    "chapters": chapter_decisions,
                },
            )
            assert confirmed.status_code == 200, confirmed.text
            assert confirmed.json()["imported_count"] == 3
            raw_endpoint = (
                "/v1/imports/books/full-cycle-http-disposable/chapters/"
                "http-9/archive-original"
            )
            unauth_read = await client.get(raw_endpoint)
            assert unauth_read.status_code == 401, unauth_read.text
            original_read = await client.get(raw_endpoint, headers=headers)
            assert original_read.status_code == 200, original_read.text
            assert original_read.json()["original_text"] == "原文九.\n\nАбзац два."
            assert original_read.json()["working_text"] == (
                "手工 исправленный текст.\n\nАбзац два."
            )

    with (
        patch("socket.socket.connect", refuse_network),
        patch("socket.socket.connect_ex", refuse_network),
        patch("socket.create_connection", refuse_network),
        patch("socket.getaddrinfo", refuse_network),
    ):
        asyncio.run(exercise_http_import())
        restarted = create_app(http_settings, QueueStore(http_store.db_path))
        assert restarted.state.import_sessions.archive_original(
            "full-cycle-http-disposable", "http-9"
        )["source_index"] == 9

    print("stage_full_cycle_zip_http_preview_import=PASS")
    print("stage_full_cycle_zip_http_auth_isolation=PASS")
    print("stage_full_cycle_zip_http_restart_readback=PASS")

    print("stage_full_cycle_zip_exporter_v1=PASS")
    print("stage_full_cycle_zip_atomic_import=PASS")
    print("stage_full_cycle_zip_original_readback=PASS")
    print("stage_full_cycle_zip_network_calls=0")
    print("stage_full_cycle_zip_production_db_access=no")


if __name__ == "__main__":
    main()
