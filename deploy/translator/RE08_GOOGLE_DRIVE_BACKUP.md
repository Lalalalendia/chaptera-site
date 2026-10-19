# RE-08-GDRIVE-01 — daily encrypted ReadEra SQLite backup to Google Drive

## Destination already created

- Google Drive: **Эрида / Резервные копии**
- Folder ID: `1ll0rsERY7kpdMm8rQQVDAFcdx7_gihtl`
- <https://drive.google.com/drive/folders/1ll0rsERY7kpdMm8rQQVDAFcdx7_gihtl>
- The folder inherits access from the existing shared `Эрида` root and is not a private, single-principal WORM backup store. It is acceptable **only for AES-256-GCM ciphertext**. Do not upload any unsealed SQLite, snapshot manifests, authentication tokens or key files.

## What an actual run does

1. The short-lived `chaptera-translator-backup-drive.service` reads the **live SQLite** by SQLite's online backup API, preserving WAL-consistent committed data without stopping Reader, API or worker.
2. It produces a private mode-0600 snapshot in a disposable 0700 scratch directory, verifies full SQLite integrity, and seals it into a distinct, SHA-backed, authenticated `.sqlite3.rbe` AES-256-GCM archive.
3. It **unseals into another isolated temporary directory and checks integrity again**, before any upload.
4. It uses the existing restricted Google OAuth `drive.file` credentials via systemd LoadCredential to create a fresh `application/octet-stream` object with a 1-MiB resumable uploader. A remote file is never overwritten, deleted, moved or shared. On an ambiguous result it rejects rather than claiming success.
5. It re-reads the complete encrypted file from Drive, validates remote SHA-256, MD5 metadata and exact byte count, and then deletes the temporary local plaintext/ciphertext. A failure is emitted as a **redacted** rejection, never an API key, text, token or Drive response body.

The job does **not** auto-sync book edits, translate anything, call Gemini or modify permanent services. Google Drive must not be regarded as immutable storage: both existing shared-folder principals can manage content. No automatic Drive deletion/retention is implemented. Monitor quota usage and protect the account against unauthorized deletion.

## ReadEra OAuth access to the backup folder — owner-only, read-only first

Google's [Drive `drive.file` scope](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
is per-file, not access to every file that the Google account can see. The
[desktop Google Picker](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker)
is the approved method for explicitly sharing specific folders with this
desktop OAuth client. The ChatGPT Google Drive connection that created our
new folder is separate from ReadEra's installed Desktop OAuth client.

**Never replace the already working refresh token just to test this.**

1. First try the existing VPS credentials with the **read-only**
   `python -m chaptera_server.ops_backup_drive --probe-folder` command in
   the protected transient systemd environment shown in step 4 below. If it
   prints `drive_backup_folder_access=PASS`, no extra consent is needed.
   If it rejects (for example HTTP 404/403), do **not** run any live backup.
2. On the trusted Windows operator desktop with the new Ararra release
   installed, verify the two original folder IDs and the backup folder ID.
   To test whether the original **desktop token** already sees all three,
   run PowerShell (owner's original token is not exported or overwritten):

   ```powershell
   .\scripts\connect-google-drive.ps1 -ClientJson 'C:\private\oauth-desktop.json' -IncludeBackupFolder -UseExistingToken -UseOriginalToken
   ```

   If this fails, perform explicit `drive.file` owner consent for
   **all three** folders (original sources, original translations,
   `Эрида/Резервные копии`), not just the newly added backup folder:

   ```powershell
   .\scripts\connect-google-drive.ps1 -ClientJson 'C:\private\oauth-desktop.json' -IncludeBackupFolder
   ```

   A **new** local candidate is created at
   `%LOCALAPPDATA%\ReadEra\drive-owner-refresh-token-backup-candidate.txt`.
   The original `drive-owner-refresh-token.txt` is left unchanged.
   Re-running consent **never overwrites** the candidate. To recheck that
   candidate without consent, use
   `-IncludeBackupFolder -UseExistingToken` (without `-UseOriginalToken`).
   ReadEra rejects callbacks missing any selected folder, duplicate IDs
   or a folder outside this approved set.
3. Consent and `drive-smoke --backup-folder-id` both check all three
   folders through the **same** app OAuth token and never create files in
   backup-preflight mode. Keep the old VPS credential active until an operator
   accepts candidate results on the same target account, securely stages the
   new protected refresh token **out of band**, verifies that existing book
   source/translation exports still work, and has a rollback plan. Creating
   multiple Google refresh tokens can invalidate an old token when provider
   limits are reached; always verify the existing token after migration.
   Never include token bytes in screenshots, shell history, Notion, chat,
   CI artifacts, or the Google backup folder.

**This is not an automatic authorization process.** The repository contains
code and instructions, but a real `drive.file` picker consent must be
performed by the Google account owner; neither GitHub CI nor ChatGPT's
Drive connector can impersonate the ReadEra desktop OAuth grant.

## Separate recovery keys — required before enabling

There are **two distinct secrets**, neither of which may be placed in the Drive backup folder:

- `backup_rbe_key`: exactly 32 random **binary** bytes in a root-owned 0700 private directory, key file 0600. This opens the `.rbe`.
- `gemini_vault_key`: the **existing** Base64 systemd credential needed to decrypt moderator personal Gemini projects after the SQLite is restored. Never regenerate it to "repair" old ciphertext.

Team credentials and Google OAuth may also need their own protected operator copy. Make an **independently recoverable, offline encrypted escrow** of both decryption keys, with tested access by the operator following complete VPS loss. An encryption key only on the VPS does not meet this requirement. Do not put it in this shared Google Drive root, source repo, Notion, CI secrets/logs or this chat.

## Operator setup (deliberately NOT executed by CI)

After accepting exact-source GitHub CI, the rootless VPS stage, and the relevant release pin, an authorized operator on the server must:

1. Confirm API and worker are stable, Reader health is unchanged, `MemAvailable >=320 MiB`, adequate scratch disk and a rollback path. Do **not** use `install=YES` as an implicit backup enabler. The `ops_backup_drive` module must actually be present in `/opt/chaptera-translator/current/venv`.
2. Create `/etc/chaptera-translator/backup` with root:root 0700. Generate (only once) a private 32-byte RBE key using `python -m chaptera_server.ops_backup_crypto generate-key --path /etc/chaptera-translator/backup/backup_rbe_key` as root, or install an already-escrowed 32-byte key. Confirm root:root 0600, then independently escrow and test recovery without printing key bytes. Never overwrite an existing key.
3. Create root:root 0600 `/etc/chaptera-translator/backup-drive.env`, containing exactly this one line:

   ```ini
   CHAPTERA_BACKUP_DRIVE_FOLDER_ID=1ll0rsERY7kpdMm8rQQVDAFcdx7_gihtl
   ```

4. **Probe the existing ReadEra OAuth separately.** The ChatGPT Google Drive connector that created this folder is **not** the same OAuth grant as the long-lived ReadEra desktop-app `drive.file` credentials. Seeing the folder in ChatGPT does **not** establish that the VPS app can access it. A no-write test must run with the VPS protected three Drive credentials via systemd LoadCredential:

   ```sh
   sudo systemd-run --wait --pipe --collect \
     --property=User=chaptera-translator \
     --property=Group=chaptera-translator \
     --property=LoadCredential=google_drive_client_id:/etc/chaptera-translator/google-drive/google_drive_client_id \
     --property=LoadCredential=google_drive_client_secret:/etc/chaptera-translator/google-drive/google_drive_client_secret \
     --property=LoadCredential=google_drive_refresh_token:/etc/chaptera-translator/google-drive/google_drive_refresh_token \
     /opt/chaptera-translator/current/venv/bin/python \
       -m chaptera_server.ops_backup_drive --probe-folder \
       --folder-id 1ll0rsERY7kpdMm8rQQVDAFcdx7_gihtl
   ```

   Require `drive_backup_folder_access=PASS`. If rejected, **STOP**. The owner must explicitly select/share the new destination with the same ReadEra desktop OAuth client through a reviewed Google Picker consent flow (preserving existing chapter access). Do not broaden OAuth scopes or silently reauthorize.

5. Independently copy the 0700/0600 root-reviewed service, timer and installer files into a **root-owned 0700 immutable staging directory**; never run an SSH user's mutable copy as root. The installer `install-backup-drive-units.sh` places units and private scratch directory, prints `drive_backup_units=installed_inert`, and **never** enables or starts a timer.
6. Only after escrow, successful read-only OAuth probe and operator-approved dry-run checks, install an explicit root-owned marker `/etc/chaptera-translator/backup-drive-enabled` (0600). Run the oneshot once through `systemctl start chaptera-translator-backup-drive.service`. Verify its redacted log `drive_encrypted_backup=PASS`, actual new `.rbe` in the chosen Drive folder, Google-side bytes/readback SHA, Reader and API health, and **no keys or plaintext** in Drive.
7. Enable daily backups explicitly: `systemctl enable --now chaptera-translator-backup-drive.timer`. Default: **03:30 UTC**, with up to 30 minutes random delay, `Persistent=true` for missed runs. Check journal errors/last successful run and Drive quota regularly. Disable safely with `systemctl disable --now chaptera-translator-backup-drive.timer` and remove the opt-in marker.

No systemd restart of API/worker is required for this dedicated timer. Merely merging GitHub PRs does **not** perform steps 1–7.

## Real recovery acceptance (separate from unit tests)

On a different operator-controlled host, download an actual ciphertext `.rbe` from the Drive folder, verify original Drive SHA/byte-count evidence, recover the separately escrowed binary RBE key, and run:

```sh
python -m chaptera_server.ops_backup_crypto unseal \
  --archive /private/received/<verified-archive>.sqlite3.rbe \
  --key-file /private/escrow/backup_rbe_key \
  --destination /private/offline-restore/jobs.sqlite3
python -m chaptera_server.ops_backup_vault \
  --database /private/offline-restore/jobs.sqlite3 \
  --vault-key-file /private/escrow/gemini_vault_key
```

Verify the books, accepted texts, source revisions, job queue and account/session state without printing private contents. Log exact source and site SHA, provider/Drive object identity, anonymized counts, operator approver, key custody and restore duration. Do **not** replace or restart the live database during the drill. These tests plus real restore evidence are needed before closing [ararra #56](https://github.com/Lalalalendia/ararra/issues/56).

**Current state (2026-10-20):** Drive folder created; Ararra encrypted Drive transport CI accepted as [PR #92](https://github.com/Lalalalendia/ararra/pull/92). Timer/unit code is prepared for GitHub review. A real production off-host backup is **not yet confirmed** and the timer is **not enabled**.
