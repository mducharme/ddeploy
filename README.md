# ddeploy

Provisions and deploys PHP sites on an Ubuntu 24.04 server: nginx + one
PHP-FPM pool per site, one Linux user per site, one MariaDB database per
site, a shared wildcard TLS cert. No containers. Each site's
`.ddev/config.yaml` is read as config, not run.

## Layout

```
provision.sh       entrypoint
provisioner.conf   per-server config, edit after cloning
manifest           name -> repo-url, used by provision-all / deploy-all
templates/         nginx vhost + FPM pool templates
lib/               implementation
hooks/             ops scripts run for every site (see hooks/README.md)
generated/         sidecar configs + DB credentials (created at runtime)
logs/              per-site provision/deploy logs (created at runtime)
```

Expected to live at `/home/deploy/provisioner`. Sites are checked out
under `$SITES_ROOT` (`provisioner.conf`, default `/home/deploy/sites`).

## Setup

1. `git clone` this repo to the server.
2. Edit `provisioner.conf` — domain, paths, PHP versions, DB creds path,
   git key path.
3. Place the Cloudflare API token at `CF_CREDENTIALS` (`chmod 600`).
4. Place the shared git SSH key at `GIT_DEPLOY_KEY` (`chmod 600`) — see
   "Git access" below.
5. `sudo ./provision.sh init`

## Commands

```
init                          set up a web server (packages, PHP, TLS, firewall)
init-db                       set up a dedicated database server
provision <name> [repo-url]   add a site
deploy <name>                 pull + run deploy steps + reload
remove <name> [--purge-db] [--purge-files]
list                          table of provisioned sites
provision-all                 provision every site in ./manifest
deploy-all                    deploy every provisioned site
backup-uploads [name]         sync upload_dirs to object storage (needs BACKUP_ENABLED=true)
```

`init`, `init-db`, `provision`, `deploy`, `remove`, `backup-uploads` need root.

## Site config resolution

`provision` resolves a site's PHP version, docroot, hostnames, and
deploy steps in this order:

1. `.ddev/config.yaml` in the repo, if present.
2. A sidecar at `generated/<name>.yaml`, if one was written by a
   previous run.
3. `--non-interactive` with `--php`/`--docroot`/`--db`/`--hostnames`/
   `--custom-domains`/`--upload-dirs`/`--deploy-cmd` flags.
4. Interactive prompts.

Paths 3 and 4 write the result to `generated/<name>.yaml`, so later runs
(including `deploy`) never need the flags/prompts again.

If no `.ddev/config.yaml` exists, `lib/cms.sh` checks the repo
(`composer.json`, `wp-load.php`, a `craft` binary) for CraftCMS,
WordPress (plain or Bedrock), or Charcoal, and uses that to fill in
docroot and deploy steps. Interactively it's shown and confirmed once;
non-interactively it only fills fields not set by a flag. Detected
values land in the sidecar and can be edited by hand.

`.ddev/config.yaml`'s `webserver_type` is read but not enforced — sites
are always served by nginx regardless of what it says.

## Custom domains

Every site gets `<name>.$BASE_DOMAIN` for free, covered by the shared
wildcard cert. A site can also have its own domain(s) — `.ddev/config.yaml`'s
`additional_fqdns`, the sidecar's own `additional_fqdns:`, or
`--custom-domains "a.com www.a.com"` non-interactively.

These aren't covered by the wildcard, so each site's custom domains get
their own certificate, issued via HTTP-01 (not the wildcard's DNS-01,
since a custom domain generally isn't on the same Cloudflare account as
`$BASE_DOMAIN`, or on Cloudflare at all). Requirements:

- DNS for the domain(s) must already point at this server before
  `provision` runs — HTTP-01 fails otherwise, `provision` logs a warning
  and leaves an HTTP-only vhost in place; re-run once DNS is live.
- All of a site's custom domains share one certificate, named after the
  first one listed.
- If the server is behind Cloudflare, these domains need their own
  orange/grey-cloud DNS record and don't inherit `$BASE_DOMAIN`'s proxy
  setup — set that up per domain as needed.

Once issued, renewal is certbot's timer, same as the wildcard.

## Database server

By default `DB_HOST` is `127.0.0.1`: `init` installs MariaDB on the same
server, and `provision`/`deploy` connect as local root over the unix
socket — no credentials file needed.

To share one MariaDB instance across multiple web servers instead, run
`init-db` on a dedicated database server (set `DB_ADMIN_CREDENTIALS` and
`DB_ALLOWED_HOSTS` — the web servers' IPs — in its `provisioner.conf`
first). It installs MariaDB, opens it to `DB_ALLOWED_HOSTS` only (via
`ufw`, port 3306; SSH stays open), and writes an admin credentials file
at `DB_ADMIN_CREDENTIALS`. Copy that file to the same path on each web
server, then on each web server's `provisioner.conf` set:

```
DB_HOST="<database server's address>"
DB_ADMIN_CREDENTIALS="<path to the copied credentials file>"
DB_GRANT_HOST="<this web server's address>"
```

`DB_GRANT_HOST` (default `localhost`) is the host each site's own DB user
is granted access from — it should match one of the entries in
`DB_ALLOWED_HOSTS` on the database server.

## Database credentials

Set by `db_env_scheme` (from CMS detection, or `db_env_scheme:` in the
sidecar):

| scheme     | written to                        | vars |
|------------|------------------------------------|------|
| `laravel`  | `.env`                             | `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` |
| `craft`    | `.env`                             | `CRAFT_DB_*` |
| `charcoal` | `config/config.local.json`         | `databases.<default_database>.{hostname,database,username,password}` |
| `none`     | nowhere (e.g. plain WordPress)     | saved to `generated/<name>.dbpass`, logged once |

`charcoal` creates `config/config.local.json` if it doesn't exist,
reuses the file's own `default_database` key if one is already set, and
leaves any other keys in the file untouched.

## Deploy hooks

`.ddev/config.yaml`'s `hooks.post-start` is replayed on every deploy, as
the site's own `www-<name>` user, under its pinned PHP version.
`exec`/`composer` steps run; `exec-host` steps are logged and skipped.
Any step referencing `ddev` or `/var/www/html` is skipped with a
warning.

Two more extension points:

- `.provisioner/post-provision.sh` / `.provisioner/post-deploy.sh` in
  the client repo — run as `www-<name>`, same as any hook step.
  `post-provision.sh` runs once after the first deploy; `post-deploy.sh`
  runs every deploy.
- `hooks/post-provision.d/*.sh` / `hooks/post-deploy.d/*.sh` in this
  repo — run as root, for every site. See `hooks/README.md`.

## Isolation

Each site: its own Linux user (`www-<name>`), its own FPM pool and
socket, its own database and DB user. Files are owned `www-<name>:www-data`,
dirs `2750`, files `640` — nginx (`www-data`) can read them, no other
site's user can.

## Git access

All git operations (clone, pull) authenticate with one shared SSH key,
placed at `GIT_DEPLOY_KEY`. This should be a machine-user account (bot
GitHub/GitLab/Bitbucket user, not a personal one) added as a read-only
collaborator on each client repo or org — not a GitHub "deploy key",
which is limited to one repo and can't be reused across a fleet.

`init` seeds `/etc/ssh/ssh_known_hosts` with GitHub/GitLab/Bitbucket host
keys for the initial clone (runs as root). `provision` and `deploy` copy
the key into each site's `$dir/.ssh` (that site's `www-<name>` `$HOME`),
so pulls after the first one run as the site's own user, not root.

## Cloudflare

`CLOUDFLARE_PROXIED` in `provisioner.conf` (default `true`) controls two
`init` steps for a proxied (orange-cloud) domain:

- Writes `/etc/nginx/conf.d/cloudflare-realip.conf` so nginx/PHP see the
  real visitor IP (`CF-Connecting-IP`) instead of Cloudflare's edge IP.
- Firewalls 80/443 to Cloudflare's published ranges via `ufw` (SSH stays
  open). Without this the origin is reachable directly, bypassing
  Cloudflare.

Both refetch Cloudflare's ranges on every `init` run; a failed fetch
leaves existing rules/config as they were. Set `CLOUDFLARE_PROXIED=false`
for a grey-cloud (DNS-only) domain — DNS-01 cert issuance uses the
Cloudflare API either way, independent of proxy status.

Set the domain's SSL/TLS mode to "Full (strict)" in Cloudflare once
`init` has issued the origin cert.

## Uploads backup

Disaster-recovery only, not shared/live storage: local disk is always
the copy actually served. A site's upload dirs — `.ddev/config.yaml`'s
own `upload_dirs:` key, or `--upload-dirs "a b"` for sites without one —
get synced one-way to S3-compatible object storage on a schedule, via
`rclone`.

To enable, in `provisioner.conf` set `BACKUP_ENABLED="true"`,
`BACKUP_BUCKET`, and `BACKUP_CREDENTIALS` to a file (`chmod 600`)
containing:

```
BACKUP_ENDPOINT="https://nyc3.digitaloceanspaces.com"
BACKUP_ACCESS_KEY="..."
BACKUP_SECRET_KEY="..."
```

`init` installs `rclone` and a cron entry (`BACKUP_SCHEDULE`, default
hourly) that runs `backup-uploads` for every site. Sites with no
`upload_dirs` declared are skipped, not backed up as a whole. Run
`backup-uploads <name>` directly to sync one site on demand.

## Assumptions to verify against a real deploy

- `PHP_EXTENSIONS` (`provisioner.conf`) covers what the CMS needs.
- The front-controller rewrite (`try_files $uri $uri/ /index.php?$query_string;`)
  matches the CMS's actual routing.
- Craft's and Bedrock's `.env` variable names (`lib/cms.sh`) are the
  frameworks' documented conventions, not verified against a real repo.
- Craft's migrate/cache CLI commands (`lib/cms.sh`) are documented
  defaults, not verified against a real project.
