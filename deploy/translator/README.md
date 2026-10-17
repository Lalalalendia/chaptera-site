# Private Ararra translator deployment — VPS

This is a dedicated service deployment, **not** a public Chaptera site release.
It never changes Reader binaries, Nginx, the landing, or the Reader database.

## Verified baseline

- Pinned Ararra main SHA: `a7e50873bb90a0263876e1329db946ae485932d6`, wheel `0.6.2`.
- Gemini `gemini-3.8-flash`: a real, synthetic translation on the VPS passed structural QA and SQLite persistence.
- VPS: Python 3.12, 891 MiB RAM, approximately 354 MiB MemAvailable at last probe, existing Reader service and ~2 GiB swap.
- SSH deploy user has no general sudo or Docker access.
- API is bound only to `127.0.0.1:8091`. One SQLite worker only.
- Bootstrap creates a single host administrator called `operator` in the protected
  `team_tokens_json` credential. The API unit explicitly sets
  `CHAPTERA_ADMIN_MEMBER_ID=operator`: without it ReadEra's administrative
  member-management endpoints would remain inaccessible. No public
  registration, no additional roles.
- This pinned revision includes SQLite browser sessions and Argon2id moderator
  passwords in addition to the existing API key protocol. A browser frontend
  still requires a separately reviewed HTTPS/trusted-proxy ingress. **Do not
  expose port 8091 publicly** or assume the unit file makes the UI reachable
  outside the host.

## Step 1 — automatic, nonmutating staging

A merge changing `.github/workflows/translator-service.yml` or its service
install files runs a **two-job** GitHub Actions pipeline. The first job checks
the exact pinned GitHub source and tests, then builds a SHA-256-verified offline
wheelhouse. The second uses protected production SSH to stage the archive and
the installation scripts under:

`~/chaptera-translator-incoming/a7e50873bb90a0263876e1329db946ae485932d6/`

The stage job also installs the verified wheelhouse into a **temporary** user-owned
virtual environment on the VPS, then executes `html_v0` and `atoms_v1` mock
Gemini → worker → SQLite smoke tests. It removes the temporary installation
afterwards. If less than 280 MiB memory is available, staging fails closed.
**No Gemini credential, external generateContent request, permanent API or
systemd mutation is involved.**

### Real-chapter offline stress gate

The staging workflow also fetches Chapter 086 of the existing
`Lalalalendia/med` Fanqie corpus, pinned to commit
`5046ff53207ce2fc89fb83277d9ceec1fee30935` and Git blob
`db53f9b07821d4a28ba35badb0da362613a39e50`. It validates the hash
before transferring the chapter, then runs the real chapter (not a short
synthetic phrase) through the packaged `TranslationWorker`, both transports,
`GeminiProvider` with a **strict local MockTransport**, deterministic QA and
a disposable SQLite database.

The mock replaces Chinese characters with Cyrillic placeholders; **this is
not a real translation and cannot establish literary quality**. Only counts,
transport status, elapsed time and peak process RSS are reported. No source,
prompt, simulated output or secret is printed or uploaded as an artifact.
The temporary source is deleted on exit. If source identity changes,
transport QA rejects the response, the request budget is exceeded, or
available memory is insufficient, the gated workflow fails before activation.

A `pull_request` runs the same source trial on GitHub runner with
no production access; a successful merge additionally performs the trial on
the actual VPS. Actual paid full-chapter Gemini evaluation remains a
**separate manual operation** requiring explicit limits and review.

## Optional before bootstrap: real Gemini Chapter 086 pilot

An independent [manual full-chapter pilot workflow](../../.github/workflows/translator-full-chapter-pilot.yml)
can exercise a real book chapter on the already verified rootless VPS environment.
It **does not install or start permanent services** and is not part of staging.

To authorize **exactly one potentially billable** request, deliberately dispatch
`main` with `authorize_billable=YES`. The default `NO` never calls Gemini.
The entire pinned Chinese Chapter 086 is sent to the configured
`gemini-3.8-flash` model; do not run without permission to process this text.
The source is pinned to `med@5046ff53207ce2fc89fb83277d9ceec1fee30935`,
with Git blob `db53f9b07821d4a28ba35badb0da362613a39e50`.

Guards: real-VPS Reader must be active and MemAvailable at least 320 MiB,
offline wheelhouse SHA256 verified, pinned source hash checked on runner and
again by the on-host pilot, at most **one** Gemini provider call, 30,000-character
prompt limit inherited from `MeteredProvider`, 16,384 output-token cap in
`generationConfig`, 160-second HTTP timeout, 210-second process timeout,
one SQLite attempt and no automatic retry. No permanent state or root required.

The protected Gemini key travels over authenticated SSH **stdin only**.
Source and a temporary SQLite database are removed on exit. The successful
output is a *plain-text Russian candidate* and a **redacted** technical JSON
report, delivered as a private GitHub Actions artifact with **one-day
retention**. The translation text never appears in logs. No Notion/Rulate
publication or reader/site changes are made.

**Acceptance is structural, not literary.** A successful action means one
full-size real-model response passed deterministic QA, broad Russian-language
and residual-CJK signals and persisted into disposable SQLite. Character
quality, naming, glossary consistency, translation style and factual meaning
must be reviewed manually against the source before any publication.

## Step 2 — ONE-TIME root bootstrap

An administrator must first copy the reviewed files into a **root-owned,
non-writable-by-deploy** directory and execute that independent copy. **Never
run the bootstrap script as root directly from the deploy user's home**: that
would allow replacement between review and execution. Example for the
`chaptera-deploy` SSH account (adjust the home path and account name if
different):

```bash
STAGED=/home/chaptera-deploy/chaptera-translator-incoming/a7e50873bb90a0263876e1329db946ae485932d6
sudo install -d -o root -g root -m 0700 /root/chaptera-translator-bootstrap
sudo install -o root -g root -m 0700 "$STAGED/bootstrap-host.sh" /root/chaptera-translator-bootstrap/
sudo install -o root -g root -m 0644 "$STAGED/chaptera-translator-api.service" /root/chaptera-translator-bootstrap/
sudo install -o root -g root -m 0644 "$STAGED/chaptera-translator-worker.service" /root/chaptera-translator-bootstrap/
# Review the frozen root-owned files before execution.
sudo bash /root/chaptera-translator-bootstrap/bootstrap-host.sh chaptera-deploy
```

The bootstrap creates a locked-down `chaptera-translator` system user,
root-owned systemd units, isolated `/opt/chaptera-translator` releases,
persistent `/var/lib/chaptera-translator` SQLite and private
`/etc/chaptera-translator/credentials/`. It generates a random initial team
API token without printing it. The deploy user receives sudo rights only for
start/stop/restart of the two named translator units. The units are enabled
but contain `ConditionPathExists` guards: reboot before release installation
skips them rather than repeatedly starting a missing executable.

### RE-08 encrypted recovery staging

The pinned `ararra` wheel includes `chaptera_server.ops_backup_crypto`.
The rootless VPS stage creates a **disposable** AES-256-GCM key in a
temporary 0700 directory, seals the disposable SQLite snapshot, restores
it to another disposable database, and verifies that a corrupted
authentication tag is rejected without publishing a partial database.
All temporary plaintext, ciphertext and key files are deleted on exit.
There is no production key in this operation.

This is only a local cryptographic round-trip on the actual VPS. It does
not create encrypted offsite backups, configure S3/Drive, install services,
or restore production data. See the [ReadEra recovery guide](https://github.com/Lalalalendia/ararra/blob/main/docs/RE08_SQLITE_RECOVERY.md)
and [acceptance issue #56](https://github.com/Lalalalendia/ararra/issues/56).

The rootless VPS staged test additionally validates
`chaptera_server.ops_backup` against a disposable SQLite database: online
snapshot, verification and isolated restore. It does NOT touch the real
`/var/lib/chaptera-translator/jobs.sqlite3`. Genuine off-host encrypted
backups and a witnessed recovery remain separate RE-08 acceptance gates.

The worker has `MemoryHigh=160M` and `MemoryMax=240M`; API has
`MemoryHigh=112M` and `MemoryMax=160M`. Installation refuses to start the
permanent processes when available memory is below **320 MiB**. These are
protective caps and a one-time headroom check, **not** proof that large chapters
fit this VPS or that the Reader cannot experience memory pressure.

## Step 3 — activate manually, without paid Gemini calls

Open [Translator stage/deploy workflow](../../.github/workflows/translator-service.yml)
in GitHub Actions, select `Run workflow`, `main`, and `install=YES`.

The workflow retrieves the already configured protected
`TRANSLATOR_GEMINI_API_KEY` and writes it to a mode-0600 server credential
file through pinned SSH. `systemd LoadCredential` delivers it only to the
worker; API receives the separate team-token credential. Secrets never go into
GitHub source or systemd unit environment variables.

The release is installed in an isolated Python environment without system
`python3.12-venv`, the `current` symlink is switched atomically, and **only
translator API/worker** are restarted. A failed health check triggers rollback.

## Acceptance checks

```bash
systemctl is-active chaptera-translator-api.service
systemctl is-active chaptera-translator-worker.service
curl --noproxy '*' -fsS http://127.0.0.1:8091/healthz
curl --noproxy '*' -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8091/v1/jobs
# Last line must print 401: member API token required.
```

The worker listens to the SQLite queue and uses the verified Gemini 3.8 model.
No automatic real Gemini request or full-book translation is started by the
deployment. Do not expose port 8091 publicly. The pinned version already has
revocable browser sessions, closed-team Argon2id moderator passwords and
local per-peer/member rate limiting; these do NOT imply that Nginx HTTPS,
trusted client IP, secure backup/restore, or operator-reviewed production
acceptance are complete. Keep the single-worker, private loopback boundary.
A full chapter requires a separate explicitly bounded pilot.
