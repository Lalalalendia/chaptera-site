# RE-01: Erida private HTTPS pilot on the existing Chaptera VPS

**Scope:** only `erida.chaptera.online` and loopback `127.0.0.1:8091`. Do not edit the
Chaptera landing or Cloud Reader virtual hosts, the existing Python systemd units,
or firewall exposure for port 8091. Two reviewable Nginx examples are in `nginx/`.

**Status:** deployment instructions only. The templates are not installed by CI.
The operator observed the API and worker active, Reader active, zero restarts,
`/app` HTTP 200, anonymous `/v1/jobs` HTTP 401 and 322 MiB MemAvailable
on 2026-10-18. The current margin over the 320 MiB install gate is only 2 MiB.
Do not use this pilot to infer load capacity.

## Gate 0 — DNS, prerequisites and existing config

1. Ensure `erida.chaptera.online` DNS A resolves to the **actual VPS public
   address**; if an AAAA record exists, it must also point to a reachable IPv6
   address on this VPS or be removed. Operator must control this DNS record.
2. As root, inspect `nginx -T` and verify that
   `/etc/nginx/conf.d/*.conf` is included **inside** the Nginx `http` block.
   Abort if this layout differs. Save current `nginx -T` output privately
   (do not publish private vhost settings), and record current Reader health.
3. Ensure Nginx, Certbot and `htpasswd` (bcrypt, usually `apache2-utils`)
   are available. Do not create a global Gemini key or use root for application
   processes. Confirm `ss -lntp '( sport = :8091 )'` reports **only**
   `127.0.0.1:8091`.

## Gate 1 — HTTP ACME only (no app access)

Review `nginx/erida-http-acme.conf.example` in the trusted repository.
Copy the reviewed example to the VPS through the operator's authenticated
transfer method (the chaptera-site GitHub repository is **private**; anonymous
`raw.githubusercontent.com` access must not be assumed). Only root may write
the destination. On the VPS:

```bash
install -d -o root -g root -m 0755 /var/www/erida-acme
install -m 0644 /path/to/reviewed/erida-http-acme.conf.example /etc/nginx/conf.d/erida-http.conf
nginx -t && systemctl reload nginx
```

This host returns 404 for every request other than the ACME HTTP-01 challenge.
Verify existing `chaptera.online` and `reader.chaptera.online` still work.
When DNS has propagated and inbound TCP 80 serves the new host:

```bash
certbot certonly --webroot -w /var/www/erida-acme -d erida.chaptera.online
```

Use an administrator-controlled renewal email/consent. The certificate must
exist at both `/etc/letsencrypt/live/erida.chaptera.online/fullchain.pem`
and `privkey.pem`. Do not enable the TLS config before this point.

## Gate 2 — Bcrypt pilot perimeter + TLS

Create a **unique** operator Basic Auth password in the terminal, never
pasting the password into GitHub, Notion, or this chat:

```bash
htpasswd -c -B /etc/nginx/erida-pilot.htpasswd erida-ops
chown root:www-data /etc/nginx/erida-pilot.htpasswd
chmod 0640 /etc/nginx/erida-pilot.htpasswd
```

Use the actual Nginx worker group instead of `www-data` on systems that
configure another one.

Review `nginx/erida-https-private.conf.example`; copy to VPS then:

```bash
install -m 0644 /path/to/reviewed/erida-https-private.conf.example /etc/nginx/conf.d/erida-https.conf
nginx -t && systemctl reload nginx
```

The new vhost has a *separate hostname*, valid TLS, short pilot HSTS, Basic
Auth, per-IP edge rate limiting, stricter login endpoints, sanitized
forwarded headers and **no** proxying on plaintext HTTP. It forwards to the
unchanged local application port. It strips the perimeter
`Authorization` header before proxying, since Ararra's legacy API clients
use `X-API-Key` and its browser clients use a secure cookie. It does not
touch other vhosts.

## Gate 3 — evidence, recovery and limits

```bash
nginx -t
curl -fsS http://127.0.0.1:8091/healthz
curl -sS -o /dev/null -w '%{http_code}\n' https://erida.chaptera.online/app
curl -sS -o /dev/null -w '%{http_code}\n' http://erida.chaptera.online/app
systemctl is-active chaptera-reader.service
systemctl is-active chaptera-translator-api.service
systemctl is-active chaptera-translator-worker.service
```

Expected unauthenticated **HTTPS** result is 401 from Nginx Basic Auth;
expected plain HTTP is 404. Through the browser, after passing perimeter
Basic Auth, the normal Ararra closed-team login page must appear. Test both
initial login and logout with a dedicated operator team token or password
(not in shell logs), then `/app/cabinet` and real authenticated session
logout. Check no API key, moderator key or cookie entered in Nginx logs.

Check `systemctl show ... -p NRestarts -p MemoryCurrent` and
`MemAvailable` again; maintain Reader health and don't lower memory gates.
Check `certbot renew --dry-run` and configure a reviewed cert renewal
deploy hook that reloads Nginx (without restarting Reader or translator).
Store trusted secrets and encrypted off-host backups independently.

### Known release limitation: client-IP inside the app

Ararra explicitly disables Uvicorn's proxy header processing, so Nginx's
`X-Real-IP` / `X-Forwarded-For` headers **do not yet give the application a
trusted individual client IP**. Its SQLite login throttle may see all
visitors as `127.0.0.1`, causing shared lockouts. The Nginx edge applies
real per-IP limits, while Basic Auth restricts this pilot. **Do not declare
general team/public ingress accepted on these controls alone.** Proper
bounded trusted-peer client-IP extraction and regression tests are a
separate application change; remove the Basic Auth perimeter only after
that acceptance plus encrypted offsite backup/restore and session tests.

### Rollback

If Nginx configuration fails, do not reload. If the new vhost causes errors,
disable only `/etc/nginx/conf.d/erida-https.conf`, run `nginx -t`, then
`systemctl reload nginx`. Never modify/remove the Reader and landing
vhosts. Leave the private loopback API and worker running for investigation.
