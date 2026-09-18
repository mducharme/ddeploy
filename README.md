# ddeploy — staging provisioner

A single CLI that provisions and deploys client sites on an Ubuntu 24.04
server using native nginx + multi-version PHP-FPM, reading each project's
`.ddev/config.yaml` as the source of truth. No containers run on staging.
Nothing in the tool is DigitalOcean-specific — the only external
dependency is Cloudflare for DNS-01 wildcard cert issuance — so it runs
unchanged on a DO droplet, Hetzner, bare metal, or any other Ubuntu 24.04
box with a public IP and root access.

Fleet-ready: the only thing that differs between droplets is
`provisioner.conf`. Standing up a new droplet is: copy this repo → edit
that one file → run `init`.

## Layout

```
provision.sh          entrypoint / subcommand dispatcher
provisioner.conf       per-droplet config — edit this after cloning
manifest                name -> repo-url for provision-all / deploy-all
templates/              nginx vhost + FPM pool templates
lib/                    implementation (sourced by provision.sh)
hooks/                  fleet-wide ops scripts, run for every site (see below)
generated/              sidecar configs + DB creds for sites without
                        .ddev/config.yaml (created on first use, not committed)
logs/                   per-site provision/deploy logs (created on first use)
```

On the droplet this repo is expected to live at
`/home/deploy/provisioner`, with sites checked out under `$SITES_ROOT`
(`provisioner.conf`, default `/home/deploy/sites`).

## Usage

```
./provision.sh init                          # once per droplet
./provision.sh provision <name> [repo-url]    # once per site
./provision.sh deploy <name>                  # the CI target
./provision.sh remove <name> [--purge-db] [--purge-files]
./provision.sh list
./provision.sh provision-all                  # everything in ./manifest
./provision.sh deploy-all
```

`init`, `provision`, `deploy`, and `remove` all require root (they write
to `/etc/nginx`, `/etc/php`, create system users, etc.) — run them with
`sudo`.

### Provisioning a site

If the repo has `.ddev/config.yaml`, `provision` reads it and proceeds
non-interactively. If it doesn't, `provision` prompts for PHP version,
docroot, DB name, hostnames, and deploy steps, then writes the answers to
`generated/<name>.yaml` (a sidecar in the same shape as a ddev config) so
subsequent runs — including `deploy` — never prompt again. For CI /
`provision-all`, skip the prompt entirely with `--non-interactive` plus
`--php`/`--docroot`/`--db`/`--hostnames`/`--deploy-cmd`.

### CMS detection

When there's no `.ddev/config.yaml`, `lib/cms.sh` looks at the checked-out
repo (`composer.json` requirements, `wp-load.php`, a `craft` binary, …) to
recognize CraftCMS, WordPress (plain or Bedrock), and Charcoal, and uses
that to seed docroot + deploy-step defaults instead of guessing one scheme
for everything:

- **interactively**: if a CMS is detected, `provision` shows what it would
  use (docroot, composer args, migrate/cache commands, DB `.env` naming
  scheme) and asks once whether to accept them — a "no" (or no detection)
  falls through to asking each field by hand, same as before detection
  existed.
- **`--non-interactive`**: detection only fills gaps — an explicit
  `--docroot` or `--deploy-cmd` always wins.

Either way the result lands in `generated/<name>.yaml` (`cms:` and
`db_env_scheme:` fields) where it can be hand-edited if detection guessed
wrong; nothing is silently unrecoverable.

`db_env_scheme` also decides where and how `lib/db.sh` writes credentials:

- `laravel` (default, also Bedrock-style WordPress): `.env` —
  `DB_HOST`/`DB_DATABASE`/`DB_USERNAME`/`DB_PASSWORD`.
- `craft`: `.env` — `CRAFT_DB_*`.
- `charcoal`: `config/config.local.json` —
  `databases.<default_database>.{hostname,database,username,password}`.
  Verified against several real Charcoal projects (`candiac.ca`, `gkc.ca`,
  `airinuit.com`, others): the file doesn't exist in a fresh clone
  (gitignored, local/staging-only), gets created if missing, and the
  active DB key is read back from an existing `default_database` rather
  than assumed to be `"default"` (one real project uses `"mysql"`
  instead) — other keys in the file (`dev_mode`, `logger`, a `sqlite`
  fallback entry, …) are left untouched.
- `none` (plain WordPress): doesn't read DB config from `.env` at all —
  credentials are saved to a root-only `generated/<name>.dbpass` instead
  and logged once for manual entry into `wp-config.php`.

### `webserver_type` isn't a compatibility gate

Every real Charcoal project's `.ddev/config.yaml` says `webserver_type:
apache-fpm` — that's just their local DDEV container choice, not a sign
the app needs Apache-specific behavior. This stack always serves via
nginx + PHP-FPM regardless of what's declared, so `provision` no longer
errors on a non-`nginx-fpm` value (the original spec called for a hard
stop here) — it logs the declared value and moves on. If a project
actually relies on `.htaccess` rules beyond the standard front-controller
rewrite, those still need manual translation into the vhost; nothing here
detects that case.

### Custom hooks beyond `.ddev/config.yaml`

Two extension points, for two different authors:

- **Per-site, repo-committed**: an executable `.provisioner/post-provision.sh`
  and/or `.provisioner/post-deploy.sh` in the client repo, run as
  `www-<name>` after the standard hook replay (`provision` runs the
  former once, `deploy` runs the latter every time). Same trust level as
  any other `exec`/`composer` hook step — for site-specific one-offs like
  symlinking a shared path or warming a cache.
- **Fleet-wide, droplet-owned**: executable `*.sh` files under
  `hooks/post-provision.d/` and `hooks/post-deploy.d/` in this repo, run
  as root for **every** site, after everything else succeeds. For
  operator concerns — monitoring registration, Slack notifications,
  updating a reverse-proxy list — that shouldn't be up to client repos to
  trigger. See `hooks/README.md`; each directory ships a disabled
  `00-example.sh.example` to copy from.

### Isolation

Each site gets its own Linux user (`www-<name>`), its own FPM pool and
socket, and its own DB + DB user scoped to only that database. `www-data`
(nginx) can read a site's static files; no other site's user can read
across. See the build spec (below) §7 for the full model.

## Preconditions before running `init`

- Ubuntu 24.04 LTS (noble) droplet.
- Wildcard DNS for `$BASE_DOMAIN` already pointed at the droplet's IP
  (proxied through Cloudflare or not — see below, both work).
- A scoped Cloudflare API token (Zone:DNS:Edit on this droplet's zone
  only) placed at the path `provisioner.conf` names as `CF_CREDENTIALS`,
  before `init` runs.
- The shared git machine-user private key (see "Repo access" below)
  placed at the path `provisioner.conf` names as `GIT_DEPLOY_KEY`, before
  `init`/`provision` run.
- The `deploy` service user already exists and will run this tool via sudo.

### Repo access

Every `git` operation this tool runs — the initial clone in `provision`
and every `git pull` in `deploy` — authenticates with **one shared SSH
key**, from a dedicated machine-user account (a bot GitHub/GitLab/
Bitbucket account, not a personal one) added as a read-only
collaborator/team member on each client repo or org.

This is deliberately **not** GitHub's native per-repo "Deploy Key"
feature — those are hard-limited to one repository each and GitHub
rejects reusing the same public key across two of them, which doesn't
work for a fleet of many repos under one key.

Setup: generate a key pair for the machine-user account, add its
*public* key to that account, and place the *private* key on the droplet
at the path `GIT_DEPLOY_KEY` names, `chmod 600`. `init` seeds
`/etc/ssh/ssh_known_hosts` with GitHub/GitLab/Bitbucket's host keys (for
the initial clone, which runs as root); `provision`/`deploy` copy the key
plus known_hosts into each site's own `$dir/.ssh` (already that site's
`www-<name>` `$HOME`, per §7 isolation), so every subsequent `deploy`
authenticates as that site's own restricted user, not root.

### Cloudflare-proxied origins

If `$BASE_DOMAIN` is proxied through Cloudflare (orange-cloud, not just
grey-cloud DNS), set `CLOUDFLARE_PROXIED="true"` in `provisioner.conf`
(the default). `init` then:

- writes `/etc/nginx/conf.d/cloudflare-realip.conf` so nginx/PHP see the
  real visitor IP (from `CF-Connecting-IP`) instead of Cloudflare's edge
  IP for every request — otherwise every access log line and every
  `$_SERVER['REMOTE_ADDR']` in every site says "Cloudflare."
- firewalls 80/443 to Cloudflare's published ranges only (via `ufw`; SSH
  stays open from anywhere) — without this, anyone who learns the
  origin IP (DNS history, certificate transparency logs — not actually
  secret just because it's not advertised) can hit the droplet directly
  and bypass Cloudflare's proxy entirely.

Both re-fetch Cloudflare's current ranges on every `init` run (they
change occasionally) and are additive-safe: a failed fetch leaves
existing rules/config untouched rather than tearing anything down.

Also **set Cloudflare's SSL/TLS mode to "Full (strict)"** in the
dashboard once `init` has issued the origin's wildcard cert — "Flexible"
would have Cloudflare talk to the origin over plain HTTP, which this
stack doesn't serve.

Set `CLOUDFLARE_PROXIED="false"` for a droplet whose DNS is grey-cloud
(or not on Cloudflare's proxy at all) — DNS-01 cert issuance still needs
the Cloudflare API token either way, that part's unaffected by proxy
status.

## Open items from the build spec — how they were resolved here

The spec that drove this build (kept for reference below) flagged several
things as "CONFIRM AT BUILD TIME." Resolved as follows; re-verify on the
actual droplet before trusting them in production:

- **yq**: must be the Go build (mikefarah/yq), not the Python one.
  `lib/common.sh:require_yq` checks for `mikefarah` in `yq --version` and
  refuses to proceed otherwise. `init` installs it via `snap install yq`.
- **certbot Cloudflare plugin**: `python3-certbot-dns-cloudflare` via apt
  — this is the standard Debian/Ubuntu package name.
- **PHP extensions**: `provisioner.conf:PHP_EXTENSIONS` defaults to
  `cli mysql mbstring xml curl zip gd` (the spec's stated minimum).
  Adjust per what the CMS actually needs.
- **DB env var names**: resolved per-CMS via detection (see "CMS
  detection" above) rather than one fixed scheme. Charcoal's
  `config/config.local.json` convention was verified against real
  projects (see below); Craft's and Bedrock's are the frameworks'
  documented conventions, not verified against a real repo here.
- **Front-controller rewrite**: used the spec's
  `try_files $uri $uri/ /index.php?$query_string;` as given — confirm it
  matches the real CMS's routing on a real repo.
- **Interactive fallback write-back**: implemented as a sidecar
  (`generated/<name>.yaml`), never touching the client repo, per the
  spec's recommended default.
- **Baseline PHP set**: `7.4 8.1 8.2 8.3`, as given in the spec's example
  `provisioner.conf`.
- **CMS-detected CLI commands**: the Craft migrate/project-config/cache
  commands in `lib/cms.sh:cms_defaults` are the framework's documented
  defaults, not verified against a real project here — treat them as a
  starting point, same as any other detected default.

## Corrections / deviations from the spec

- The spec's name regex (`^[a-z0-9][a-z0-9-]{0,30}$`, up to 31 chars) was
  sized against "Linux's 32-char username limit," but the actual username
  is `www-<name>` — a 4-char prefix on top. At 31 chars that's a 35-char
  username, over the limit. `lib/common.sh:NAME_RE` caps names at 28
  chars instead (`^[a-z0-9][a-z0-9-]{0,27}$`), so `www-<name>` always
  fits in 32.
- The spec calls for a hard error when `webserver_type` isn't
  `nginx-fpm`. Dropped in favor of a log line (see "`webserver_type`
  isn't a compatibility gate" above) — confirmed with the project owner
  after finding it would've blocked every real Charcoal project.
- Not a spec item, but caught in testing: `lib/cloudflare.sh`'s two
  `curl` calls (ips-v4, then ips-v6) were writing straight to the same
  stream with nothing guaranteeing a newline between them — when the v4
  response's last line had no trailing newline, its last range and the
  v6 list's first range merged into one corrupted line
  (`131.0.72.0/222400:cb00::/32`). Fixed by forcing a newline after each
  fetch and filtering blank lines.

## Build spec

The full build spec this implements is preserved in the project's task
history; ask if you need it reproduced here.
