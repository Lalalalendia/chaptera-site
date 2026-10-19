#!/usr/bin/env bash
# Reviewed one-time ROOT placement of the INERT ReadEra Drive backup units.
# Never enables a timer, starts a job, reads SQLite, or grants Drive access.
set -euo pipefail

(( EUID == 0 )) || { echo 'error=root_required' >&2; exit 2; }
[[ $# == 0 ]] || { echo 'usage: install-backup-drive-units.sh' >&2; exit 2; }
source_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
[[ ! -L "$0" && "$(stat -c '%u:%g:%a' "$source_dir")" == "0:0:700" &&
   "$(stat -c '%u:%g:%a' "$0")" == "0:0:700" ]] || {
  echo 'error=untrusted_unit_source' >&2; exit 2;
}
[[ -f /etc/chaptera-translator/.bootstrapped ]] || {
  echo 'error=translator_not_bootstrapped' >&2; exit 2;
}
[[ ! -e /etc/chaptera-translator/backup-drive-enabled ]] || {
  echo 'error=backup_already_enabled_review_before_install' >&2; exit 2;
}
for name in chaptera-translator-backup-drive.service chaptera-translator-backup-drive.timer; do
  src="$source_dir/$name"
  dest="/etc/systemd/system/$name"
  [[ -f "$src" && ! -L "$src" && "$(stat -c '%u:%g:%a' "$src")" == "0:0:644" ]] || {
    echo "error=untrusted_source_$name" >&2; exit 2;
  }
  [[ ! -L "$dest" ]] || { echo "error=linked_destination_$name" >&2; exit 2; }
  if [[ -e "$dest" ]] && ! cmp -s -- "$src" "$dest"; then
    echo "error=existing_different_unit_$name" >&2; exit 2;
  fi
done

# This installer does not generate or export a recovery key.
# Operator must independently escrow BOTH the RBE and Gemini vault secrets.
backup_dir=/etc/chaptera-translator/backup
backup_key="$backup_dir/backup_rbe_key"
[[ -d "$backup_dir" && ! -L "$backup_dir" &&
   "$(stat -c '%u:%g:%a' "$backup_dir")" == '0:0:700' ]] || {
  echo 'error=operator_backup_key_directory_missing_or_unsafe' >&2; exit 2;
}
[[ -f "$backup_key" && ! -L "$backup_key" &&
   "$(stat -c '%u:%g:%a:%s' "$backup_key")" == '0:0:600:32' ]] || {
  echo 'error=operator_backup_key_missing_or_unsafe' >&2; exit 2;
}
credentials=/etc/chaptera-translator/google-drive
[[ -d "$credentials" && ! -L "$credentials" &&
   "$(stat -c '%u:%g:%a' "$credentials")" == '0:0:700' ]] || {
  echo 'error=private_google_oauth_missing_or_unsafe' >&2; exit 2;
}
for name in google_drive_client_id google_drive_client_secret google_drive_refresh_token; do
  path="$credentials/$name"
  [[ -s "$path" && ! -L "$path" && -f "$path" &&
     "$(stat -c '%u:%g:%a' "$path")" == '0:0:600' ]] || {
    echo "error=missing_google_credential_$name" >&2; exit 2;
  }
done
config=/etc/chaptera-translator/backup-drive.env
[[ -f "$config" && ! -L "$config" &&
   "$(stat -c '%u:%g:%a' "$config")" == '0:0:600' ]] || {
  echo 'error=root_owned_backup_drive_env_missing' >&2; exit 2;
}
# A non-secret folder ID is the entire env file; no executable shell content
# or unreviewed variable names are accepted by the installer.
[[ "$(wc -l < "$config")" -eq 1 ]] || {
  echo 'error=invalid_backup_drive_env_lines' >&2; exit 2;
}
grep -Eq '^CHAPTERA_BACKUP_DRIVE_FOLDER_ID=[A-Za-z0-9_-]{10,128}$' "$config" || {
  echo 'error=invalid_backup_drive_destination' >&2; exit 2;
}
scratch=/var/lib/chaptera-translator/backup-drive-work
[[ ! -L "$scratch" ]] || { echo 'error=unsafe_backup_scratch_symlink' >&2; exit 2; }
install -d -o chaptera-translator -g chaptera-translator -m 0700 "$scratch"
for name in chaptera-translator-backup-drive.service chaptera-translator-backup-drive.timer; do
  install -o root -g root -m 0644 "$source_dir/$name" "/etc/systemd/system/$name"
done
systemctl daemon-reload
printf 'drive_backup_units=installed_inert\n'
printf 'drive_backup_timer_enabled_by_installer=no\n'
printf 'drive_backup_scope=encrypted_rbe_only\n'
printf 'production_database_opened_by_installer=no\n'
printf 'oauth_reauthorized_by_installer=no\n'
