#!/usr/bin/env bash
# Reviewed ONE-TIME ROOT install of inert Drive exporter units.
# Does not restart API/Worker, enable timer, enable DB policy or call Google.
set -euo pipefail
(( EUID == 0 )) || { echo 'error=root_required' >&2; exit 2; }
[[ $# == 0 ]] || { echo 'usage: install-drive-export-units.sh' >&2; exit 2; }
source_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
[[ "$(stat -c '%u:%g' "$source_dir")" == "0:0" ]] || {
  echo 'error=untrusted_unit_source_dir' >&2; exit 2;
}
for name in chaptera-translator-drive-export.service chaptera-translator-drive-export.timer; do
  src="$source_dir/$name"
  dest="/etc/systemd/system/$name"
  [[ -f "$src" && ! -L "$src" && "$(stat -c '%u:%g' "$src")" == "0:0" ]] || {
    echo "error=untrusted_source_$name" >&2; exit 2;
  }
  [[ ! -L "$dest" ]] || { echo "error=linked_dest_$name" >&2; exit 2; }
  if [[ -e "$dest" ]] && ! cmp -s -- "$src" "$dest"; then
    echo "error=existing_different_unit_$name" >&2; exit 2
  fi
done
[[ -f /etc/chaptera-translator/.bootstrapped ]] || {
  echo 'error=translator_not_bootstrapped' >&2; exit 2;
}
credentials=/etc/chaptera-translator/google-drive
[[ -d "$credentials" && ! -L "$credentials" &&
   "$(stat -c '%u:%g:%a' "$credentials")" == "0:0:700" ]] || {
  echo 'error=private_google_credentials_directory_missing_or_unsafe' >&2; exit 2;
}
for key in google_drive_client_id google_drive_client_secret google_drive_refresh_token; do
  path="$credentials/$key"
  [[ -s "$path" && -f "$path" && ! -L "$path" &&
     "$(stat -c '%u:%g:%a' "$path")" == "0:0:600" ]] || {
    echo "error=missing_or_unsafe_google_credential_$key" >&2; exit 2;
  }
done
# This root-owned marker is created only after a separate accepted real-job pilot.
[[ ! -e /etc/chaptera-translator/drive-export-enabled ]] || {
  echo 'error=export_already_authorized_review_before_install' >&2; exit 2;
}
install -o root -g root -m 0644 "$source_dir/chaptera-translator-drive-export.service" \
  /etc/systemd/system/chaptera-translator-drive-export.service
install -o root -g root -m 0644 "$source_dir/chaptera-translator-drive-export.timer" \
  /etc/systemd/system/chaptera-translator-drive-export.timer
systemctl daemon-reload
printf 'drive_export_units=installed_inert\n'
printf 'drive_export_timer_enabled_by_this_script=no\n'
printf 'drive_export_oauth_reauthorized=no\n'
printf 'existing_reader_api_worker_restarted=no\n'
