#!/usr/bin/env bash
# Read-only preflight of an existing Chaptera VPS. Do not print tokens, hostnames, or IPs.
set -euo pipefail

printf 'schema=chaptera.translator.host-preflight.v1\n'
printf 'host_linux=%s\n' "$(test "$(uname -s)" = Linux && echo yes || echo no)"
printf 'host_arch=%s\n' "$(uname -m)"
printf 'ssh_actor_is_root=%s\n' "$(test "$(id -u)" -eq 0 && echo yes || echo no)"

for tool in python3 docker sudo systemctl nginx curl ss; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s=present\n' "$tool"
  else
    printf '%s=missing\n' "$tool"
  fi
done
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import sys
print(f'python_version={sys.version_info.major}.{sys.version_info.minor}')
PY
fi
if test -r /proc/meminfo; then
  awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ { key=$1; sub(/:$/ , "", key); out[tolower(key)] = int($2/1024) } END { for (key in out) printf "%s_mib=%d\n", key, out[key] }' /proc/meminfo
fi
if test -d /var/lib; then
  df -Pk /var/lib | awk 'NR == 2 { printf "state_disk_available_mib=%d\n", $4 / 1024 }'
fi
if command -v sudo >/dev/null 2>&1; then
  if sudo -n -l >/dev/null 2>&1; then
    printf 'sudo_noninteractive_list=permitted\n'
  else
    printf 'sudo_noninteractive_list=unavailable\n'
  fi
fi
if command -v docker >/dev/null 2>&1; then
  if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    printf 'docker_daemon_access=permitted\n'
  else
    printf 'docker_daemon_access=denied_or_unavailable\n'
  fi
fi
if command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    printf 'sudo_true_noninteractive=permitted\n'
  else
    printf 'sudo_true_noninteractive=denied\n'
  fi
fi
if command -v systemctl >/dev/null 2>&1; then
  for unit in nginx chaptera-reader chaptera-translator-api chaptera-translator-worker; do
    if systemctl is-active --quiet "$unit.service" 2>/dev/null; then
      printf 'service_%s=active\n' "${unit//-/_}"
    else
      printf 'service_%s=inactive_or_absent\n' "${unit//-/_}"
    fi
  done
  main_pid="$(systemctl show -p MainPID --value chaptera-reader.service 2>/dev/null || true)"
  if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] && command -v ps >/dev/null 2>&1; then
    rss="$(ps -o rss= -p "$main_pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$rss" =~ ^[0-9]+$ ]]; then
      printf 'reader_main_rss_mib=%d\n' "$((rss / 1024))"
    fi
  fi
fi
for path in /var/www/chaptera/current /opt/chaptera/current /opt/chaptera-translator/current /var/lib/chaptera-translator; do
  case "$path" in
    /var/www/chaptera/current) label=landing_current ;;
    /opt/chaptera/current) label=reader_current ;;
    /opt/chaptera-translator/current) label=translator_current ;;
    /var/lib/chaptera-translator) label=translator_state ;;
  esac
  if test -e "$path"; then
    printf '%s=present\n' "$label"
  else
    printf '%s=absent\n' "$label"
  fi
done
if command -v ss >/dev/null 2>&1; then
  if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)8091$'; then
    printf 'candidate_port_8091=occupied\n'
  else
    printf 'candidate_port_8091=not_listening\n'
  fi
else
  printf 'candidate_port_8091=unknown\n'
fi
if command -v curl >/dev/null 2>&1; then
  # No credentials, no prompts, and no paid generateContent calls.
  status="$(curl --silent --show-error --output /dev/null --connect-timeout 5 --max-time 15 --write-out '%{http_code}' \
    'https://generativelanguage.googleapis.com/v1beta/models' 2>/dev/null || true)"
  if [[ "$status" =~ ^[1-5][0-9][0-9]$ ]]; then
    printf 'gemini_tls_endpoint=reachable_without_credentials\n'
    printf 'gemini_unauth_http_status=%s\n' "$status"
  else
    printf 'gemini_tls_endpoint=unreachable_or_blocked\n'
  fi
fi
# RE-02 source collection: resources-only pilot evidence. This is deliberately
# read-only: no SQLite content or recovery key is accessed, no site is fetched,
# and off-host backup success cannot be inferred from local service status.
printf 'source_pilot_schema=readera.source-pilot.readiness.v1\n'
printf 'source_pilot_memory_floor_mib=512\n'
printf 'source_pilot_disk_floor_mib=1536\n'\nprintf 'source_bulk_disk_floor_mib=5120\n'
memory_mib=''
if test -r /proc/meminfo; then
  memory_mib="$(awk '$1 == "MemAvailable:" {printf "%d", $2/1024; exit}' /proc/meminfo)"
fi
if [[ "$memory_mib" =~ ^[0-9]+$ ]]; then
  printf 'source_pilot_memavailable_mib=%s\n' "$memory_mib"
  if (( memory_mib >= 512 )); then
    memory_gate=pass
  else
    memory_gate=hold
  fi
else
  memory_gate=unknown
fi
printf 'source_pilot_memory_gate=%s\n' "$memory_gate"

state_dir=/var/lib/chaptera-translator
disk_mib=''
if test -d "$state_dir"; then
  disk_mib="$(df -Pm -- "$state_dir" 2>/dev/null | awk 'NR == 2 {print $4}' || true)"
fi
if [[ "$disk_mib" =~ ^[0-9]+$ ]]; then
  printf 'source_pilot_state_disk_available_mib=%s\n' "$disk_mib"
  if (( disk_mib >= 1536 )); then
    disk_gate=pass
  else
    disk_gate=hold
  fi
  if (( disk_mib >= 5120 )); then
    bulk_disk_gate=pass
  else
    bulk_disk_gate=hold
  fi
else
  disk_gate=unknown
  bulk_disk_gate=unknown
fi
printf 'source_pilot_disk_gate=%s\n' "$disk_gate"
printf 'source_bulk_disk_gate=%s\n' "$bulk_disk_gate"

# Include a non-secret exact commit only if an installed release already
# provides the validated SOURCE_SHA marker. Staged releases are not installed.
installed_source=/opt/chaptera-translator/current/SOURCE_SHA
if test -r "$installed_source"; then
  installed_sha="$(head -n 1 -- "$installed_source" 2>/dev/null || true)"
  if [[ "$installed_sha" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'source_pilot_installed_ararra_sha=%s\n' "$installed_sha"
  else
    printf 'source_pilot_installed_ararra_sha=unverified\n'
  fi
else
  printf 'source_pilot_installed_ararra_sha=unavailable\n'
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet chaptera-translator-source-worker.service 2>/dev/null; then
    collector_state=active
  else
    collector_state=inactive_or_absent
  fi
  if systemctl is-active --quiet chaptera-translator-backup-drive.timer 2>/dev/null; then
    backup_timer_state=active
  else
    backup_timer_state=inactive_or_absent
  fi
  if systemctl is-enabled --quiet chaptera-translator-backup-drive.timer 2>/dev/null; then
    backup_timer_enabled=yes
  else
    backup_timer_enabled=no_or_inaccessible
  fi
else
  collector_state=unknown
  backup_timer_state=unknown
  backup_timer_enabled=unknown
fi
printf 'source_pilot_persistent_collector=%s\n' "$collector_state"
printf 'source_pilot_backup_timer=%s\n' "$backup_timer_state"
printf 'source_pilot_backup_timer_enabled=%s\n' "$backup_timer_enabled"
if [[ "$memory_gate" == pass && "$disk_gate" == pass &&
      "$collector_state" == inactive_or_absent ]]; then
  printf 'source_pilot_host_resource_gate=pass\n'
else
  printf 'source_pilot_host_resource_gate=hold\n'
fi
if [[ "$memory_gate" == pass && "$bulk_disk_gate" == pass &&
      "$collector_state" == inactive_or_absent ]]; then
  printf 'source_bulk_host_resource_gate=pass\n'
else
  printf 'source_bulk_host_resource_gate=hold\n'
fi
# Off-host ciphertext existence and independently restorable keys must
# be verified separately. A green host probe never clears the backup gate.
printf 'source_pilot_offhost_restore_gate=not_assessed\n'
printf 'source_pilot_live_site_authorization_gate=not_assessed\n'
printf 'source_pilot_no_mutations=yes\n'
# RUST-MIGRATION-01: ACTUAL resident memory of Python API and worker.
# No process command line, environment, secrets, source text or PID logged.
printf 'rust_baseline_schema=erida.python-process-memory.v1\n'
for spec in api:chaptera-translator-api.service worker:chaptera-translator-worker.service; do
  label="${spec%%:*}"
  unit="${spec#*:}"
  pid=''
  if command -v systemctl >/dev/null 2>&1; then
    pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
  fi
  status=not_running
  rss=unknown
  pss=unknown
  hwm=unknown
  cgroup_current=unknown
  cgroup_peak=unknown
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && test -r "/proc/$pid/status"; then
    status=active
    if command -v ps >/dev/null 2>&1; then
      rss_kib="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
      if [[ "$rss_kib" =~ ^[0-9]+$ ]]; then
        rss="$(( (rss_kib + 1023) / 1024 ))"
      fi
    fi
    peak_kib="$(awk '$1 == "VmHWM:" {print $2;exit}' "/proc/$pid/status" 2>/dev/null || true)"
    if [[ "$peak_kib" =~ ^[0-9]+$ ]]; then
      hwm="$(( (peak_kib + 1023) / 1024 ))"
    fi
    if test -r "/proc/$pid/smaps_rollup"; then
      pss_kib="$(awk '$1 == "Pss:" {print $2;exit}' "/proc/$pid/smaps_rollup" 2>/dev/null || true)"
      if [[ "$pss_kib" =~ ^[0-9]+$ ]]; then
        pss="$(( (pss_kib + 1023) / 1024 ))"
      fi
    fi
    if command -v systemctl >/dev/null 2>&1; then
      group="$(systemctl show -p ControlGroup --value "$unit" 2>/dev/null || true)"
      if [[ "$group" == /* && "$group" != *'..'* ]]; then
        for name in current peak; do
          path="/sys/fs/cgroup${group}/memory.${name}"
          if test -r "$path"; then
            bytes="$(cat "$path" 2>/dev/null || true)"
            if [[ "$bytes" =~ ^[0-9]+$ ]]; then
              value="$(( (bytes + 1048575) / 1048576 ))"
              if [[ "$name" == current ]]; then
                cgroup_current="$value"
              else
                cgroup_peak="$value"
              fi
            fi
          fi
        done
      fi
    fi
  fi
  printf 'rust_baseline_%s_state=%s\n' "$label" "$status"
  printf 'rust_baseline_%s_rss_mib=%s\n' "$label" "$rss"
  printf 'rust_baseline_%s_pss_mib=%s\n' "$label" "$pss"
  printf 'rust_baseline_%s_hwm_mib=%s\n' "$label" "$hwm"
  printf 'rust_baseline_%s_cgroup_current_mib=%s\n' "$label" "$cgroup_current"
  printf 'rust_baseline_%s_cgroup_peak_mib=%s\n' "$label" "$cgroup_peak"
done
printf 'rust_baseline_no_mutations=yes\n'
printf 'preflight_completed=yes\n'
