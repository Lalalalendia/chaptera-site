#!/usr/bin/env python3
"""Repository-wide no-VPS fail-closed guard.

The previous VPS was retired on 2026-10-29. While development is offline,
every workflow job that contacts it or probes its public endpoints must be
explicitly disabled, including manually dispatched and scheduled jobs.
Keep pure GitHub-runner compilation, wheel builds and static validation on.
Re-enabling requires a reviewed PR and a separately approved new VPS.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"

REMOTE_JOBS = {
    "translator-service.yml": ("stage",),
    "translator-host-preflight.yml": ("preflight",),
    "translator-rootless-smoke.yml": ("smoke",),
    "translator-http-loopback-smoke.yml": ("http-probe",),
    "deploy.yml": ("deploy",),
    "deploy-reader-static.yml": ("deploy",),
    "deploy-reader-backend.yml": ("deploy",),
    "reader-production-ttl-acceptance.yml": ("ttl",),
    "validate-reader-autodeploy.yml": ("public-edge-header-witness",),
}

OFFLINE_JOBS = {
    "translator-service.yml": ("build",),
    "translator-host-preflight.yml": ("validate",),
    "translator-rootless-smoke.yml": ("build",),
    "validate-reader-autodeploy.yml": ("validate",),
    "validate.yml": ("validate",),
}

FALSE = "    if: ${{ false }}"


def jobs_in(path: Path) -> dict[str, str]:
    source = path.read_text(encoding="utf-8")
    if "\njobs:\n" not in source:
        raise AssertionError(f"Missing jobs declaration: {path.name}")
    body = source.split("\njobs:\n", 1)[1]
    starts = list(re.finditer(r"(?m)^  ([a-zA-Z0-9_-]+):\s*$", body))
    if not starts:
        raise AssertionError(f"No job blocks: {path.name}")
    found = {}
    for i, start in enumerate(starts):
        name = start.group(1)
        if name in found:
            raise AssertionError(f"Duplicate job: {path.name} / {name}")
        end = starts[i + 1].start() if i + 1 < len(starts) else len(body)
        found[name] = body[start.end():end]
    return found


def main() -> None:
    required = set(REMOTE_JOBS) | set(OFFLINE_JOBS)
    for filename in sorted(required):
        jobs = jobs_in(WORKFLOWS / filename)
        for name in REMOTE_JOBS.get(filename, ()):
            if name not in jobs or FALSE not in jobs[name].splitlines():
                raise AssertionError(
                    f"VPS job is not fail-closed: {filename} / {name}"
                )
            print(f"remote_job_paused=PASS {filename} / {name}")
        for name in OFFLINE_JOBS.get(filename, ()):
            if name not in jobs or FALSE in jobs[name].splitlines():
                raise AssertionError(
                    f"Offline CI unexpectedly disabled: {filename} / {name}"
                )
            print(f"offline_job_retained=PASS {filename} / {name}")

    backend = jobs_in(WORKFLOWS / "deploy-reader-backend.yml")
    acceptance = backend.get("public-acceptance", "")
    if "needs: deploy" not in acceptance or (
        "needs.deploy.result == 'success'" not in acceptance
    ):
        raise AssertionError("Public Reader acceptance must depend on paused deploy")

    print("no_vps_network_deploy_jobs=0")
    print("no_vps_development_gate=PASS")


if __name__ == "__main__":
    main()
