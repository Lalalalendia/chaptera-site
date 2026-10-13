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


## Temporary PUB Editor — production consumer acceptance

The anonymous Temporary Editor V0 is served by the Rust backend deployed through
the **separate**, explicitly pinned `Deploy Cloud Reader backend` workflow.
Merging source, publishing a Linux packet or installing it on FirstVDS is **not**
a complete public release receipt.

Run [Public FirstVDS temporary editor browser acceptance](.github/workflows/public-guest-editor-acceptance.yml)
**manually** only after the protected backend deploy has successfully installed
the exact intended `rar2` release SHA. The production environment and existing
read-only SSH preflight must be authorized by the operator. Provide the immutable
40-character lowercase `release_sha`, not `main`, `latest`, a shortened SHA
or the `chaptera-site` SHA.

The workflow refuses an absent published `cloud-reader-<sha>` release and a
different `/opt/chaptera/current` symlink **before uploading anything**. It then
uses trusted public TLS at `https://reader.chaptera.online`, denies Product and
OIDC routes, and executes **two separate clean Chromium sessions** with the
public pinned Apache POI `SampleNewsletter.pub`:

- real guest upload → pointer MoveNode → exact revised Scene → download edited
  IDML (ZIP/XML NodeId and bounds) or PDF (independent painted rectangle and xref);
- reload the revised document, confirm unchanged original and non-renewing reads;
- explicitly click Delete, require HTTP 204 and verify the old bearer is revoked.

Only the **source-free** SHA/geometry/privacy summary is uploaded as an Actions
artifact; original/downloaded PUB/IDML/PDF bytes and guest access tokens are
never published. The script attempts private DELETE on failure; server TTL
remains the backstop. The job does **not** install software, change Nginx,
run an infrastructure rollback, simulate elapsed 60-minute TTL cleanup or
declare product `GO`. A final operator release decision also needs physical
TTL/sweep and rollback receipts. Changes in the upstream physical acceptance
script fail closed until this adapter is reviewed.
