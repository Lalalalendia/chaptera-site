# Chaptera site

Private deployment repository for https://chaptera.online.

## Canonical landing artifact

The exact verified landing archive is stored as Git-friendly Base64 chunks:

`site/artifact4k.b64.00` … `site/artifact4k.b64.07`

CI reconstructs:

`site/chaptera-landing-online-ready.zip`

and requires SHA-256:

`09dddec241ef4667de55ef6ed48678374818ac76206d79e38b451f50e6de20d8`

The archive contains the static landing, Reader hub, privacy/FAQ/supported/report routes, and the fail-closed future Cloud Reader configuration.

## Workflows

- `validate.yml` runs on every push/PR and verifies the reconstructed archive hash, JSON, JavaScript syntax, domain and Reader sitemap route.
- `deploy.yml` is intentionally manual until production SSH secrets are configured.
- After the first successful production smoke, it can be switched to automatic deploy on pushes to `main`.

Required Actions secrets:

- `DEPLOY_HOST`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `SSH_KNOWN_HOSTS`

Production server root: `/var/www/chaptera`.

Deployment layout:

```
/var/www/chaptera/
├── releases/<git-sha>/
└── current -> releases/<git-sha>/
```
