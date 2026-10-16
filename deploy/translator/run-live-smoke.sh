#!/usr/bin/env bash
# Exactly one explicitly authorized Gemini request on the existing rootless VPS install.
# The protected Actions secret is piped through SSH stdin; never written or printed.
set -euo pipefail

sha="${1:-}"
protocol="${2:-}"
model="${3:-}"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ || ! "$protocol" =~ ^(html_v0|atoms_v1)$ || ! "$model" =~ ^(gemini-3\.8-flash|gemini-3\.6-flash|gemini-3\.5-flash-lite)$ ]]; then
  echo 'error=invalid_sha_transport_or_model' >&2
  exit 2
fi
base="$HOME/chaptera-translator-probe/$sha"
staged="$HOME/chaptera-translator-incoming/$sha/payload/SOURCE_SHA"
if [[ ! -x "$base/venv/bin/chaptera-smoke" || ! -f "$staged" || "$(cat "$staged")" != "$sha" ]]; then
  echo 'error=verified_worker_not_installed' >&2
  exit 2
fi
if [[ ! -s "$base/html_v0.json" || ! -s "$base/atoms_v1.json" ]]; then
  echo 'error=offline_worker_proof_missing' >&2
  exit 2
fi
available="$(awk '/^MemAvailable:/ { print int($2/1024) }' /proc/meminfo)"
if [[ ! "$available" =~ ^[0-9]+$ ]] || (( available < 240 )); then
  echo 'error=insufficient_available_memory' >&2
  exit 3
fi

# One newline-terminated API key from protected Actions secret over SSH stdin.
IFS= read -r api_key || { echo 'error=key_not_received' >&2; exit 2; }
[[ -n "$api_key" && "$api_key" != *$'\r'* ]] || { echo 'error=invalid_key' >&2; exit 2; }

umask 077
set +e
CHAPTERA_GEMINI_API_KEY="$api_key" CHAPTERA_SMOKE_ALLOW_LIVE=YES \
  timeout 100s nice -n 10 "$base/venv/bin/chaptera-smoke" \
  --live --authorize-billable --max-requests 1 --transport "$protocol" --model "$model" \
  --output "$base/live-$protocol.json"
status=$?
set -e
unset api_key

if [[ -s "$base/live-$protocol.json" ]]; then
  python3 - "$base/live-$protocol.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding='utf-8'))
assert report['schema'] == 'chaptera-gemini-smoke-v1'
assert report['mode'] == 'live_gemini'
assert report['provider_requests'] <= 1
for key in ('mode', 'model', 'transport', 'job_status', 'provider_requests',
            'provider_successful_responses', 'structural_qa_passed',
            'language_probe_passed', 'result_persisted', 'qa_passed', 'failure_category'):
    print(f'{key}={report.get(key)}')
print('live_gemini_worker_proof=' + ('PASS' if report['qa_passed'] else 'FAIL'))
PY
else
  echo 'error=live_smoke_no_report' >&2
fi
exit "$status"
