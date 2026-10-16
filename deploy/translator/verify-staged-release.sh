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
