# Erida MVP: consent-only Google Drive exporter (INERT)

This is a deployment template, not approval to activate it. The original
chaptera-translator-drive-export.service and timer are untouched. The
new chaptera-translator-mvp-drive-export.service runs:
    chaptera-server drive-outbox --run-once --allow-drive-write --consented-only

It therefore selects only durable jobs belonging to translation batches with
an explicit user request for Drive delivery. The installed Ararra wheel must
include PR #143 (user consent and consented-only CLI) and PR #144 (readable
UTF-8 separate chapter TXT), both merged. A GitHub commit is not evidence
of the active VPS release.

## Two independent operator gates

1. After real pilot and owner approval, a privileged operator enables the
   production SQLite Drive export policy on the configured translator database.
2. Root creates /etc/chaptera-translator/mvp-drive-export-enabled and only then
   enables the dedicated timer.

The root-owned drive-export.env must set an owner-approved shared Drive root.
The service loads existing root-only Google OAuth credentials with systemd
LoadCredential. They are never passed to the web API or Gemini worker.

The legacy chaptera-translator-drive-export.timer MUST stay disabled and its
/etc/chaptera-translator/drive-export-enabled marker MUST be absent. The
legacy selector does not enforce per-batch user consent. The new service
independently refuses to start while the legacy marker exists.

## Frozen one-time installation, never automatic activation

Copy the installer and two units to a reviewed, immutable root-owned staging
directory: the directory has mode 0700, the installer 0700, both units 0644.
Before use, review all three files and verify syntax using bash -n and
systemd-analyze verify. Run the installer as root only from that frozen copy.
It checks existing root bootstrap/credential metadata, legacy timer inactivity,
root marker absence, and existing unit identity. It copies two units to
/etc/systemd/system and calls only systemctl daemon-reload.

It never enables, starts or restarts any service, reads contents of OAuth
secrets, touches production SQLite, or sends a Gemini/Google request.
GitHub CI only tests inert unit syntax, not real installation.

## Live acceptance and rollback (NOT carried out by CI)

A separate operator must approve real Drive root/OAuth, backups and one
real user TXT -> Gemini -> N separate Drive translation TXT file pilot.
Only then may the operator enable the policy, create the new root marker,
and enable the consent-only timer. One oneshot claims at most one job each
activation; uncertain remote writes remain HOLD until reviewed and cannot
be automatically retried/overwritten.

Rollback disables the new timer and policy, removes its root marker, and
leaves prior OAuth, the SQLite journal and Google files intact. Never delete
remote files as an implicit rollback.
