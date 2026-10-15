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


## Release-published event-driven Reader backend deployment (opt-in)

Owner task: [CI-READER-RELEASE-EVENT-DEPLOY-01](https://app.notion.com/p/3fa32a84beec81209c73ee130de32eb5).

The protected `rar2` post-release workflow validates a successful Linux packet
published from `main`, then dispatches the exact 40-hex release SHA to this
repository's existing `deploy-reader-backend.yml` with
`release_mode=published`. The `chaptera-site` receiver **does not grant this
request release authority**: it independently verifies the GitHub Release tag,
asset digest, protected-main ancestry, and that the requested release remains
the most recently published eligible immutable packet. It also rejects an
automatic host downgrade or diverged host history. No direct SSH privileges or
Reader/PUB data leave this repository; all production deployment still runs in
the existing `production` environment and retains the previous release pointer,
real PUB acceptance and independent public Chromium PDF/IDML proof.

Credentials are an explicit administrative prerequisite in **rar2 only**:
create/install a dedicated GitHub App with **Actions:write** on
`Lalalalendia/chaptera-site` (avoid broad repo Content writes), and configure
`CHAPTERA_DEPLOY_APP_CLIENT_ID` as a repository variable and
`CHAPTERA_DEPLOY_APP_PRIVATE_KEY` as a protected secret. The sender uses a
short-lived, one-repository installation token; without these settings it
emits a warning and the **existing cron remains the only automatic fallback**.
The code/PR alone must not be called an operational event-driven cutover.

An explicit `workflow_dispatch` with `release_mode=manual` (default) and
`release_sha` remains the **only** path for intentional operator rollback or
same-SHA reinstall. A `release_mode=published` dispatch is not a rollback.
The cron `*/10` fallback and rollback-aware deploy bridge stay unchanged.
Measure release `published_at` → host `current` identity → public acceptance
against the first real release after the app is provisioned; do not extrapolate
release latency from unit tests.

For rollback isolation, the site receiver explicitly denies `release_mode=manual`
when `GITHUB_ACTOR` identifies a bot. Thus the delegated GitHub App token
cannot turn its automatic published-event authority into an intentional
operator rollback, even though both modes share GitHub's Actions endpoint.
