#!/usr/bin/env bash
# Verify the exact staged 0.6.2 release on the real VPS without root,
# service mutation, Gemini credentials, public binding or billable requests.
set -euo pipefail
umask 077
if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'error=invalid_staged_release_sha' >&2
  exit 2
fi
sha="$1"
slot="$HOME/chaptera-translator-incoming/$sha"
packet="$slot/translator-wheelhouse.tar.gz"
checksum="$slot/translator-wheelhouse.sha256"
[[ -f "$packet" && -f "$checksum" ]] || {
  echo 'error=staged_wheelhouse_missing' >&2
  exit 2
}
(cd "$slot" && sha256sum -c translator-wheelhouse.sha256 --status)
available="$(awk '/^MemAvailable:/ { print int($2/1024) }' /proc/meminfo)"
if [[ ! "$available" =~ ^[0-9]+$ ]] || (( available < 280 )); then
  echo 'error=insufficient_memory_for_staged_smoke' >&2
  exit 3
fi
work="$(mktemp -d "$slot/staged-smoke.XXXXXXXX")"
cleanup() {
  rc=$?
  trap - EXIT
  # The real source is public but should not be retained as a staging side effect.
  rm -f -- "$slot/fixture-086.txt" "$slot/fixture-086.sha256"
  if [[ "$work" == "$slot"/staged-smoke.* ]]; then
    rm -rf -- "$work"
  fi
  exit "$rc"
}
trap cleanup EXIT

python3 - "$packet" "$work/unpacked" <<'PY'
from pathlib import Path
import sys
import tarfile

archive, destination = Path(sys.argv[1]), Path(sys.argv[2])
destination.mkdir(mode=0o700)
with tarfile.open(archive, "r:gz") as packet:
    packet.extractall(destination, filter="data")
PY
[[ "$(cat "$work/unpacked/SOURCE_SHA")" == "$sha" ]] || {
  echo 'error=staged_source_sha_mismatch' >&2
  exit 3
}
(cd "$work/unpacked" && sha256sum -c SHA256SUMS --status)
pip_wheel="$(find "$work/unpacked/wheelhouse" -maxdepth 1 -type f -name 'pip-*.whl' -print -quit)"
[[ -f "$pip_wheel" ]] || { echo 'error=offline_pip_missing' >&2; exit 3; }

python3 -m venv --without-pip "$work/venv"
PYTHONPATH="$pip_wheel" "$work/venv/bin/python" -m pip install \
  --disable-pip-version-check --no-input --no-index --no-cache-dir \
  --find-links "$work/unpacked/wheelhouse" \
  chaptera-server-translator==0.6.2 > /dev/null

for transport in html_v0 atoms_v1; do
  env -u CHAPTERA_GEMINI_API_KEY -u CREDENTIALS_DIRECTORY \
    timeout 90s nice -n 10 "$work/venv/bin/chaptera-smoke" \
    --transport "$transport" --model gemini-3.8-flash \
    --max-requests 1 --output "$work/$transport.json"
done

"$work/venv/bin/python" - "$work" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
for transport in ("html_v0", "atoms_v1"):
    report = json.loads((root / f"{transport}.json").read_text(encoding="utf-8"))
    assert report["schema"] == "chaptera-gemini-smoke-v1"
    assert report["mode"] == "offline_mock"
    assert report["model"] == "gemini-3.8-flash"
    assert report["transport"] == transport
    assert report["provider_requests"] == 1
    assert report["provider_successful_responses"] == 1
    assert report["job_status"] == "completed"
    assert report["qa_passed"] is True
    assert report["result_persisted"] is True
    assert report["provider_reported_tokens"] is None
    print(f"stage_{transport}_worker_sqlite=PASS")
print("real_gemini_calls=0")
print("permanent_services_changed=no")
print("translator_staged_062_acceptance=PASS")
PY

# Check the bundled SQLite recovery tool against disposable, NON-PRODUCTION
# state on the actual VPS. The Reader database and translator state are untouched.
"$work/venv/bin/python" - "$work" <<'PY'
from pathlib import Path
import sqlite3
import sys

from chaptera_server.api import create_app
from chaptera_server.config import Settings
from chaptera_server.ops_backup import snapshot, verify, restore
from chaptera_server.storage import JobSpec, QueueStore

work = Path(sys.argv[1])
db = work / "isolated-readera.sqlite3"
settings = Settings(db_path=db, team_tokens={"operator": "offline-test-only"},
                    admin_member_id="operator")
store = QueueStore(db)
create_app(settings, store)
job = store.create_job("operator", JobSpec(
    chapter_id="disposable", source_html="<p>offline fixture</p>"))
private = work / "private-snapshots"
private.mkdir(mode=0o700)
manifest = snapshot(db, private)
assert verify(manifest)["schema"] == "readera.sqlite-snapshot.v1"
recovery = work / "offline-recovery"
recovery.mkdir(mode=0o700)
target = restore(manifest, recovery / "isolated-recovered.sqlite3")
with sqlite3.connect(target) as con:
    assert con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert con.execute("SELECT id FROM jobs").fetchone()[0] == job["id"]
from chaptera_server.ops_backup_crypto import (
    BackupRejected, generate_key, seal, unseal,
)
keydir = work / "ephemeral-keys"
keydir.mkdir(mode=0o700)
keyfile = generate_key(keydir / "readera-test.key")
encrypted = work / "ephemeral-encrypted"
encrypted.mkdir(mode=0o700)
bundle = seal(manifest, keyfile, encrypted)
encrypted_restore = work / "ephemeral-encrypted-recovery"
encrypted_restore.mkdir(mode=0o700)
recovered = unseal(bundle, keyfile, encrypted_restore / "recovered.sqlite3")
with sqlite3.connect(recovered) as con:
    assert con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert con.execute("SELECT id FROM jobs").fetchone()[0] == job["id"]
assert b"offline fixture" not in bundle.read_bytes()
# Corrupt the authenticated tag: no partial database must be published.
with bundle.open("r+b") as raw:
    raw.seek(-1, 2)
    original_tag_byte = raw.read(1)
    raw.seek(-1, 2)
    raw.write(bytes([original_tag_byte[0] ^ 1]))
blocked_path = encrypted_restore / "must-not-exist.sqlite3"
try:
    unseal(bundle, keyfile, blocked_path)
except BackupRejected:
    assert not blocked_path.exists()
else:
    raise AssertionError("AES-GCM tag forgery was accepted")
print("stage_sqlite_online_snapshot=PASS")
print("stage_sqlite_offline_restore=PASS")
print("stage_sqlite_encrypted_bundle=PASS")
print("stage_sqlite_encrypted_tamper_rejected=PASS")
print("live_translator_database_access=no")
PY

# Stress the actual chapter from med using a local HTTP mock. It intentionally
# produces Cyrillic placeholders, NOT a literary translation.
[[ -s "$slot/fixture-086.txt" && -s "$slot/fixture-086.sha256" && -s "$slot/pilot-chapter-offline.py" ]] || {
  echo 'error=missing_verified_real_source_fixture' >&2
  exit 3
}
(cd "$slot" && sha256sum -c fixture-086.sha256 --status)
env -u CHAPTERA_GEMINI_API_KEY -u CREDENTIALS_DIRECTORY \
  timeout 125s nice -n 10 "$work/venv/bin/python" \
  "$slot/pilot-chapter-offline.py" "$slot/fixture-086.txt" > "$work/real-chapter-report.json"
"$work/venv/bin/python" - "$work/real-chapter-report.json" <<'PY'
import json
from pathlib import Path
import sys
report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["schema"] == "chaptera-real-source-offline-v1"
assert report["mock_response_kind"] == "CYRILLIC_PLACEHOLDERS_NOT_REAL_TRANSLATION"
assert report["gemini_network_calls"] == 0
assert report["permanent_service_changes"] == 0
assert {item["transport"] for item in report["results"]} == {"html_v0", "atoms_v1"}
for item in report["results"]:
    assert item["status"] == "PASS"
    print(f"real_chapter_{item['transport']}_offline=PASS")
print("real_chapter_offline_probe=PASS")
PY
