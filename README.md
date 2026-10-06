# Chaptera site

Private deployment repository for https://chaptera.online.

## Production artifact

The canonical landing bundle is stored at `site/chaptera-landing-online-ready.zip`.

Expected SHA-256:

`09dddec241ef4667de55ef6ed48678374818ac76206d79e38b451f50e6de20d8`

The bundle contains the static landing, Reader hub, privacy/FAQ/supported/report routes, and the fail-closed future Cloud Reader configuration.

## Deployment

- `validate.yml` runs on every push.
- `deploy.yml` is manual until the server SSH secrets are configured.
- After SSH secrets are installed and the first production smoke passes, enable automatic deploy on pushes to `main`.

Required Actions secrets:
- `DEPLOY_HOST`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `SSH_KNOWN_HOSTS`

Production server root: `/var/www/chaptera`.
