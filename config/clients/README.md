# Per-client white-label configs

Drop **one YAML file per client** in this directory, e.g.:

```
config/clients/parcours.yml
config/clients/acme.yml
config/clients/beta-corp.yml
```

These files are **gitignored** (see `.gitignore`) so client branding never
lands in version control. Only this README and `.keep` are committed. Start
from the documented template at [`config/config.example.yml`](../config.example.yml):

```bash
cp config/config.example.yml config/clients/parcours.yml
```

## Switching client in development

Use the helper script — it symlinks `config/config.yml` to the chosen client
file (and `config/config.yml` is the dev default the app loads):

```bash
bin/use-client parcours      # activate clients/parcours.yml
bin/use-client --list        # list available client configs + show active one
bin/use-client --current     # show which client is active
bin/use-client --clear       # remove the symlink (back to no config)
```

Then restart the server — the config is read and cached at boot:

```bash
bin/rails server
```

### One-off without switching

To boot a specific client without touching the symlink:

```bash
INTEBEC_CLIENT=acme bin/rails server
```

## How resolution works

`lib/whitelabel.rb` picks the local config file in this order (first wins):

1. **`INTEBEC_CONFIG_PATH`** — explicit absolute path. **Production uses this**
   (docker mounts the single client config at `/run/secrets/config.yml`).
2. **`INTEBEC_CLIENT=<name>`** — loads `config/clients/<name>.yml`.
3. **`config/config.yml`** — dev/test default (the symlink `bin/use-client` flips).
4. **`/run/secrets/config.yml`** — production default.

## Production

Production needs only **one** config. Mount the relevant client file at
`/run/secrets/config.yml` (already wired in `docker-compose.yml` via the
`INTEBEC_CONFIG_FILE` build/run variable), or set `INTEBEC_CONFIG_PATH` to its
location. No code changes are needed to deploy a different client — just point
the mount at a different file.
