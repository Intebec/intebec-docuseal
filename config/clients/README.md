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

## Recommended: keep configs in a private repo (submodule)

Gitignored files have no history, review, or backup. The cleaner setup is to
keep all client configs **and** brand images in a separate **private** git repo
and pull it in as a submodule at `config/whitelabel`. **Files must be flat —
`clients/<name>.yml`, not `clients/<name>/<name>.yml`.** Suggested layout:

```
clients/parcours.yml      clients/acme.yml          # the configs (flat!)
brands/parcours/...        brands/acme/...           # the per-client images
```

One-time wiring (after you create + populate the private repo):

```bash
bin/setup-whitelabel git@github.com:Intebec/intebec-whitelabel.git
bin/use-client parcours
```

`bin/setup-whitelabel` adds the submodule, initialises it, and symlinks each
client's brand images into `public/brands/` for dev.

**No env var needed.** Once `config/whitelabel/clients` exists, both the app and
`bin/use-client` auto-detect it — so a teammate just needs
`git submodule update --init --recursive` after cloning (or `git clone
--recurse-submodules`). `INTEBEC_CLIENTS_DIR` is still honoured as an explicit
override if you ever want a different location.

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
2. **`INTEBEC_CLIENT=<name>`** — loads `<clients-dir>/<name>.yml`. The clients
   dir is `INTEBEC_CLIENTS_DIR` if set, else `config/whitelabel/clients` if the
   submodule is present, else `config/clients`.
3. **`config/config.yml`** — dev/test default (the symlink `bin/use-client` flips).
4. **`/run/secrets/config.yml`** — production default.

## Validating configs

A typo no longer has to wait until a broken page to show up:

```bash
rake whitelabel:validate[config/clients/parcours.yml]   # check one file
rake whitelabel:lint                                     # check every file in the clients dir
```

The same checks run automatically at boot and log warnings/errors. To make a
**bad config fail the boot** (recommended for CI / deploy pipelines):

```bash
INTEBEC_STRICT_CONFIG=true bin/rails server
```

## Production

Production needs only **one** config. Mount the relevant client file at
`/run/secrets/config.yml` (already wired in `docker-compose.yml` via the
`INTEBEC_CONFIG_FILE` build/run variable), or set `INTEBEC_CONFIG_PATH` to its
location. No code changes are needed to deploy a different client — just point
the mount at a different file.
