#!/usr/bin/env python3
"""Public production witness for Temporary Editor one-hour sliding TTL.

Source-safe by construction: bearer/session identifiers never leave process memory
and are never written to artifacts or stdout.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import secrets
import time
import urllib.error
import urllib.request

ORIGIN = "https://reader.chaptera.online"
FIXTURE_URL = (
    "https://raw.githubusercontent.com/apache/poi/"
    "942d95d85b15d0dfdb3bc9ba1b4f273f277757c8/"
    "test-data/publisher/SampleNewsletter.pub"
)
FIXTURE_SHA256 = "6a825ba26ba35d6e885acdc62e859591ed37cb0ff7480b554b9cb362b644dfcf"
FIXTURE_BYTES = 291_840
SLIDING_TTL_MS = 3_600_000
EXPIRY_GRACE_SECONDS = 40
SESSION_PREFIX = "tempedit:"


class WitnessError(RuntimeError):
    pass


def request(method: str, path: str, *, body: bytes | None = None,
            token: str | None = None, csrf: str | None = None,
            content_type: str | None = None, timeout: int = 150) -> tuple[int, bytes]:
    headers = {"Accept": "application/json", "Cache-Control": "no-store"}
    # EdgePolicy requires a same-origin browser provenance header on every
    # unsafe method. The real Chromium UI supplies this automatically.
    if method in {"POST", "PUT", "PATCH", "DELETE"}:
        headers["Origin"] = ORIGIN
    if token:
        headers["x-chaptera-reader-session"] = token
    if csrf:
        headers["x-csrf-token"] = csrf
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(
        ORIGIN + path, data=body, headers=headers, method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            if response.geturl() != ORIGIN + path:
                raise WitnessError("public request redirected away from exact origin")
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def as_json(raw: bytes) -> dict:
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise WitnessError("public reply is not an object")
    return value


def expect(status: int, wanted: int, label: str) -> None:
    if status != wanted:
        raise WitnessError(f"{label} returned HTTP {status}")


def download_fixture() -> bytes:
    with urllib.request.urlopen(FIXTURE_URL, timeout=120) as response:
        data = response.read()
    if len(data) != FIXTURE_BYTES or hashlib.sha256(data).hexdigest() != FIXTURE_SHA256:
        raise WitnessError("pinned Publisher fixture identity drifted")
    return data


def ttl_remaining(expires_at_ms: int) -> int:
    return expires_at_ms - int(time.time() * 1000)


def assert_one_hour_ttl(expires_at_ms: int, label: str) -> int:
    remaining = ttl_remaining(expires_at_ms)
    if not 3_450_000 <= remaining <= 3_605_000:
        raise WitnessError(f"{label} did not yield one-hour temporary TTL")
    return remaining


def choose_candidates(current: dict, scene_reply: dict) -> list[tuple[str, int, int]]:
    scene = scene_reply.get("scene")
    if not isinstance(scene, dict) or not isinstance(scene.get("nodes"), list):
        raise WitnessError("temporary Reader Scene missing nodes")
    visible = {
        node.get("node_id")
        for node in scene["nodes"]
        if isinstance(node, dict)
        and isinstance(node.get("node_id"), str)
        and node.get("parent_node_id") is None
        and node.get("origin_node_id") is None
    }
    nodes = current.get("authoring_graph", {}).get("nodes")
    if not isinstance(nodes, dict):
        raise WitnessError("canonical current graph missing nodes")
    out: list[tuple[str, int, int]] = []
    for node_id, node in sorted(nodes.items()):
        if node_id not in visible or not isinstance(node, dict):
            continue
        bounds = node.get("header", {}).get("bounds", {})
        if not isinstance(bounds, dict):
            continue
        x, y = bounds.get("x"), bounds.get("y")
        if type(x) is int and type(y) is int:
            out.append((node_id, x, y))
    if not out:
        raise WitnessError("no direct canonical MoveNode candidates")
    return out


def main() -> int:
    release_sha = os.environ.get("RELEASE_SHA", "")
    output = Path(os.environ["TTL_RECEIPT"])
    if len(release_sha) != 40 or any(c not in "0123456789abcdef" for c in release_sha):
        raise WitnessError("exact deployed release SHA required")

    fixture = download_fixture()
    csrf = secrets.token_hex(16)
    token: str | None = None
    session_id: str | None = None
    expired_proven = False
    stored_ttl_ms = 0
    move_ttl_ms = 0
    expired_current = 0
    expired_scene = 0

    try:
        status, raw = request(
            "POST", "/v1/editor/temporary-sessions",
            body=json.dumps({"expected_byte_len": len(fixture)}).encode(),
            csrf=csrf, content_type="application/json",
        )
        expect(status, 200, "temporary session issue")
        issued = as_json(raw)
        session_id = issued.get("session_id")
        token = issued.get("access_token")
        if (issued.get("mode") != "temporary_edit"
                or not isinstance(session_id, str)
                or not session_id.startswith(SESSION_PREFIX)
                or len(session_id) != len(SESSION_PREFIX) + 32
                or not isinstance(token, str) or len(token) != 64):
            raise WitnessError("temporary session identity invalid")
        upload_path = issued.get("upload_path")
        open_path = issued.get("open_path")
        if not isinstance(upload_path, str) or not isinstance(open_path, str):
            raise WitnessError("temporary upload/open path missing")

        status, raw = request(
            "PUT", upload_path, body=fixture, token=token, csrf=csrf,
            content_type="application/octet-stream",
        )
        expect(status, 200, "accepted temporary upload")
        stored = as_json(raw)
        stored_expiry = int(stored.get("expires_at_ms", 0))
        stored_ttl_ms = assert_one_hour_ttl(stored_expiry, "accepted upload")

        status, raw = request(
            "POST", open_path, body=b"{}", token=token, csrf=csrf,
            content_type="application/json",
        )
        expect(status, 200, "temporary PUB open")
        opened = as_json(raw)
        if opened.get("classification") not in {"supported", "partial"}:
            raise WitnessError("pinned PUB is not editor-eligible")
        source_hash = opened.get("source_sha256")
        if source_hash != FIXTURE_SHA256:
            raise WitnessError("opened source identity mismatch")

        current_path = f"/v1/editor/temporary-sessions/{session_id}/current"
        scene_path = f"/v1/editor/temporary-sessions/{session_id}/scene"
        move_path = f"/v1/editor/temporary-sessions/{session_id}/move-node"

        status, raw = request("GET", current_path, token=token, csrf=csrf)
        expect(status, 200, "canonical current")
        current = as_json(raw)
        status, raw = request("GET", scene_path, token=token, csrf=csrf)
        expect(status, 200, "canonical scene")
        scene_reply = as_json(raw)

        revision = current.get("revision_id")
        candidates = choose_candidates(current, scene_reply)
        accepted = None
        for index, (node_id, x, y) in enumerate(candidates[:24]):
            intent = {
                "protocol_version": "chaptera.commit-request.v1",
                "document_id": session_id,
                "source_hash": source_hash,
                "base_revision_id": revision,
                "client_operation_id": f"prod-ttl-{index}",
                "command": {
                    "kind": "move_node_to", "node_id": node_id,
                    "x_emu": x + 6350, "y_emu": y + 6350,
                },
            }
            status, raw = request(
                "POST", move_path, body=json.dumps(intent).encode(),
                token=token, csrf=csrf, content_type="application/json",
            )
            if status == 422:
                continue
            expect(status, 200, "canonical MoveNode")
            accepted = as_json(raw)
            break
        if accepted is None:
            raise WitnessError("no supported direct MoveNode in pinned PUB")

        move_expiry = int(accepted.get("expires_at_ms", 0))
        move_ttl_ms = assert_one_hour_ttl(move_expiry, "accepted edit")
        if move_expiry <= stored_expiry:
            raise WitnessError("accepted edit did not slide temporary TTL")
        if accepted.get("revision_id") == revision or accepted.get("replayed") is not False:
            raise WitnessError("accepted edit did not create a fresh revision")

        status, raw = request("GET", current_path, token=token, csrf=csrf)
        expect(status, 200, "post-edit current")
        reread = as_json(raw)
        if int(reread.get("expires_at_ms", 0)) != move_expiry:
            raise WitnessError("GET unexpectedly changed sliding TTL")
        if reread.get("revision_id") != accepted.get("revision_id"):
            raise WitnessError("post-edit current lost accepted revision")

        sleep_seconds = max(
            1.0,
            (move_expiry - int(time.time() * 1000)) / 1000.0 + EXPIRY_GRACE_SECONDS,
        )
        time.sleep(sleep_seconds)

        expired_current, _ = request("GET", current_path, token=token, csrf=csrf)
        if expired_current not in {404, 410}:
            raise WitnessError(
                f"expired current remained accessible: HTTP {expired_current}"
            )
        expired_scene, _ = request("GET", scene_path, token=token, csrf=csrf)
        if expired_scene not in {404, 410}:
            raise WitnessError(
                f"expired scene remained accessible: HTTP {expired_scene}"
            )
        expired_proven = True

        # source-neutral receipt only; no session/token/node/file bytes.
        receipt = {
            "schema": "chaptera.temporary-v0-production-ttl.v1",
            "status": "PASS",
            "release_sha": release_sha,
            "fixture_sha256": FIXTURE_SHA256,
            "accepted_upload_one_hour_ttl": True,
            "accepted_edit_one_hour_sliding_ttl": True,
            "stored_ttl_ms_observed": stored_ttl_ms,
            "move_ttl_ms_observed": move_ttl_ms,
            "expired_current_status": expired_current,
            "expired_scene_status": expired_scene,
            "expired_access_cleanup_authority": True,
            "identifier_or_bearer_emitted": False,
        }
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        print(json.dumps({
            "status": "PASS",
            "release_sha": release_sha,
            "one_hour_sliding_ttl": True,
            "expired_access_denied": True,
        }, sort_keys=True))
        return 0
    finally:
        # A failed witness must not intentionally leave a live test source.
        if token and session_id and not expired_proven:
            try:
                request(
                    "DELETE", f"/v1/editor/temporary-sessions/{session_id}",
                    token=token, csrf=csrf,
                )
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
