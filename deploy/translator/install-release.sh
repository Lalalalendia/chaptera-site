#!/usr/bin/env bash
# Rootless pinned-wheelhouse deploy after one-time reviewed root bootstrap.
set -euo pipefail
if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then echo 'error=invalid_release_sha' >&2; exit 2; fi
sha="$1"
root=/opt/chaptera-translator
slot="$HOME/chaptera-translator-incoming/$sha"
release="$root/releases/$sha"
credentials=/etc/chaptera-translator/credentials
if [[ ! -f /etc/chaptera-translator/.bootstrapped || ! -d "$root/releases" ]]; then
  echo 'error=one_time_root_bootstrap_required' >&2; exit 2
fi
for name in team_tokens_json gemini_vault_key; do
  if [[ ! -s "$credentials/$name" ]]; then
    echo "error=missing_protected_credential_$name" >&2; exit 2
  fi
done
if [[ ! -f "$slot/translator-wheelhouse.tar.gz" || ! -f "$slot/translator-wheelhouse.sha256" ]]; then
  echo 'error=missing_wheelhouse_packet' >&2; exit 2
fi
(cd "$slot" && sha256sum -c translator-wheelhouse.sha256 --status)
# Do not activate a wheelhouse that was uploaded but never successfully
# exercised by the transient offline suite (including Full Cycle source ZIP).
# Bind acceptance to BOTH upstream source SHA and the exact packet bytes.
acceptance="$slot/STAGED_SMOKE_SHA256"
[[ -s "$acceptance" ]] || { echo 'error=missing_accepted_offline_stage' >&2; exit 3; }
[[ "$(wc -l < "$acceptance")" == 1 ]] || { echo 'error=invalid_stage_acceptance_record' >&2; exit 3; }
accepted_source=''
accepted_packet=''
accepted_extra=''
read -r accepted_source accepted_packet accepted_extra < "$acceptance" || {
  echo 'error=unreadable_stage_acceptance' >&2; exit 3
}
if [[ "$accepted_source" != "$sha" || ! "$accepted_packet" =~ ^[0-9a-f]{64}$ || -n "$accepted_extra" ]]; then
  echo 'error=stage_acceptance_source_mismatch' >&2; exit 3
fi
actual_packet="$(sha256sum "$slot/translator-wheelhouse.tar.gz" | awk '{print $1}')"
[[ "$actual_packet" == "$accepted_packet" ]] || {
  echo 'error=stage_acceptance_packet_mismatch' >&2; exit 3
}
printf 'translator_stage_acceptance=PASS\n'
available="$(awk '/^MemAvailable:/ { print int($2/1024) }' /proc/meminfo)"
if [[ ! "$available" =~ ^[0-9]+$ ]] || (( available < 320 )); then
  echo 'error=insufficient_available_memory_for_persistent_services' >&2; exit 3
fi
# The content-addressed source archive retains verified chapters even after
# collection jobs are deleted. Unique-body 256 MiB is not the physical DB/WAL
# footprint. Do not activate this release on a disk without a safe margin.
free_archive_mb="$(df -Pm /var/lib/chaptera-translator | awk 'NR==2 {print $4}')"
if [[ ! "$free_archive_mb" =~ ^[0-9]+$ ]] || (( free_archive_mb < 1536 )); then
  echo 'error=insufficient_disk_for_shared_source_archive' >&2; exit 3
fi
for name in chaptera-translator-api.service chaptera-translator-worker.service; do
  test -f "/etc/systemd/system/$name" || { echo "error=missing_$name" >&2; exit 3; }
done
# An existing, bootstrapped unit may predate the archive-only wheel.
# A slim wheel cannot start in legacy full-mode: verify the *effective*
# systemd environment before switching current or restarting anything.
# The root-owned unit must be updated through a separately approved bootstrap.
for name in chaptera-translator-api.service chaptera-translator-worker.service; do
  effective_env="$(systemctl show --property=Environment --value "$name" 2>/dev/null || true)"
  if [[ " $effective_env " != *" CHAPTERA_ARCHIVE_ONLY=1 "* ]]; then
    echo "error=missing_archive_only_runtime_unit_$name" >&2
    exit 3
  fi
done
# The archive-only wheel intentionally does not contain source-worker code.
# A previously enabled crawler must be stopped by an independently reviewed
# administrative action; this deploy must never silently disable it.
if systemctl is-active --quiet chaptera-translator-source-worker.service; then
  echo 'error=active_legacy_source_worker_forbidden_in_archive_release' >&2
  exit 3
fi
previous=''
if [[ -L "$root/current" ]]; then
  previous="$(readlink -f "$root/current" 2>/dev/null || true)"
elif [[ -e "$root/current" ]]; then
  echo 'error=unexpected_non_symlink_current' >&2; exit 3
fi
if [[ -n "$previous" && "$previous" != "$root"/releases/* ]]; then
  echo 'error=unrecognized_existing_current' >&2; exit 3
fi
scratch="$(mktemp -d "$slot/verify.XXXXXX")"
install_dir=''
switched=false
cleanup() {
  rc=$?
  trap - EXIT
  if [[ "$rc" -ne 0 && "$switched" == true ]]; then
    if [[ -n "$previous" && -x "$previous/venv/bin/chaptera-server" ]]; then
      ln -s "$previous" "$root/current.rollback.$$"
      mv -Tf "$root/current.rollback.$$" "$root/current"
      sudo -n systemctl restart chaptera-translator-api.service || true
      sudo -n systemctl restart chaptera-translator-worker.service || true
      printf 'translator_release_rollback=attempted_previous\n' >&2
    else
      sudo -n systemctl stop chaptera-translator-worker.service || true
      sudo -n systemctl stop chaptera-translator-api.service || true
      rm -f -- "$root/current"
      printf 'translator_release_rollback=stopped_no_previous\n' >&2
    fi
  fi
  if [[ -n "$install_dir" && -d "$install_dir" ]]; then rm -rf -- "$install_dir"; fi
  rm -rf -- "$scratch"
  exit "$rc"
}
trap cleanup EXIT
# Python 3.12 filter rejects escaping archive paths, device files, unsafe links.
python3 - "$slot/translator-wheelhouse.tar.gz" "$scratch" <<'PY'
from pathlib import Path
import sys, tarfile
archive, destination = Path(sys.argv[1]), Path(sys.argv[2])
with tarfile.open(archive, 'r:gz') as tar:
    tar.extractall(destination, filter='data')
PY
[[ "$(cat "$scratch/SOURCE_SHA")" == "$sha" ]] || { echo 'error=release_source_mismatch' >&2; exit 3; }
(cd "$scratch" && sha256sum -c SHA256SUMS --status)
pip_wheel="$(find "$scratch/wheelhouse" -maxdepth 1 -type f -name 'pip-*.whl' -print -quit)"
[[ -f "$pip_wheel" ]] || { echo 'error=offline_pip_wheel_missing' >&2; exit 3; }
if [[ ! -x "$release/venv/bin/chaptera-server" ]]; then
  if [[ -e "$release" ]]; then echo 'error=partial_release_exists' >&2; exit 3; fi
  # Install in the final immutable SHA path: venv console scripts have absolute
  # shebangs and cannot be relocated after pip has generated them.
  install -d -m 0755 "$release"
  install_dir="$release"
  python3 -m venv --without-pip "$release/venv"
  PYTHONPATH="$pip_wheel" "$release/venv/bin/python" -m pip install \
    --disable-pip-version-check --no-input --no-index --no-cache-dir \
    --find-links "$scratch/wheelhouse" chaptera-server-translator==0.6.2 >/dev/null
  test -x "$release/venv/bin/chaptera-server"
  printf '%s\n' "$sha" > "$release/SOURCE_SHA"
  chmod -R go-w "$release"
  chmod 0755 "$release"
  install_dir=''
else
  [[ "$(cat "$release/SOURCE_SHA")" == "$sha" ]] || {
    echo 'error=installed_release_sha_mismatch' >&2; exit 3
  }
fi
ln -s "$release" "$root/current.new.$$"
mv -Tf "$root/current.new.$$" "$root/current"
switched=true
sudo -n systemctl restart chaptera-translator-api.service
sudo -n systemctl restart chaptera-translator-worker.service
for _ in $(seq 1 30); do
  if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:8091/healthz >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl --noproxy '*' -fsS --max-time 3 http://127.0.0.1:8091/healthz >/dev/null
status="$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 3 http://127.0.0.1:8091/v1/jobs)"
[[ "$status" == 401 ]] || { echo 'error=unauthenticated_api_access' >&2; exit 3; }
systemctl is-active --quiet chaptera-translator-api.service
systemctl is-active --quiet chaptera-translator-worker.service
systemctl is-active --quiet chaptera-reader.service
[[ "$(readlink -f "$root/current")" == "$release" ]]
switched=false
printf 'translator_release_sha=%s\n' "$sha"
printf 'translator_api_loopback=PASS\n'
printf 'translator_api_unauthenticated=DENIED\n'
printf 'translator_worker_service=active\n'
printf 'chaptera_reader_service=active\n'
printf 'translator_release_result=PASS\n'
