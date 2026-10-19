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
  'chaptera-server-translator[offsite-s3]==0.6.2' > /dev/null

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

# RE-09A-04: exercise the actual PINNED wheel's outbox, offline and isolated.
"$work/venv/bin/python" - "$work" <<'PY'
from pathlib import Path
import sys
from chaptera_server.drive_outbox import DriveOutbox
from chaptera_server.library import BookLibrary
from chaptera_server.storage import QueueStore
db = QueueStore(Path(sys.argv[1]) / "disposable-drive-outbox.sqlite3")
outbox = DriveOutbox(db)
assert outbox.status() == {
    "enabled": False, "pending": 0, "running": 0, "done": 0, "hold": 0,
}
lib = BookLibrary(db)
lib.create_book("book-1", "Offline stage only",
                owner_member_id="operator", actor_id="operator")
chapter = lib.put_chapter(
    "book-1", "chapter-1", chapter_index=1, chapter_path="chapters/1.xhtml",
    source_html="<p>offline source</p>", expected_revision=0,
)
def complete():
    spec = lib.new_job(
        "book-1", "chapter-1", source_language="en", target_language="Russian",
        style_instructions="", max_attempts=1,
    )
    job = db.create_job("operator", spec)
    running = db.claim_next()
    assert running and running[0]["id"] == job["id"]
    assert db.complete(job["id"], running[1], "<p>offline translation</p>",
                       chapter["source_hash"], 1)
    return job["id"]
complete()
assert outbox.status()["pending"] == 0  # no historical backfill
outbox.set_enabled(True)
jid = complete()
assert outbox.status()["pending"] == 1
claim = outbox.claim_next()
assert claim and claim[0] == jid
assert outbox.hold(jid, claim[1], error_code="offline_test_only")
assert outbox.status()["hold"] == 1
assert outbox.retry_held(jid)
assert outbox.status()["pending"] == 1
outbox.set_enabled(False)
assert not outbox.status()["enabled"]
print("stage_drive_outbox_durable_sqlite=PASS")
print("stage_drive_network_calls=0")
print("production_drive_credentials_read=no")
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
# No external cloud access, secrets, root, or live SQLite. The staged wheel has
# boto3/botocore, and the SDK must understand conditional writes for both
# single-part and multipart S3. Fake storage checks ReadEra's streaming logic.
import io
import boto3
sdk = boto3.client("s3", region_name="us-east-1",
                   aws_access_key_id="ephemeral-test", aws_secret_access_key="ephemeral-test")
for operation in ("PutObject", "CompleteMultipartUpload"):
    assert "IfNoneMatch" in sdk.meta.service_model.operation_model(operation).input_shape.members
from chaptera_server.ops_backup_s3 import S3BackupTransport
class OnlyDisposableCiphertext:
    def __init__(self):
        self.objects = {}
    def put_object(self, **kwargs):
        assert kwargs["IfNoneMatch"] == "*"
        assert kwargs["Key"] not in self.objects
        raw = kwargs["Body"].read()
        assert len(raw) == kwargs["ContentLength"]
        assert b"offline fixture" not in raw
        self.objects[kwargs["Key"]] = (raw, kwargs["Metadata"])
        return {"ETag": '"fake"'}
    def head_object(self, *, Bucket, Key):
        raw, metadata = self.objects[Key]
        return {"ContentLength": len(raw), "Metadata": metadata}
    def get_object(self, *, Bucket, Key):
        raw, metadata = self.objects[Key]
        return {"ContentLength": len(raw), "Body": io.BytesIO(raw)}
fake = OnlyDisposableCiphertext()
s3 = S3BackupTransport(fake, bucket="readera-private-test", vault="vps-stage-01")
receipt = s3.push(bundle)
assert receipt["verified"] and receipt["bytes"] == bundle.stat().st_size
assert s3.check_remote(bundle.name)["verified"]
download_dir = work / "temporary-s3-download"
download_dir.mkdir(mode=0o700)
downloaded = s3.pull(bundle.name, download_dir)
s3_recover_dir = work / "temporary-s3-restore"
s3_recover_dir.mkdir(mode=0o700)
s3_restored = unseal(downloaded, keyfile, s3_recover_dir / "jobs.sqlite3")
with sqlite3.connect(s3_restored) as con:
    assert con.execute("SELECT id FROM jobs").fetchone()[0] == job["id"]
print("stage_s3_sdk_conditional_support=PASS")
print("stage_s3_disposable_upload_readback=PASS")
print("stage_s3_disposable_download_restore=PASS")
print("offhost_network_calls=0")
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

# Disposable, no-Gemini-network acceptance of the personal project vault.
"$work/venv/bin/python" - "$work" <<'PY'
import asyncio
import base64
import sqlite3
import sys
from pathlib import Path

from chaptera_server.api import create_app
from chaptera_server.config import Settings
from chaptera_server.member_gemini_provider import MemberGeminiProviders
from chaptera_server.personal_gemini_keys import PersonalGeminiKeys
from chaptera_server.ops_backup import BackupRejected, snapshot
from chaptera_server.ops_backup_crypto import generate_key, seal, unseal
from chaptera_server.ops_backup_vault import verify_restored_vault
from chaptera_server.storage import JobSpec, QueueStore
from chaptera_server.worker import TranslationWorker
import chaptera_server.member_gemini_provider as member_provider

work = Path(sys.argv[1])
master = base64.b64encode(bytes([2]) * 32).decode("ascii")
personal_db = work / "temporary-personal-keys.sqlite3"
config = Settings(
    db_path=personal_db, team_tokens={"moda": "test-only-token-a", "modb": "test-only-token-b"},
    gemini_vault_key=master, gemini_rpm=0, gemini_tpm=0,
    gemini_reserved_output_tokens=0,
)
store = QueueStore(config.db_path)
create_app(config, store)
vault = PersonalGeminiKeys(store, master)
a_key = "AIzaTEST_aaaaaaaaaaaaaaaaaaaaaaaaaa"
b_key = "AIzaTEST_bbbbbbbbbbbbbbbbbbbbbbbbbb"
vault.put("moda", "project-mod-a01", a_key)
vault.put("modb", "project-mod-b01", b_key)
with sqlite3.connect(personal_db) as database:
    assert a_key.encode() not in personal_db.read_bytes()
    assert b_key.encode() not in personal_db.read_bytes()
assert len(vault.list_for("moda")["projects"]) == 1
assert len(vault.list_for("modb")["projects"]) == 1
used = []
class FakeGemini:
    def __init__(self, api_key, model, **kwargs):
        self.api_key, self.model, self.completed_calls = api_key, model, 0
    async def generate(self, request):
        used.append(self.api_key)
        self.completed_calls += 1
        return request.source_html_with_markers.replace("世界正在燃烧。", "Мир горит.")
member_provider.GeminiProvider = FakeGemini
for i in range(2):
    store.create_job("moda", JobSpec(f"a-{i}", "<body><p>世界正在燃烧。</p></body>"))
store.create_job("modb", JobSpec("b-0", "<body><p>世界正在燃烧。</p></body>"))
# RE-06C: keys alone do not authorize requests. Admission is fail-closed
# until each project has a moderator-configured local daily request cap.
assert store.claim_next(require_personal_key=True) is None
vault.set_daily_cap("moda", "project-mod-a01", 21)
vault.set_daily_cap("modb", "project-mod-b01", 21)
async def trial():
    worker = TranslationWorker(store, MemberGeminiProviders(store, config, vault))
    assert await worker.run_once()
    assert await worker.run_once()
    assert await worker.run_once()
    assert not await worker.run_once()
asyncio.run(trial())
assert used == [b_key, a_key, a_key]
assert all(job["status"] == "completed" for job in store.list_jobs())
# RE-08: the existing RBE backup key and application vault key are independent.
# Only disposable files under the rootless staging scratch directory are used.
personal_snapshot_dir = work / "synthetic-personal-snapshots"
personal_snapshot_dir.mkdir(mode=0o700)
personal_manifest = snapshot(personal_db, personal_snapshot_dir)
personal_rbe_keys = work / "synthetic-personal-rbe-keys"
personal_rbe_keys.mkdir(mode=0o700)
personal_rbe_key = generate_key(personal_rbe_keys / "rbe.key")
personal_sealed_dir = work / "synthetic-personal-sealed"
personal_sealed_dir.mkdir(mode=0o700)
personal_archive = seal(personal_manifest, personal_rbe_key, personal_sealed_dir)
personal_restore_dir = work / "synthetic-personal-restore"
personal_restore_dir.mkdir(mode=0o700)
personal_restored = unseal(
    personal_archive, personal_rbe_key, personal_restore_dir / "restored.sqlite3"
)
personal_escrow = work / "synthetic-independent-escrow"
personal_escrow.mkdir(mode=0o700)
escrow_file = personal_escrow / "gemini_vault_key"
escrow_file.write_text(master + "\n", encoding="ascii")
escrow_file.chmod(0o600)
assert verify_restored_vault(personal_restored, escrow_file)["projects_checked"] == 2
with sqlite3.connect(personal_restored) as restored_database:
    assert restored_database.execute(
        "SELECT COUNT(*) FROM member_gemini_budgets"
    ).fetchone()[0] == 2
    assert restored_database.execute(
        "SELECT daily_request_cap FROM member_gemini_budgets "
        "WHERE project_id='project-mod-a01'"
    ).fetchone()[0] == 21
wrong_escrow = personal_escrow / "incorrect_vault"
wrong_escrow.write_text(base64.b64encode(bytes([3]) * 32).decode("ascii"), encoding="ascii")
wrong_escrow.chmod(0o600)
try:
    verify_restored_vault(personal_restored, wrong_escrow)
except BackupRejected:
    pass
else:
    raise AssertionError("Incorrect Gemini vault escrow was accepted")
print("stage_personal_gemini_vault_recovery=PASS")
print("stage_personal_gemini_rpd_caps=PASS")
vault.delete("modb", "project-mod-b01")
assert vault.choices("modb") == []
print("stage_personal_gemini_encrypted_vault=PASS")
print("stage_personal_gemini_actor_dispatch=PASS")
print("stage_personal_gemini_revocation=PASS")
print("real_gemini_calls=0")
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
