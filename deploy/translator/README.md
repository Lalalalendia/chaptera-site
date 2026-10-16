# Private Ararra translator deployment — VPS

This is a dedicated service deployment, **not** a public Chaptera site release.
It never changes Reader binaries, Nginx, the landing, or the Reader database.

## Verified baseline

- Pinned Ararra main SHA: `218bea25a77e1ae5010dff2840bffc911f152823`, wheel `0.6.2`.
- Gemini `gemini-3.8-flash`: a real, synthetic translation on the VPS passed structural QA and SQLite persistence.
- VPS: Python 3.12, 891 MiB RAM, approximately 354 MiB MemAvailable at last probe, existing Reader service and ~2 GiB swap.
- SSH deploy user has no general sudo or Docker access.
- API is bound only to `127.0.0.1:8091`. One SQLite worker only.

## Step 1 — automatic, nonmutating staging

A merge changing `.github/workflows/translator-service.yml` or its service
install files runs a **two-job** GitHub Actions pipeline. The first job checks
the exact pinned GitHub source and tests, then builds a SHA-256-verified offline
wheelhouse. The second uses protected production SSH to stage the archive and
the installation scripts under:

`~/chaptera-translator-incoming/218bea25a77e1ae5010dff2840bffc911f152823/`

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

## Step 2 — ONE-TIME root bootstrap

An administrator must first copy the reviewed files into a **root-owned,
non-writable-by-deploy** directory and execute that independent copy. **Never
run the bootstrap script as root directly from the deploy user's home**: that
would allow replacement between review and execution. Example for the
`chaptera-deploy` SSH account (adjust the home path and account name if
different):

```bash
STAGED=/home/chaptera-deploy/chaptera-translator-incoming/218bea25a77e1ae5010dff2840bffc911f152823
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
deployment. Do not expose port 8091 publicly: browser account sessions,
per-book ACL, quotas, backups and long-chapter capacity gates are still future
requirements. A full chapter requires a separate explicitly bounded pilot.
