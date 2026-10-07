# Chaptera Cloud Reader in chaptera-site

This directory is the deployment-owned mirror of the public Cloud Reader surface.

Source snapshot:
- upstream repository: `Lalalalendia/rar2`
- upstream commit: `5f8f32ee160fab0ec4fefbf839896e454d576e9b`

## Ownership split

`chaptera-site` owns the public deployment surface and reuses the production SSH path that already deploys `chaptera.online`.

- `app/` — the five browser runtime assets served to users.
- `deploy/` — Reader production config, Nginx/systemd templates and host/bootstrap scripts.
- `tools/` — host acceptance and isolation harness copied with the deployment packet.

The Rust backend remains built from `rar2`; this mirror deliberately does not fork the parser/server source tree.

## Public layout

The site deployment publishes the browser assets at:

```
/var/www/chaptera/current/cloud-reader/
```

This gives the existing `chaptera-site` SSH credentials ownership of the Reader web surface. The `reader.chaptera.online` Nginx vhost can serve these assets directly and proxy only `/v1/reader/*` to the loopback Rust backend.

## Sync rule

When the Reader UI changes in `rar2`, update this directory from one exact upstream commit and update the commit above. Do not hand-edit a mixed snapshot without recording the divergence.
