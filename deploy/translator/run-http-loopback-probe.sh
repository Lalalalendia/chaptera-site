#!/usr/bin/env bash
# Temporary FastAPI -> SQLite -> offline Gemini worker -> HTTP result acceptance.
# No external network, no Gemini credentials, no systemd changes.
set -euo pipefail
sha="${1:-}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'error=invalid_sha' >&2; exit 2; }
base="$HOME/chaptera-translator-probe/$sha"
[[ -x "$base/venv/bin/chaptera-server" && -x "$base/venv/bin/python" ]] || {
  echo 'error=worker_probe_not_installed' >&2; exit 2;
}
available="$(awk '/^MemAvailable:/ { print int($2/1024) }' /proc/meminfo)"
[[ "$available" =~ ^[0-9]+$ ]] && (( available >= 260 )) || {
  echo 'error=insufficient_memory_for_two_process_probe' >&2; exit 3;
}
if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)8091$'; then
  echo 'error=loopback_port_occupied' >&2; exit 3
fi

work="$(mktemp -d "$base/http-probe.XXXXXX")"
api_pid=''
cleanup() {
  if [[ "$api_pid" =~ ^[0-9]+$ ]]; then
    kill "$api_pid" 2>/dev/null || true
    wait "$api_pid" 2>/dev/null || true
  fi
  [[ "$work" == "$base"/http-probe.* ]] && rm -rf -- "$work"
}
trap cleanup EXIT

# A synthetic token is valid only in this localhost-only ephemeral process.
probe_token='chaptera-loopback-acceptance-not-a-production-credential'
CHAPTERA_BIND=127.0.0.1 CHAPTERA_PORT=8091 \
CHAPTERA_DB_PATH="$work/jobs.sqlite3" \
CHAPTERA_TEAM_TOKENS_JSON='{"probe":"chaptera-loopback-acceptance-not-a-production-credential"}' \
  timeout 65s nice -n 10 "$base/venv/bin/chaptera-server" serve > "$work/api.log" 2>&1 &
api_pid=$!

ready=false
for _ in $(seq 1 30); do
  if curl --silent --fail --max-time 2 http://127.0.0.1:8091/healthz > "$work/health.json"; then
    ready=true
    break
  fi
  sleep 0.25
done
[[ "$ready" == true ]] || { echo 'error=api_not_ready' >&2; exit 3; }
ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Fx '127.0.0.1:8091' >/dev/null || {
  echo 'error=api_not_exclusively_loopback' >&2; exit 3;
}

unauth="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  http://127.0.0.1:8091/v1/jobs)"
[[ "$unauth" == 401 ]] || { echo 'error=unauthenticated_access' >&2; exit 3; }
created="$(curl --silent --show-error --max-time 10 --output "$work/post.json" \
  --write-out '%{http_code}' -X POST \
  -H "X-API-Key: $probe_token" -H 'Content-Type: application/json' \
  -d '{"chapter_id":"loopback-probe","source_html":"<p>世界。</p>","transport":"html_v0"}' \
  http://127.0.0.1:8091/v1/jobs)"
[[ "$created" == 201 ]] || { echo 'error=job_submission' >&2; exit 3; }
job_id="$(python3 - "$work/post.json" <<'PY'
import json,sys
value=json.load(open(sys.argv[1],encoding='utf-8'))['id']
assert isinstance(value,str) and len(value) > 10
print(value)
PY
)"
[[ "$job_id" =~ ^[a-zA-Z0-9-]{12,80}$ ]] || exit 3

"$base/venv/bin/python" - "$work/jobs.sqlite3" <<'PY'
import asyncio, sys
from pathlib import Path
import httpx
from chaptera_server.provider import GeminiProvider
from chaptera_server.smoke import _mock_gemini
from chaptera_server.storage import QueueStore
from chaptera_server.worker import TranslationWorker
async def run():
    async with httpx.AsyncClient(transport=httpx.MockTransport(_mock_gemini)) as client:
        worker=TranslationWorker(QueueStore(Path(sys.argv[1])),
                                 GeminiProvider('offline-probe', 'gemini-2.5-flash', client=client))
        assert await worker.run_once()
asyncio.run(run())
PY

status="$(curl --silent --show-error --max-time 10 --output "$work/result.json" \
  --write-out '%{http_code}' -H "X-API-Key: $probe_token" \
  "http://127.0.0.1:8091/v1/jobs/$job_id")"
[[ "$status" == 200 ]] || { echo 'error=result_endpoint_failed' >&2; exit 3; }
"$base/venv/bin/python" - "$work/result.json" <<'PY'
import json,re,sys
from bs4 import BeautifulSoup
job=json.load(open(sys.argv[1],encoding='utf-8'))
assert job['status'] == 'completed'
text=BeautifulSoup(job['translated_html'],'html.parser').get_text(' ',strip=True)
assert re.search(r'[А-Яа-яЁё]',text) and '世界' not in text
print('http_health=PASS')
print('http_auth=PASS')
print('http_queue=PASS')
print('http_worker_sqlite=PASS')
print('http_result=PASS')
print('real_gemini_calls=0')
print('translator_http_loopback_probe=PASS')
PY
