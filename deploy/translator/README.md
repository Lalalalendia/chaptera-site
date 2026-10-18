# Private Ararra translator deployment — VPS

This is a dedicated service deployment, **not** a public Chaptera site release.
It never changes Reader binaries, Nginx, the landing, or the Reader database.

## Verified baseline

- Pinned Ararra main SHA: `26bb92b7c383a22de67b0c1c40535fe5f19c450f`, wheel `0.6.2`.
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

`~/chaptera-translator-incoming/26bb92b7c383a22de67b0c1c40535fe5f19c450f/`

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

## Retired shared-key diagnostics (RE-01 personal-key migration)

Historical chapter-086 Gemini pilots are already recorded in the repository's
closed PRs and Actions runs. The original manual workflows for a one-request
smoke, model listing, and the full-chapter pilot all read the former shared
`TRANSLATOR_GEMINI_API_KEY` GitHub secret; these workflows have been removed.
They must not be dispatched or reintroduced for the personal-key deployment.
The historical translation is evidence of an earlier pilot, **not** acceptance
of the new moderator-owned credential path.

Before the reviewed root bootstrap and manual service activation, continue
**offline/mock** staging only. After activation, any future billable pilot must
use an explicitly authorized moderator-owned Google-project key entered through
`/app/cabinet`, with bounded usage and human QA; never a shared Actions secret.
The CI ratchet rejects shared Gemini secret references in **all** workflows.

## Step 2 — ONE-TIME root bootstrap

An administrator must first copy the reviewed files into a **root-owned,
non-writable-by-deploy** directory and execute that independent copy. **Never
run the bootstrap script as root directly from the deploy user's home**: that
would allow replacement between review and execution. Example for the
`chaptera-deploy` SSH account (adjust the home path and account name if
different):

```bash
STAGED=/home/chaptera-deploy/chaptera-translator-incoming/26bb92b7c383a22de67b0c1c40535fe5f19c450f
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

### RE-08 S3 offsite transport in disposable staging

The pinned Ararra wheel includes the **optional** `offsite-s3` dependency,
packaged in the offline wheelhouse for operator-side use. On rootless VPS
staging, boto3's S3 service model must expose `IfNoneMatch` for PUT and
multipart Complete. The stage then exercises encrypted upload/readback and
download/unseal against an **in-memory fake S3**, not a real bucket.
The ephemeral AES key, temporary SQLite and fake data are removed after
the smoke run. No production S3 credentials or cloud network requests exist
in this test.

Passing this check does NOT mean a real off-host copy exists. The bucket,
credentials, versioning/retention, key escrow, scheduled backup and
independent-host recovery still require an approved operator workflow:
[ararra #56](https://github.com/Lalalalendia/ararra/issues/56).

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

The personal-key release does **not** use a shared `TRANSLATOR_GEMINI_API_KEY`
or copy any global Gemini key over SSH. After **operator-approved** bootstrap,
both API and the single worker receive the same private `gemini_vault_key`
through `systemd LoadCredential`. API additionally receives the protected
team token. Moderators enter their own Google-project keys under
`/app/cabinet`; a moderator without a key has queued chapters, **not**
billable requests. No paid Gemini call is made by this installation workflow.

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


### RE-06: Gemini-ключи модераторов через личный кабинет

Однократный **утверждённый root bootstrap** генерирует отдельно от SQLite
случайный 32-байтный `gemini_vault_key` (base64) в owner-only файле.
Системные API и worker получают его через `LoadCredential`; он стабилен
между выпусками и не выводится в stdout/GitHub. При утрате master key
модераторские ключи в SQLite не расшифровать. Никогда не ротировать master
автоматически.

Личный кабинет `/app/cabinet` добавляет, заменяет и удаляет ключи
собственных Google-проектов (правило **1 проект = 1 ключ**). API хранит
AES-256-GCM ciphertext, а worker использует только ключ владельца главы;
участники без ключа ожидают в SQLite без платных попыток.
**В новом выпуске общий `gemini_api_key` не требуется**, не передаётся
через GitHub Actions и не загружается systemd worker. Для отката на старый
shared-key выпуск потребуется **отдельная санкционированная процедура
возврата legacy credential/unit**, а не автоматическая подмена личных
ключей общим.

Не включать Nginx/public API и не делать платный пилот автоматически.
Блокер root bootstrap [#46](https://github.com/Lalalalendia/chaptera-site/issues/46)
остаётся до фактического санкционированного выполнения.

### RE-01-PERSONAL-ONLY-CREDENTIAL-01 — one worker, zero shared Gemini keys

The current deployment pin, wheelhouse and VPS staging use
`ararra@a8b7994d078bdd1b47442202f13688e5d8cb0ce8`.
**Exactly one Google project has exactly one saved moderator key.**
The root bootstrap creates the stable `gemini_vault_key`; both services
load that vault, and no `TRANSLATOR_GEMINI_API_KEY` secret is required
in GitHub or on the host. Staging uses only disposable synthetic keys.

Required operator acceptance is unchanged: one reviewed root-owned
bootstrap, `MemAvailable >=320 MiB`, explicit protected
`workflow_dispatch install=YES`, loopback-only port 8091, healthy Reader,
and later independently reviewed HTTPS/client-IP proxy.
The automated push workflow always stages **without** installing.

### RE-01 release pin acceptance — 2026-10-18

The staged release pin was updated to the exact merged `ararra@a8b7994d078bdd1b47442202f13688e5d8cb0ce8` (`RE-06C` batch selection/queue plus `RE-09A` manual Drive export/OAuth). The workflow guards require those modules in the *pinned wheel source*, not merely in the latest upstream main. This is a stage/CI update only; it does not alter the permanent VPS services.

Before an operator performs the one-time reviewed root-owned bootstrap, verify the preflight and the exact-head two-job `translator-service` CI (build plus rootless VPS stage). Bootstrap copies must remain root-owned and immutable to the SSH deploy principal. Subsequent `install=YES` is separately approved and must pass the existing Reader/memory/loopback gates. Do not assume package/CI success proves an installed service. Personal moderator Gemini keys remain required; no paid Gemini calls and no public Nginx/HTTPS exposure are authorized by this pin.

## Step 4 — separately approved private HTTPS browser pilot

After confirming the installed API stays on loopback, Reader is stable and
the operator has approved a new DNS record, use the isolated
[Erida private HTTPS ingress guide](HTTPS_INGRESS.md) and the two reviewed
`nginx/erida-*.conf.example` files. They create a separate
`erida.chaptera.online` vhost protected by TLS, unique bcrypt HTTP Basic
Auth and Nginx edge limits. The plaintext vhost serves **ACME only**, not
the translator; no existing landing/Reader vhost may be changed.

This remains a **restricted operator pilot**, not public/team production:
Ararra's internal login throttle still sees the Nginx peer, and a real
client-IP trusted-proxy boundary, off-host encrypted backup/restore and browser
acceptance are outstanding. Do not open port 8091 or remove the pilot perimeter
until the separate gates pass. The CI syntax validator never contacts the
production VPS and cannot enable the ingress by itself.

### RE-03 KEY ONLY release acceptance — 2026-10-18

**Current release pin:** `ararra@26bb92b7c383a22de67b0c1c40535fe5f19c450f`, merged as
[Ararra PR #75](https://github.com/Lalalalendia/ararra/pull/75).
The prior `a8b7994d` pin references below this section are historical
checkpoints and must NOT be used for new installation.

- One moderator = one revocable random key. A moderator signs in via that key
  once, then receives a Secure/HttpOnly browser cookie. UI has no password
  selector/first-time reset, and the API refuses the three former password
  endpoints. Historical tables remain intact for rollback and backups.
- New private server release trusts forwarded client IP only from the local
  Nginx hop. The key-only vhost **overwrites** forwarded IP with
  `$remote_addr` and applies per-client admission on `/v1/session`.
- To activate: ensure latest release CI and rootless VPS stage pass,
  verify Reader active and `MemAvailable>=320 MiB`, then explicitly dispatch
  `translator-service.yml` on `main` with `install=YES`. This is manual,
  never a merge-side automatic deployment.
- Only **AFTER** key-only API+worker are installed and healthy, operator
  reviews [HTTPS_INGRESS.md](HTTPS_INGRESS.md) Gate 4 and replaces only
  Erida's HTTPS vhost with the key-only example. Do not add a second vhost,
  touch Reader/landing or open port 8091. Roll back just the Erida vhost
  to its saved Basic Auth copy if tests fail.
- Old password login no longer works. Firegod's *team key* remains valid;
  if the key was not retained, admin uses «Перевыпустить» once in Team.
  Never reveal keys/credential values in GitHub, Notion, logs or chat.

Public team-production acceptance (off-host restore/recovery, memory headroom,
client-IP E2E and user workflow QA) remains a separate gate.

### RE-03 minimal anonymous screen — release acceptance 2026-10-18

**Latest pinned release:** `ararra@657db7759155326160e0d6f9325ddca9f4a41be4`
([Ararra PR #77](https://github.com/Lalalalendia/ararra/pull/77), merged).
Earlier SHA references in this document are historical checkpoints.

Anonymous visitors to `https://erida.chaptera.online/app` see **only** a
centered key input and "Войти" button. No brand title, sidebar, project
navigation or topbar is visible until the existing Secure HttpOnly team
session is verified. On logout or failed restore, the shell disappears
again. The initial HTML is fail-closed using body auth state and CSS;
mobile direct-route navigation is positioned after the shell is revealed.
Data confidentiality still belongs to the authenticated `/v1` API
boundary, not to CSS visibility.

Release pin guards insist on fail-closed Jinja, CSS and JS; Python 3.11/3.12,
Web boundaries and real Chromium desktop/mobile tests passed in Ararra.
Rollout remains **manual**: postmerge build + rootless VPS stage first,
then operator checks Reader active and `MemAvailable >= 320 MiB`, and
explicitly triggers GitHub Actions `install=YES`. No Nginx change,
reader restart or billable Gemini calls are needed for this UI-only release.
Verify `readlink -f /opt/chaptera-translator/current` matches the new
pin and HTTPS /app renders only the one key form in an incognito window.
After legitimate key login, confirm normal sidebar/cabinet; after logout,
only the key form remains. Keep off-host backup/restore production gates.

### RE-04 compact operator workbench — 2026-10-18

**Latest release pin:** `ararra@05587830dd3614289bf2e3ff0522aba926eb8480`,
merged from [Ararra PR #78](https://github.com/Lalalalendia/ararra/pull/78).
All earlier SHAs in this document are historical.

Operator feedback from real authenticated import screen: detached oversized
logout row, tall header, cards with excess vertical whitespace, nested
source-job card and scattered controls. New release moves logout beside
the identity in a 50px account bar, reduces card/navigation/form density,
flattens background source-job controls, and makes source/URL/discover
share one desktop row (stacked responsively on mobile). Existing key-only
anonymous login, HTTP API authorization, credentials, Reader, worker,
translation queue and persisted source-job IDs are unchanged.

Acceptance: Ararra Python 3.11/3.12, Web boundaries, real Chromium 1440px +
390px regression smoke pass, including account logout bounds, import
without nested second card, source collection and mobile no-overflow.
Postmerge build + rootless stage must pass before the operator manually
triggers `translator-service.yml` on `main` with `install=YES`, but
only after verifying Reader active and MemAvailable >=320 MiB.
Nginx does NOT need modification for this UI-only release.
After install verify /opt/chaptera-translator/current points at the pin,
healthz=200, unauthenticated API=401, Reader/worker/API all active; then
refresh an authenticated /app/import and check compact toolbar and
normal import interactions. Secure HttpOnly sessions are unaffected.

### RE-03 neutral browser title before login — 2026-10-18

**Latest release pin:** `ararra@95d6319c88eeef10687a3107a7745c870ec484f2`,
from [Ararra PR #80](https://github.com/Lalalalendia/ararra/pull/80).
Older SHA references above remain historical checkpoints.

Issue: although the anonymous webpage visually showed only the key field and
submit button, the unprotected HTML `<title>РидЭра — переводческая платформа</title>`
was disclosed immediately in browser chrome before session verification.

- Initial Jinja `<title>Вход</title>` across all `/app` paths before any
  JavaScript or cookie restore can complete; no brand name in the tab/window.
- Only after the `/v1/session` team-key session passes authorization and
  content API loads, the browser tab title becomes `РидЭра — переводческая платформа`.
  Logout, invalid cookie, or session restore failure restores `Вход`.
- Python/Jinja and real Chromium 1440px/390px test: first paint, no session,
  admin/mod key, browser reload with live cookie, logout and reload. No
  changes to Nginx, TLS, Reader, credentials or persistent data.
- The public domain `erida.chaptera.online` itself still reveals the name,
  and static HTML/JS are not secrets; server-side protected API continues
  to be the security boundary.

Deployment remains manual: after the pinned build and rootless VPS stage
succeed postmerge, root operator checks Reader active and
`MemAvailable >= 320 MiB`, then explicitly runs translator-service
workflow on `main` with `install=YES`. Verify /opt/chaptera-translator/current
points to the new pin, /healthz 200, unauthenticated /v1/jobs 401, Reader
and worker active, and check private-browser tab title `Вход` before key login.
No Gemini calls or Nginx modifications required.


### RE-09A-04 — inert dedicated Drive export service (pending #81 / #79)

The owner's OAuth and real end-to-end `drive-smoke --live-smoke` have already
**PASSED directly on the VPS**. Google client ID, client secret and refresh token
are stored root-only in `/etc/chaptera-translator/google-drive/` and must
survive all future `/opt/chaptera-translator/current` release switches.
**Never request repeat OAuth consent when updating ReadEra.**

The new `chaptera-translator-drive-export.service` is a **standalone one-shot**
that loads only these three secrets via `systemd LoadCredential`, runs the
existing pinned executable with `drive-outbox --run-once --allow-drive-write`,
and uses the permanent translation SQLite. The API and Gemini worker do not get
Google credentials. The timer wakes every two minutes but is *not enabled* by
the installer. Both the `drive-export-enabled` root marker and the separate
SQLite operator policy must be opted in before real writes can begin.

One-time reviewed root installation (example; adjust the staged path and use a
frozen root-owned copy, never run arbitrary deploy-user-owned scripts as root):

```bash
STAGED=/home/chaptera-deploy/chaptera-translator-incoming/f0be7180daf3e1fd3d25417ecd14590e76eda451
install -d -o root -g root -m 0700 /root/erida-drive-export-review
install -o root -g root -m 0700 "$STAGED/install-drive-export-units.sh" /root/erida-drive-export-review/
install -o root -g root -m 0644 "$STAGED/chaptera-translator-drive-export.service" /root/erida-drive-export-review/
install -o root -g root -m 0644 "$STAGED/chaptera-translator-drive-export.timer" /root/erida-drive-export-review/
# Review the frozen /root/ copy, including unit ExecStart, folder IDs and credentials paths.
bash /root/erida-drive-export-review/install-drive-export-units.sh
```

Installer checks the existing root-owned OAuth credentials' **metadata only**
(mode 0700 directory, 0600 each file), refuses unexpected symlinks and changed
existing units, installs units and performs `systemctl daemon-reload`; it **does
not** enable or start anything, touch Google files, restart Reader/API/Worker or
print secret bytes. The previously installed pinned CLI will reject the new
`drive-outbox` command until PR #81 is merged, a new release is staged and
installed by the separate `install=YES` workflow. Do not activate early.

Future activation requires explicit operator verification: review a real
completed chapter first with `export-drive --job-id <id> --dry-run` (no network)
and separate authorized first remote write, then use
`chaptera-server drive-outbox --enable` as the normal translator service
user against the production SQLite; only after all those gates, root creates
the `/etc/chaptera-translator/drive-export-enabled` marker and enables the
timer with `systemctl enable --now chaptera-translator-drive-export.timer`.
Rollback: disable the timer and remove the marker; then disable the SQLite
policy. **No OAuth revocation, secret rotation, or service restart** is needed.
Failed or uncertain uploads remain in HOLD until reviewed for reconciliation.

Reference: [ararra #79](https://github.com/Lalalalendia/ararra/issues/79),
[draft ararra PR #81](https://github.com/Lalalalendia/ararra/pull/81).

### RE-09A-04 exact pin — 2026-10-18

This workflow now pins the merged `ararra@f0be7180daf3e1fd3d25417ecd14590e76eda451` ([PR #81](https://github.com/Lalalalendia/ararra/pull/81)):
the durable **opt-in** Google Drive outbox and one-shot CLI. On rootless
VPS staging, the exact wheel performs a self-contained SQLite outbox proof
without Google OAuth, Google network calls, or real production data.

`chaptera-translator-drive-export.service`, its timer and a root-only reviewed
installer are copied into the deploy user's incoming staging folder for review;
**none is installed or activated** by the GitHub Actions pipeline. Permanent
VPS Google OAuth credentials in `/etc/chaptera-translator/google-drive/` are
unchanged and survive release changes. Actual export remains OFF until a
separately authorized real completed-job pilot, opt-in policy, reviewed
root marker and timer enablement.


### RE-02 source collection is a separate, **disabled** service

An optional, resource-bounded service template
[chaptera-translator-source-worker.service](chaptera-translator-source-worker.service)
and the reviewed [source-worker runbook](SOURCE_WORKER.md) are available.
They are intentionally NOT part of bootstrap-host.sh, install-release.sh,
translator-service.yml, automatic service restart or production sudoers.

The API and Gemini worker can remain healthy while bulk original-source
collection is disabled. Source-worker requires the pinned process-shared
source request limiter, independent site permissions/robots acceptance,
offsite restore and substantially more free RAM/disk. The reviewed root
operator must authorize and start exactly one worker manually. No credentials
for Gemini, Drive OAuth or moderator teams may be granted to the collector.

### RE-09A-05 — shared root by moderator / book / source+translation (2026-10-19)

The exact pinned Ararra wheel is now `cbfdb2068f3759b30cbb0bcc76b51ad2ae552910`
([PR #82](https://github.com/Lalalalendia/ararra/pull/82)).
One shared Google Drive library root, `CHAPTERA_DRIVE_ROOT_FOLDER_ID`,
replaces the old two roots as the **write destination**. Nested layout:

```text
<approved shared library root>/
  <book owner member ID>/
    <book title [stable key]>/
      Источники/Глава 001.txt
      Переводы/Глава 001.txt
```

The old two configured root IDs remain available **only for read-only
preflight and legacy duplicate detection**. They are NOT new write targets.
Never copy/move existing edited Drive files automatically; migrations must
preserve original Google file/folder IDs and be operator-reviewed.

**Production activation is still forbidden without a chosen shared root.**
The dedicated Drive exporter oneshot now also checks
`ConditionPathExists=/etc/chaptera-translator/drive-export.env`, with
`EnvironmentFile=/etc/chaptera-translator/drive-export.env`. This separate
root-owned file MUST contain exactly the operator-approved
`CHAPTERA_DRIVE_ROOT_FOLDER_ID=<id>` (mode 0600, owned by root). The file
is intentionally **not created** by CI or the inert unit installer; do not
put an invented or placeholder ID into the unit. Source/translation old
folder IDs remain as legacy guards.

The site workflow only stages and verifies the wheel and frozen unit scripts.
`install=YES` is still manual and separately gated by Reader health/RAM,
and even after installation the Drive timer, SQLite export policy and
root opt-in marker are **disabled**. No OAuth credentials are regenerated,
moved or supplied to the long-lived API/Worker. If the new shared folder is
not accessible through the already connected Drive `drive.file` grant, give
this ONE folder an explicit one-time Picker authorization through the
existing OAuth client; this is not per-release reauthorization.

### RE-02 — verified originals readable by every team member (2026-10-19)

Pinned application release: `ararra@baca1c45b293edefe63a9d0eb69a965b77a955a8`
([PR #87](https://github.com/Lalalalendia/ararra/pull/87)).
Previously recorded pins in this document are historical.

- Confirmed in Python 3.11/3.12 and real Chromium: all authenticated
  moderators and admins can read previously saved, hash-verified original
  source chapters using the isolated `/v1/source-books/shared` GET router.
  Existing accepted translations and imported originals in `BookLibrary`
  were already team-readable. The source job creator is recorded in
  `collector_member_id`; it is **not** a per-book ACL or `owner_member_id`.
- Team-facing browser reader is collapsed until opened, renders external
  text with `textContent` (never injected HTML), clears on logout, and
  exposes no foreign delete/retry/cancel/import stage controls. Unverified
  chapters return no prose. Complete manuscript TXT still requires exact
  manifest + SHA-256 preview matching before downloading.
- Existing personal source job management and daily/private Gemini usage,
  credentials, import stages and Google Drive ownership remain unchanged.
- `chaptera-translator-source-worker.service` is intentionally **not**
  installed/enabled/started by this release. **No bulk site scraping**
  without site-usage permission, live acceptance, physical RAM/disk headroom
  and a tested off-host backup/restore. See Ararra issues
  [#65](https://github.com/Lalalalendia/ararra/issues/65) and
  [#83](https://github.com/Lalalalendia/ararra/issues/83).

CI workflow builds and performs transient, offline, rootless VPS staging only;
it does NOT change running services unless a root operator later launches
`translator-service.yml` from main with `install=YES` after Reader is
confirmed active and `MemAvailable >= 320 MiB`.
On an accepted manual activation verify the `/opt/chaptera-translator/current`
symlink points to exact Ararra SHA above; source-team GET without a team
session returns HTTP 401, `/healthz` returns 200 and Reader/API/translation
worker remain active. `source-worker` must stay disabled.
