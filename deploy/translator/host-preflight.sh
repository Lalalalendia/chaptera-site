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
printf 'preflight_completed=yes\n'
