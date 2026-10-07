# Chaptera site

Private deployment repository for https://chaptera.online.

## Canonical landing artifact

Production landing is **Chaptera Landing v2**.

The exact verified archive is stored as Git-friendly Base64 chunks:

`site/artifact4k.b64.00` … `site/artifact4k.b64.04`

CI reconstructs:

`site/chaptera-landing-online-ready.zip`

and requires SHA-256:

`3e43a2582a5871f716b04be8d82403ab28f13a8d3476c007d44c133692221e79`

V2 is the product-first editorial landing: warm paper/ink/cobalt visual system, dominant Open PUB action, Reader/product proof in the hero, Windows Reader secondary route, and the existing Reader/Editor/Supported/Privacy/FAQ/Report routes.

The canonical Landing v2 ZIP remains a fail-closed base artifact. Production applies `site/production-overrides.json` after unpacking. Cloud Reader physical acceptance is now green, so the production overlay enables the browser Reader:

- `cloud_reader_url = https://reader.chaptera.online`
- `cloud_reader_available = true`
- `cloud_reader_privacy_ready = true`

Keeping the gates as a production overlay preserves the immutable v2 base artifact while ensuring future site deploys do not accidentally close an accepted Reader.

## Workflows

- `validate.yml` runs on every push/PR, reconstructs the immutable base archive, applies the production override, and verifies JSON, JavaScript syntax, live Reader gates, domain and Reader sitemap route.
- `deploy.yml` reconstructs the same base archive, applies the production override, releases to FirstVDS, and smokes both the site and public Cloud Reader.
- Reader browser/backend deployment is separate from the marketing landing release.

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
