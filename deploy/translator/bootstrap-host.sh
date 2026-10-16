#!/usr/bin/env bash
# ONE-TIME root bootstrap. No Reader, Nginx or landing changes.
set -euo pipefail
if (( EUID != 0 )); then echo 'error=root_required' >&2; exit 2; fi
if [[ $# -ne 1 || ! "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo 'usage: bootstrap-host.sh <existing-ssh-deploy-user>' >&2; exit 2
fi
deploy_user="$1"
if ! id "$deploy_user" >/dev/null 2>&1 || [[ "$deploy_user" == root ]]; then
  echo 'error=invalid_deploy_user' >&2; exit 2
fi
for tool in useradd install systemctl visudo python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error=missing_$tool" >&2; exit 2; }
done
source_dir="$(cd "$(dirname "$0")" && pwd -P)"
for f in chaptera-translator-api.service chaptera-translator-worker.service; do
  test -s "$source_dir/$f" || { echo "error=missing_$f" >&2; exit 2; }
done
if ! id chaptera-translator >/dev/null 2>&1; then
  useradd --system --home /var/lib/chaptera-translator --shell /usr/sbin/nologin chaptera-translator
fi
runtime_group="$(id -gn "$deploy_user")"
install -d -m 0755 -o "$deploy_user" -g "$runtime_group" /opt/chaptera-translator /opt/chaptera-translator/releases
install -d -m 0700 -o chaptera-translator -g chaptera-translator /var/lib/chaptera-translator
install -d -m 0755 -o root -g root /etc/chaptera-translator
install -d -m 0700 -o "$deploy_user" -g "$runtime_group" /etc/chaptera-translator/credentials
token_file=/etc/chaptera-translator/credentials/team_tokens_json
if [[ ! -e "$token_file" ]]; then
  python3 - "$token_file" <<'PY'
from pathlib import Path
import json, os, secrets, sys
path = Path(sys.argv[1])
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w', encoding='utf-8') as stream:
    json.dump({'operator': secrets.token_urlsafe(48)}, stream)
PY
  chown "$deploy_user:$runtime_group" "$token_file"
fi
chmod 0600 "$token_file"
install -m 0644 -o root -g root "$source_dir/chaptera-translator-api.service" /etc/systemd/system/chaptera-translator-api.service
install -m 0644 -o root -g root "$source_dir/chaptera-translator-worker.service" /etc/systemd/system/chaptera-translator-worker.service
systemctl_path="$(command -v systemctl)"
[[ "$systemctl_path" == /usr/bin/systemctl || "$systemctl_path" == /bin/systemctl ]] || {
  echo 'error=unexpected_systemctl_path' >&2; exit 2;
}
sudoers_file=/etc/sudoers.d/chaptera-translator-services
cat > "$sudoers_file" <<SUDOERS
$deploy_user ALL=(root) NOPASSWD: $systemctl_path restart chaptera-translator-api.service, $systemctl_path restart chaptera-translator-worker.service, $systemctl_path stop chaptera-translator-api.service, $systemctl_path stop chaptera-translator-worker.service, $systemctl_path start chaptera-translator-api.service, $systemctl_path start chaptera-translator-worker.service
SUDOERS
chmod 0440 "$sudoers_file"
visudo -cf "$sudoers_file" >/dev/null
systemctl daemon-reload
systemctl enable chaptera-translator-api.service chaptera-translator-worker.service >/dev/null
install -m 0644 -o root -g root /dev/null /etc/chaptera-translator/.bootstrapped
printf 'translator_bootstrap=PASS\n'
printf 'translator_services=enabled_not_started\n'
printf 'translator_api_bind=127.0.0.1:8091\n'
printf 'reader_modified=no\n'
