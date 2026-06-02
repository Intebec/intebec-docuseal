# Per-client brand images

One folder per client, holding that client's logo + favicons. These files are
**gitignored** (like `config/clients/`), so client branding never lands in
version control. Only this README and `.keep` are committed.

```
public/brands/
  parcours/
    logo.svg
    favicon.svg
    favicon.ico
    favicon-16x16.png
    favicon-32x32.png
    favicon-96x96.png
    apple-icon-180x180.png
    preview.png
  intebec/
    logo.svg
    ...
```

## How a client picks up its images

Each client config (`config/clients/<name>.yml`) points its `assets:` paths at
its own folder — the path *is* a URL served from `public/`:

```yaml
assets:
  logo_path:        "/brands/parcours/logo.svg"
  favicon_svg:      "/brands/parcours/favicon.svg"
  favicon_ico:      "/brands/parcours/favicon.ico"
  favicon_16:       "/brands/parcours/favicon-16x16.png"
  favicon_32:       "/brands/parcours/favicon-32x32.png"
  favicon_96:       "/brands/parcours/favicon-96x96.png"
  apple_touch_icon: "/brands/parcours/apple-icon-180x180.png"
  preview_image:    "/brands/parcours/preview.png"
```

Switching client (`bin/use-client parcours`) changes the config, which changes
the paths, which changes the images. No file swapping.

## Development

Just drop each client's images in `public/brands/<client>/`. Rails serves
`public/` in dev, so `/brands/<client>/logo.svg` works immediately. Restart not
required for images (only for config changes).

## Production

`public/brands/*` is gitignored, so it is **not** baked into the Docker image.
`docker-compose.yml` mounts the brands directory into the container instead
(`./public/brands` → `/app/public/brands`, read-only). As long as the deployed
client's folder exists there, its `/brands/<client>/...` paths resolve:

```bash
INTEBEC_CONFIG_FILE=./config/clients/parcours.yml docker compose up -d
```

If the brand images live somewhere else on the host, point `INTEBEC_BRAND_DIR`
at the directory that contains the client subfolder(s):

```bash
INTEBEC_CONFIG_FILE=./config/clients/parcours.yml \
INTEBEC_BRAND_DIR=/srv/intebec/brands \
docker compose up -d
```

Keep the mounted subfolder name the same as the one referenced in the config
(e.g. the config says `/brands/parcours/...`, so the folder must be `parcours/`).
