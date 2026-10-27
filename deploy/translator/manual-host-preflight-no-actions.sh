#!/usr/bin/env bash
# RE-02: run the existing read-only VPS host probe WITHOUT GitHub Actions.
# No secrets, runner registration, root, file transfer, systemd changes or DB.
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage: bash deploy/translator/manual-host-preflight-no-actions.sh DEPLOY_USER@VPS_HOST

Run from a trusted Linux/WSL workstation with existing SSH identity and a
previously verified ~/.ssh/known_hosts entry. This script performs only the
read-only VPS diagnostics from host-preflight.sh and reports a source-pilot
resource gate. It does NOT stage, install, restart or activate any service.
A PASS cannot prove off-host backup/escrow or authorize production rollout.
USAGE
}
if [[ $# == 1 && "$1" == '--help' ]]; then usage; exit 0; fi
[[ $# == 1 ]] || { usage >&2; exit 2; }
target="$1"
[[ "$target" =~ ^[a-z_][a-z0-9_-]*@[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || {
  echo 'error=invalid_ssh_target_use_user_at_hostname' >&2
  exit 2
}
for name in ssh bash grep mktemp rm cat; do
  command -v "$name" >/dev/null 2>&1 || {
    echo "error=missing_tool_$name" >&2
    exit 2
  }
done
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
probe="$script_dir/host-preflight.sh"
[[ -s "$probe" ]] || { echo 'error=missing_readonly_vps_probe' >&2; exit 2; }
bash -n "$probe" || { echo 'error=readonly_probe_syntax' >&2; exit 2; }

report="$(mktemp "${TMPDIR:-/tmp}/erida-host-preflight.XXXXXXXX")"
trap 'rm -f -- "$report"' EXIT
# Passing the script over stdin does not write it to the VPS.
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
  "$target" 'bash -s' < "$probe" > "$report"
for witness in \
  'preflight_completed=yes' \
  'source_pilot_no_mutations=yes' \
  'rust_baseline_no_mutations=yes' \
  'source_pilot_offhost_restore_gate=not_assessed'; do
  grep -Fxq -- "$witness" "$report" || {
    echo 'error=incomplete_or_untrusted_vps_preflight' >&2
    exit 3
  }
done
cat -- "$report"
# Deployment always needs an independent off-host backup and recovery proof.
echo 'translator_offhost_restore_gate=NOT_ASSESSED'
if grep -Fxq 'source_pilot_host_resource_gate=pass' "$report"; then
  echo 'translator_readonly_resource_preflight=PASS'
else
  echo 'translator_readonly_resource_preflight=HOLD'
  exit 3
fi
echo 'translator_production_install=no'
