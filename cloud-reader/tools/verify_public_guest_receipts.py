#!/usr/bin/env python3
"""Fail-closed, source-free summary of two production Chromium guest sessions."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

SHA = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
TARGETS = {"idml": "idml_path_geometry", "pdf": "pdf_rectangle_stream"}
REQUIRED_TRUE = (
    "real_pub", "real_chromium", "tls_public_trusted", "rust_server",
    "isolated_worker", "exact_source_bound_revision", "browser_scene_repaint",
    "revised_scene_on_reload", "read_does_not_renew_ttl",
    "same_browser_session_delete_proven",
    "revoked_old_current_scene_export_denied",
    "temporary_bearer_cleared_after_delete", "loss_report_checked",
    "original_pub_immutable", "auth_product_routes_blocked",
    "bearer_absent_from_urls", "no_s3_or_account",
)


def aggregate(release_sha: str, source_sha: str, receipts: dict[str, dict]) -> dict:
    if not COMMIT.fullmatch(release_sha) or not SHA.fullmatch(source_sha):
        raise ValueError("exact release and public fixture SHA are required")
    if set(receipts) != set(TARGETS):
        raise ValueError("both independent IDML and PDF physical consumer proofs required")
    outputs = []
    for target, form in TARGETS.items():
        r = receipts[target]
        if (r.get("schema") != "chaptera.tempedit-real-pub-chromium-https.v1"
                or r.get("status") != "PASS" or r.get("v0_go") is not False
                or r.get("source_sha256") != source_sha
                or r.get("export_target") != target
                or r.get("browser_pointer_commits") != 1
                or not all(r.get(k) is True for k in REQUIRED_TRUE)
                or r.get(f"changed_{target}_geometry_form") != form
                or r.get(f"changed_{target}_geometry_proven") is not True
                or r.get(f"changed_{target}_identity_proven") is not True):
            raise ValueError("public guest physical acceptance incomplete for " + target)
        artifact_sha = r.get(f"changed_{target}_download_sha256")
        byte_len = r.get(f"changed_{target}_byte_len")
        if not isinstance(artifact_sha, str) or not SHA.fullmatch(artifact_sha):
            raise ValueError("private artifact digest invalid for " + target)
        if type(byte_len) is not int or not 0 < byte_len <= 16 * 1024 * 1024:
            raise ValueError("private artifact size invalid for " + target)
        outputs.append({
            "target": target, "download_sha256": artifact_sha,
            "download_byte_len": byte_len,
            "consumer_geometry_form": form,
            "changed_geometry_proven": True,
            "original_pub_immutable": True,
            "same_session_delete_and_old_capability_revocation": True,
        })
    return {
        "schema": "chaptera.public-firstvds-temp-editor-consumer.v1",
        "status": "PASS",
        "release_sha": release_sha,
        "public_origin": "https://reader.chaptera.online",
        "fixture_sha256": source_sha,
        "trusted_public_https": True,
        "independent_real_chromium_sessions": 2,
        "outputs": outputs,
        "ttl_elapsed_and_physical_sweep_proven": False,
        "rollback_exercised": False,
        "v0_go": False,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--release-sha", required=True)
    p.add_argument("--fixture-sha", required=True)
    p.add_argument("--idml", required=True, type=Path)
    p.add_argument("--pdf", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    args = p.parse_args()
    receipts = {
        t: json.loads(path.read_text(encoding="utf-8"))
        for t, path in (("idml", args.idml), ("pdf", args.pdf))
    }
    packet = aggregate(args.release_sha, args.fixture_sha, receipts)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(packet, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("public guest Chromium edit/export/delete: PASS for IDML and PDF")
    print("TTL physical-sweep and rollback remain separate GO gates")


if __name__ == "__main__":
    main()
