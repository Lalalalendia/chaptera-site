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

The browser Reader URL is already wired to `https://reader.chaptera.online`, but the landing remains fail-closed until physical Reader acceptance is green:

- `cloud_reader_available = false`
- `cloud_reader_privacy_ready = false`

This allows the v2 marketing surface to ship independently without exposing a backend that has not completed physical acceptance.

## Workflows

- `validate.yml` runs on every push/PR and verifies the reconstructed archive hash, JSON, JavaScript syntax, v2 config gates, domain and Reader sitemap route.
- `deploy.yml` performs the production release to FirstVDS and is manually dispatched.
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
