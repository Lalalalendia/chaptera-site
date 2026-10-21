# Timotxt release candidate — October 21, 2026

**Exact pinned Ararra:** `8cffa23d6888963107900b63d1e63d1f7f9b0f84`, already accepted by postmerge [CI 39648498836](https://github.com/Lalalalendia/ararra/actions/runs/39648498836) (Python 3.11/3.12, Web, Chromium all PASS).

This update changes only the production build pin and adds static package verification. On `chaptera-site/main`, existing [translator-service.yml](../../.github/workflows/translator-service.yml) performs a SHA-verified wheelhouse build, transfers files and verifies offline in a temporary venv on the actual VPS. The **live symlink and systemd services remain unchanged** on normal pushes. Ordinary deployment never starts the Timotxt source-worker.

Release-pin changes now also trigger the existing read-only host preflight to collect fresh RAM/disk/installed-version/service-status information, with no database writes and no restart.

## Evidence from the October 20 host report

[Preflight 39431726890](https://github.com/Lalalalendia/chaptera-site/actions/runs/39431726890): MemAvailable 377–384 MiB, disk free approximately 21 GiB, installed Ararra `4b82d3e081203832849cdbca75fce3a71302e8fd`, source-worker inactive, encrypted Drive backup timer inactive, live off-host restore **not assessed**. The 512 MiB source-worker requirement is **not met**. The normal API install script uses a separate 320 MiB RAM gate, and does not imply source-worker approval.

**Manual `workflow_dispatch install=YES` is a distinct production switch** and must not be triggered based on staging alone. Before activation: verify current preflight, production SQLite+vault encrypted off-host backup and isolated restore with non-secret receipt, rollback/Reader/API health, and maintenance approval. Keep the source-worker disabled; site rights and live Timotxt corpus permission gate [Ararra #65](https://github.com/Lalalalendia/ararra/issues/65) is still open. Never make Gemini calls or bulk source requests as a deploy probe.

Source code: [Ararra PR #121](https://github.com/Lalalalendia/ararra/pull/121). Deployment state must distinguish **ready**, **staged**, and **installed**.
