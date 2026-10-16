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

This action does not install or start the permanent services.

## Step 2 — ONE-TIME root bootstrap

An administrator should inspect the staged unit files and
`bootstrap-host.sh`, and then run once, as root (replace the account if the
actual SSH deploy user is different):

```bash
sudo bash /home/chaptera-deploy/chaptera-translator-incoming/218bea25a77e1ae5010dff2840bffc911f152823/bootstrap-host.sh chaptera-deploy
```

The bootstrap creates a locked-down `chaptera-translator` system user,
root-owned systemd units, isolated `/opt/chaptera-translator` releases,
persistent `/var/lib/chaptera-translator` SQLite and private
`/etc/chaptera-translator/credentials/`. It generates a random initial team
API token without printing it. The deploy user receives sudo rights only for
start/stop/restart of the two named translator units. Units are **enabled but
not started** until the release is installed.

The worker has `MemoryHigh=160M` and `MemoryMax=240M`; API has
`MemoryHigh=112M` and `MemoryMax=160M`. These are protective caps, not
proof that large chapters fit this VPS.

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
