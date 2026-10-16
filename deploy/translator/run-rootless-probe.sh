#!/usr/bin/env bash
# Runner feeds this source through the verified SSH session. No sudo, Docker, or systemd.
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'error=invalid_pinned_release_sha\n' >&2
  exit 2
fi
sha="$1"
slot="$HOME/chaptera-translator-incoming/$sha"
if [[ ! -d "$slot" || ! -f "$slot/wheelhouse.tar.gz" || ! -f "$slot/wheelhouse.sha256" ]]; then
  printf 'error=missing_staged_release\n' >&2
  exit 2
fi
cd "$slot"
sha256sum -c wheelhouse.sha256 --status
mkdir -p payload
# The archive is created from SHA-verified source by the trusted Actions workflow.
tar -xzf wheelhouse.tar.gz -C payload
cd payload
[[ "$(cat SOURCE_SHA)" == "$sha" ]] || { printf 'error=source_sha_mismatch\n' >&2; exit 2; }
sha256sum -c SHA256SUMS --status

# Reject running while the host is already under pressure; don't affect Reader.
available="$(awk '/^MemAvailable:/ { print int($2/1024) }' /proc/meminfo)"
if [[ ! "$available" =~ ^[0-9]+$ ]] || (( available < 240 )); then
  printf 'error=insufficient_available_memory\n' >&2
  exit 3
fi

install_root="$HOME/chaptera-translator-probe/$sha"
mkdir -p "$install_root"
python3 -m venv "$install_root/venv"
"$install_root/venv/bin/python" -m pip install --no-input --no-index \
  --no-cache-dir --find-links "$slot/payload/wheelhouse" chaptera-server-translator==0.6.1

for transport in html_v0 atoms_v1; do
  timeout 90s nice -n 10 "$install_root/venv/bin/chaptera-smoke" \
    --transport "$transport" --output "$install_root/$transport.json"
done

python3 - "$install_root" <<'PY'
import json
from pathlib import Path
import sys
base = Path(sys.argv[1])
for protocol in ('html_v0','atoms_v1'):
    report = json.loads((base / (protocol + '.json')).read_text(encoding='utf-8'))
    assert report['schema'] == 'chaptera-gemini-smoke-v1'
    assert report['mode'] == 'offline_mock'
    assert report['transport'] == protocol
    assert report['qa_passed'] is True
    assert report['result_persisted'] is True
    assert report['provider_requests'] == 1
    assert report['provider_successful_responses'] == 1
    print(f'offline_{protocol}_worker_sqlite=PASS')
print('real_gemini_calls=0')
print('translator_rootless_probe=PASS')
PY
