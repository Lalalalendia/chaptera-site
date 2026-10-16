#!/usr/bin/env bash
# Explicit one-request, billable, full-chapter Gemini pilot. No systemd writes.
# stdout is ONLY a tar archive (redacted report + review text on success).
# The Gemini key arrives exclusively through authenticated SSH stdin.
set -euo pipefail
umask 077

if [[ $# -ne 2 ]]; then echo 'error=missing_pilot_arguments' >&2; exit 2; fi
sha="$1"
run_id="$2"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ || ! "$run_id" =~ ^[0-9]{1,20}$ ]]; then
  echo 'error=invalid_release_or_pilot_run' >&2
  exit 2
fi
slot="$HOME/chaptera-translator-incoming/$sha"
work="$slot/paid-pilot-$run_id"
[[ -d "$work" && -s "$work/fixture-086.txt" && -s "$work/pilot-chapter-live.py" ]] || {
  echo 'error=missing_pilot_script_or_pinned_source' >&2
  exit 2
}
cleanup() {
  rc=$?
  trap - EXIT
  if [[ "$work" == "$slot"/paid-pilot-[0-9]* ]]; then
    rm -rf -- "$work"
  fi
  exit "$rc"
}
trap cleanup EXIT

packet="$slot/translator-wheelhouse.tar.gz"
checksum="$slot/translator-wheelhouse.sha256"
[[ -s "$packet" && -s "$checksum" ]] || {
  echo 'error=verified_release_not_staged' >&2
  exit 3
}
(cd "$slot" && sha256sum -c translator-wheelhouse.sha256 --status)
mem="$(awk '/^MemAvailable:/ { print int($2/1024) }' /proc/meminfo)"
[[ "$mem" =~ ^[0-9]+$ ]] && (( mem >= 320 )) || {
  echo 'error=insufficient_memory_for_paid_pilot' >&2
  exit 3
}
systemctl is-active --quiet chaptera-reader.service || {
  echo 'error=reader_not_active' >&2
  exit 3
}

python3 - "$packet" "$work/unpacked" <<'PY'
from pathlib import Path
import sys
import tarfile
destination = Path(sys.argv[2])
destination.mkdir(mode=0o700)
with tarfile.open(sys.argv[1], "r:gz") as archive:
    archive.extractall(destination, filter="data")
PY
[[ "$(cat "$work/unpacked/SOURCE_SHA")" == "$sha" ]] || {
  echo 'error=source_sha_mismatch' >&2
  exit 3
}
(cd "$work/unpacked" && sha256sum -c SHA256SUMS --status)
pip_wheel="$(find "$work/unpacked/wheelhouse" -maxdepth 1 -type f -name 'pip-*.whl' -print -quit)"
[[ -f "$pip_wheel" ]] || { echo 'error=offline_pip_missing' >&2; exit 3; }

python3 -m venv --without-pip "$work/venv"
PYTHONPATH="$pip_wheel" "$work/venv/bin/python" -m pip install \
  --disable-pip-version-check --no-input --no-index --no-cache-dir \
  --find-links "$work/unpacked/wheelhouse" chaptera-server-translator==0.6.2 > /dev/null

# stdin is untouched until this invocation. No credentials saved to disk,
# arguments, environment variables, response logs, or system services.
set +e
CHAPTERA_FULL_CHAPTER_ALLOW_BILLABLE=YES timeout 210s nice -n 10 \
  "$work/venv/bin/python" "$work/pilot-chapter-live.py" \
  --authorize-billable --chapter "$work/fixture-086.txt" \
  --output-dir "$work/output" > /dev/null
result=$?
set -e

if [[ -s "$work/output/report.json" ]]; then
  "$work/venv/bin/python" - "$work/output/report.json" >&2 <<'PY'
import json, sys
report=json.load(open(sys.argv[1], encoding="utf-8"))
assert report["schema"] == "chaptera-full-chapter-live-pilot-v1"
assert 0 <= report["provider_requests"] <= 1
for name in ("model", "job_status", "provider_requests",
             "provider_successful_responses", "structural_qa_passed",
             "russian_character_signal", "remaining_source_cjk_chars",
             "output_visible_chars", "unit_count", "elapsed_seconds",
             "peak_rss_mib", "pass_for_manual_review", "failure_category"):
    print(f"chapter_pilot_{name}={report.get(name)}")
print("chapter_pilot_token_usage=" + json.dumps(report.get("provider_token_usage") or {}, sort_keys=True))
PY
fi
if [[ "$result" -ne 0 || ! -s "$work/output/translation-review.txt" ]]; then
  echo 'error=full_chapter_pilot_incomplete_or_qa_rejected' >&2
  exit 4
fi
# The tar is captured to a private Actions temp file, never emitted in logs.
tar -C "$work/output" -cf - report.json translation-review.txt
