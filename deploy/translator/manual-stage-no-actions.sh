#!/usr/bin/env bash
# ERIDA MVP: build and STAGE a pinned translator on a trusted Linux workstation.
# Never installs/releases services, opens public ports, enables Drive, or calls Gemini.
# Does not use GitHub Actions, GitHub deployment secrets, or a production runner.
set -euo pipefail
umask 077

fail() { printf 'error=%s\n' "$1" >&2; exit 2; }
usage() {
  cat <<'USAGE'
Usage: bash deploy/translator/manual-stage-no-actions.sh DEPLOY_USER@VPS_HOST

Run from a trusted Linux/WSL2 workstation with Git, Python 3.12, curl, ssh,
scp, tar, sha256sum and a pre-verified SSH host key in ~/.ssh/known_hosts.
Uses the exact Ararra SHA pinned by this branch's translator-service.yml.
Runs tests, builds an offline wheelhouse, stages via SSH, and runs the existing
transient/nonmutating VPS smoke. NEVER installs or activates a service.
USAGE
}
if [[ $# == 1 && "$1" == '--help' ]]; then usage; exit 0; fi
[[ $# == 1 ]] || { usage >&2; exit 2; }
target="$1"
[[ "$target" =~ ^[a-z_][a-z0-9_-]*@[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail 'invalid_ssh_target_use_user_at_hostname'
for tool in git python3.12 curl ssh scp sha256sum tar timeout awk grep sort mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing_tool_$tool"
done
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
site_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" || fail 'not_in_site_git_checkout'
[[ "$site_root/deploy/translator" == "$script_dir" ]] || fail 'wrong_repo_script_location'
workflow="$site_root/.github/workflows/translator-service.yml"
[[ -s "$workflow" ]] || fail 'missing_pinned_workflow'
mapfile -t pins < <(grep -E '^[[:space:]]+ARARRA_SHA: [0-9a-f]{40}$' "$workflow" | awk '{print $2}' | sort -u)
[[ ${#pins[@]} == 1 && "${pins[0]}" =~ ^[0-9a-f]{40}$ ]] || fail 'missing_or_divergent_exact_sha_pins'
sha="${pins[0]}"
# Never stage an older site branch without the per-chapter consent/UTF-8 smoke.
grep -Fq 'stage_mvp_readable_chapter_txt=PASS' "$script_dir/verify-staged-release.sh" || fail 'mvp_stage_gate_absent_checkout_pr_79'
for file in bootstrap-host.sh install-release.sh verify-staged-release.sh pilot-chapter-offline.py \
    verify-full-cycle-zip-offline.py \
    chaptera-translator-api.service chaptera-translator-worker.service \
    chaptera-translator-drive-export.service chaptera-translator-drive-export.timer \
    install-drive-export-units.sh chaptera-translator-backup-drive.service \
    chaptera-translator-backup-drive.timer install-backup-drive-units.sh; do
  [[ -s "$script_dir/$file" ]] || fail "missing_stage_file_$file"
done
for shell_file in bootstrap-host.sh install-release.sh verify-staged-release.sh \
    install-drive-export-units.sh install-backup-drive-units.sh; do
  bash -n "$script_dir/$shell_file" || fail "bad_shell_syntax_$shell_file"
done
python3.12 -m py_compile "$script_dir/verify-full-cycle-zip-offline.py" || fail 'bad_full_cycle_zip_smoke_syntax'
printf 'manual_stage_source_sha=%s\n' "$sha"
printf 'manual_stage_git_actions_minutes=0\n'
work="$(mktemp -d "${TMPDIR:-/tmp}/erida-manual-stage.XXXXXXXX")"
cleanup(){ rc=$?; trap - EXIT; rm -rf -- "$work"; exit "$rc"; }
trap cleanup EXIT

# Build only a commit already reachable from public Ararra main.
git clone --quiet --no-checkout https://github.com/Lalalalendia/ararra.git "$work/ararra"
git -C "$work/ararra" checkout --quiet --detach "$sha"
[[ "$(git -C "$work/ararra" rev-parse HEAD)" == "$sha" ]] || fail 'wrong_upstream_commit'
git -C "$work/ararra" merge-base --is-ancestor "$sha" origin/main || fail 'pin_not_in_ararra_main'
grep -Fq 'version = "0.6.2"' "$work/ararra/pyproject.toml" || fail 'unreviewed_package_version'
for path in src/chaptera_server/batch_drive_consent.py \
    src/chaptera_server/chapter_plain_txt.py tests/test_mvp_file_to_drive.py \
    tests/test_drive_export.py \
    src/chaptera_server/full_cycle_archive.py \
    docs/RE02_FULL_CYCLE_ARCHIVE_IMPORT.md \
    tests/test_full_cycle_archive_import.py \
    tests/test_full_cycle_actual_exporter_compat.py \
    tests/fixtures/full_cycle_actual_exporter_20261017.zip.b64; do
  [[ -s "$work/ararra/$path" ]] || fail "missing_mvp_source_$path"
done
grep -Fq -- '--consented-only' "$work/ararra/src/chaptera_server/cli.py" || fail 'missing_consented_only_selector'
grep -Fq 'full_cycle_app.chapter_exchange' "$work/ararra/docs/RE02_FULL_CYCLE_ARCHIVE_IMPORT.md" || fail 'missing_full_cycle_zip_contract'


python3.12 -m venv "$work/build-venv"
"$work/build-venv/bin/python" -m pip install --disable-pip-version-check --no-input -e "$work/ararra[test]"
(
  cd "$work/ararra"
  env -u CHAPTERA_GEMINI_API_KEY -u CREDENTIALS_DIRECTORY \
      "$work/build-venv/bin/python" -m pytest -q
  "$work/build-venv/bin/python" tools/check_architecture.py
)
mkdir -p "$work/packet/wheelhouse"
"$work/build-venv/bin/python" -m pip wheel --disable-pip-version-check --no-input \
  --wheel-dir "$work/packet/wheelhouse" "$work/ararra[offsite-s3]"
"$work/build-venv/bin/python" -m pip wheel --disable-pip-version-check --no-input \
  --wheel-dir "$work/packet/wheelhouse" pip
printf '%s\n' "$sha" > "$work/packet/SOURCE_SHA"
cp "$work/ararra/tests/fixtures/full_cycle_actual_exporter_20261017.zip.b64" "$work/packet/full-cycle-exporter.zip.b64"
cp "$script_dir/verify-full-cycle-zip-offline.py" "$work/packet/verify-full-cycle-zip-offline.py"
(cd "$work/packet" && sha256sum wheelhouse/*.whl full-cycle-exporter.zip.b64 verify-full-cycle-zip-offline.py > SHA256SUMS)
tar -czf "$work/translator-wheelhouse.tar.gz" -C "$work/packet" .
(cd "$work" && sha256sum translator-wheelhouse.tar.gz > translator-wheelhouse.sha256)

# Existing independent chapter-086 QA fixture. Verify the exact Git blob before use.
curl -fsSL --retry 2 --max-time 45 \
  'https://raw.githubusercontent.com/Lalalalendia/med/5046ff53207ce2fc89fb83277d9ceec1fee30935/corpora/fanqie/xianjie-jijian/full/chapters/086_author-086_7628922407947862553.txt' \
  -o "$work/fixture-086.txt"
[[ "$(git hash-object "$work/fixture-086.txt")" == 'db53f9b07821d4a28ba35badb0da362613a39e50' ]] || fail 'real_chapter_fixture_mismatch'
(cd "$work" && sha256sum fixture-086.txt > fixture-086.sha256)
env -u CHAPTERA_GEMINI_API_KEY -u CREDENTIALS_DIRECTORY \
  timeout 120s "$work/build-venv/bin/python" \
  "$script_dir/pilot-chapter-offline.py" "$work/fixture-086.txt" \
  > "$work/chapter-086-report.json"
"$work/build-venv/bin/python" - "$work/chapter-086-report.json" <<'PY'
import json, sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
assert report['schema'] == 'chaptera-real-source-offline-v1'
assert report['gemini_network_calls'] == 0
assert all(row['status'] == 'PASS' for row in report['results'])
print('manual_real_chapter_offline=PASS')
PY

# SSH must match a previously verified known_hosts fingerprint; never disable checking.
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$target" \
  "install -d -m 700 'chaptera-translator-incoming/$sha'"
files=(
  "$work/translator-wheelhouse.tar.gz" "$work/translator-wheelhouse.sha256"
  "$work/fixture-086.txt" "$work/fixture-086.sha256"
)
for name in bootstrap-host.sh install-release.sh verify-staged-release.sh pilot-chapter-offline.py \
    chaptera-translator-api.service chaptera-translator-worker.service \
    chaptera-translator-drive-export.service chaptera-translator-drive-export.timer \
    install-drive-export-units.sh chaptera-translator-backup-drive.service \
    chaptera-translator-backup-drive.timer install-backup-drive-units.sh; do
  files+=("$script_dir/$name")
done
scp -o BatchMode=yes -o StrictHostKeyChecking=yes "${files[@]}" \
  "$target:chaptera-translator-incoming/$sha/"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$target" \
  "cd 'chaptera-translator-incoming/$sha' && sha256sum -c translator-wheelhouse.sha256 --status && sha256sum -c fixture-086.sha256 --status"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$target" \
  "bash 'chaptera-translator-incoming/$sha/verify-staged-release.sh' '$sha'"
printf 'manual_staging=PASS\n'
printf 'production_install=no\n'
printf 'production_api_worker_restarted=no\n'
printf 'paid_gemini_calls=0\n'
printf 'google_drive_remote_writes=0\n'
