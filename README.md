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
backup-database [name]        dump + upload each site's DB (needs DB_BACKUP_ENABLED=true)
provision-preview <project> <branch> [repo-url] [opts]   branch preview (see -h)
deploy-preview <project> <branch>       pull + redeploy a preview
remove-preview <project> <branch> [opts]   remove a preview (see -h)
prune-previews [project]      remove previews whose branch no longer exists
```

`init`, `init-db`, `provision`, `deploy`, `remove`, `backup-uploads`,
`backup-database`, and the `*-preview`/`prune-previews` commands need root.

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

`docroot`, `upload_dirs`, `additional_hostnames`, and `additional_fqdns`
are validated before use (`validate_relative_path`/`validate_hostname` in
`lib/config.sh`) — a `.ddev/config.yaml` lives in the client's own repo,
and these values get used in filesystem operations and rendered nginx
config, so a `..`-traversing docroot or a hostname with an embedded
newline is rejected outright rather than trusted.

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

## Branch previews

`provision-preview <project> <branch> [repo-url]` stands up a site for
one branch of an existing project, at a name derived deterministically
from `<project>` + `<branch>` (`preview_slug` in `lib/preview.sh` —
lowercased, slugified, truncated with a hash suffix to fit the 28-char
name cap). `deploy-preview`/`remove-preview` take the same `(project,
branch)` pair and resolve the same name, so nothing needs to remember or
pass around a generated name — CI just needs to know the project and
branch it's already building.

**Database and uploads are shared with the parent project by default,
not copied.** This is deliberate, not a shortcut: these sites are
typically deployed pre-launch, while a client is actively entering real
content — the database *is* their content, with nothing else it could be
restored from. Isolating a preview's database means content a client
enters while a feature is in review has no way back into the main site
when the branch merges; there's no equivalent of a git merge for a
database. So `PREVIEW_DB_MODE=shared` (the default) links a preview to
its parent's actual, current database and uploads — a migration in the
preview's deploy steps runs against real data, and content entered
through the preview is immediately the same content the main site has,
because it's the same database. The Linux user is shared too (the
preview's FPM pool runs as the parent's `www-<project>`, not a new
user) — once the data itself is shared, a separate user protects nothing
that matters.

The accepted tradeoff: two previews active at once with diverging schema
changes can conflict with each other against that one shared database.
Given the alternative is guaranteed content loss, that's the right side
to be on — and `backup-database` already covers this exact failure mode
with a rolling snapshot history, which is what actually makes the
tradeoff acceptable rather than reckless.

`--isolated` opts a specific preview out into a fully normal, separate
site — its own database, uploads, and Linux user — for when shared
continuity isn't what's wanted: testing a risky migration against a
site that's already live with real customers, or a branch that
genuinely wants a disposable blank slate. `PREVIEW_SEED` (default
`true`) seeds an isolated preview's database and uploads once, at
creation, from the parent's current state (`mysqldump | mysql`, reusing
`backup-database`'s dump; `rsync`, a copy not a link) — `--no-seed` skips
that for a truly empty database.

`deploy-preview` does `git fetch && reset --hard`, not `--ff-only pull`
— PR branches get rebased and force-pushed routinely, and there's
nothing local worth protecting on a preview. Basic auth defaults to on
for previews (`--no-auth` to turn it off), unlike normal sites, since
these are meant for internal/client eyes, not public or indexed.

nginx doesn't validate that `auth_basic_user_file` exists at `nginx -t`
time, only at request time — so a preview with no htpasswd file of its
own would 500 on every request. `init` generates a shared fallback
(`BASIC_AUTH_CREDENTIALS`, default `/etc/nginx/htpasswd/default`) once,
with a random password logged to stdout — every site with auth on and
no htpasswd file of its own (`htpasswd -c /etc/nginx/htpasswd/<name>
<user>`) uses that shared one instead. Rotate it by deleting the file
and re-running `init`.

`remove-preview --purge-db` only drops a database for an isolated-mode
preview — for shared mode it's a no-op, since that database belongs to
the parent. `--purge-files` only ever removes the preview's own
checkout; a shared preview's uploads paths are symlinks into the
parent's directory, and `rm -rf` on the preview's own dir removes the
symlinks, never what they point to.

`prune-previews [project]` is the cleanup safety net: it diffs every
provisioned preview against its branch's actual state on the remote
(`git ls-remote`) and removes ones whose branch is gone. The primary
cleanup path is still CI calling `remove-preview` when a PR closes —
this only catches what that missed. Wire it into `init` via
`PREVIEW_PRUNE_ENABLED`/`PREVIEW_PRUNE_SCHEDULE` for a periodic cron run.

The general commands are preview-aware too, so a preview never needs its
own separate mental model once it exists: `list` shows a `PREVIEW`
column (`<project>/<branch> (<mode>)`) and resolves a shared-mode
preview's `DB` column to the parent's actual database, not the preview's
own unused name; `deploy-all` skips previews (they update via
`deploy-preview`, not a fleet-wide `--ff-only` pull that would fail on
any rebased branch); and plain `remove <name>` on a preview detects that
and delegates to `remove-preview`, so the purge-db-belongs-to-the-parent
safety and the symlink-safe file cleanup apply automatically.

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

**Accepted tradeoff:** the admin account `init-db` creates has
`GRANT ALL ON *.* WITH GRANT OPTION` — full control of every database on
that server, not just the ones this tool manages — scoped only by source
IP (`DB_ALLOWED_HOSTS`), and shared across every web server that gets a
copy of `DB_ADMIN_CREDENTIALS`. Provisioning/deploying/backing up a site
on demand needs an account that can create databases and grant per-site
users, and MySQL has no clean "can CREATE DATABASE and GRANT on what it
creates, but nothing else" role — the real options are a wildcard-prefix
grant (forces every site's DB name under one prefix, still one shared
account, needs a naming convention + migration) or a per-web-server admin
account (limits blast radius to one server's compromise instead of the
whole fleet's, no schema change, but doesn't shrink the account's own
privileges). Neither is a clean win over the other, so this stays as-is
for now — keep `DB_ADMIN_CREDENTIALS` file permissions tight (600,
root-owned) and `DB_ALLOWED_HOSTS` as narrow as possible.

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

## Backups

Disaster-recovery only, not live/shared storage — local disk and the
running database are always what's actually served; these are one-way
copies out to S3-compatible object storage on a schedule, via `rclone`.
Both share the same destination config in `provisioner.conf`:

```
BACKUP_CREDENTIALS="..."   # path to a file (chmod 600), see below
BACKUP_BUCKET="..."
```

`BACKUP_CREDENTIALS` points at a file containing:

```
BACKUP_ENDPOINT="https://nyc3.digitaloceanspaces.com"
BACKUP_ACCESS_KEY="..."
BACKUP_SECRET_KEY="..."
```

**Uploads** (`BACKUP_ENABLED`, `BACKUP_SCHEDULE`, default hourly): a
site's upload dirs — `.ddev/config.yaml`'s own `upload_dirs:` key, or
`--upload-dirs "a b"` for sites without one — get synced to
`<bucket>/<name>/<dir>`. Sites with none declared are skipped, not
backed up as a whole. Run `backup-uploads [name]` directly to sync
on demand.

**Database** (`DB_BACKUP_ENABLED`, `DB_BACKUP_SCHEDULE`, default hourly,
offset from `BACKUP_SCHEDULE`): each site's database is dumped
(`mysqldump --single-transaction`, gzipped) and uploaded to
`<bucket>/<name>/db/` — a live database's data files aren't safe to sync
directly, so this is a logical dump, not a file copy, and it accumulates
a dated series rather than mirroring current state. Dumps older than
`DB_BACKUP_RETENTION_DAYS` (default 7) are pruned on each run. Works
against a local or remote (`init-db`) database, same as `provision`. Run
`backup-database [name]` directly to dump on demand.

`init` installs `rclone` (once, if either backup is enabled) and the
cron entries for whichever are turned on.

Both are preview-aware: a shared-mode preview is skipped by both (its
uploads are a symlink into its parent's, and its database *is* its
parent's — either would just be a redundant duplicate of the parent's
own backup, multiplied by however many shared previews exist). An
isolated-mode preview has real, separate uploads/database of its own
and is backed up normally.

### Restoring

`restore-uploads <name> --yes` and `restore-database <name> [--from <file>] --yes`
pull a backup back down — genuinely destructive (that's the point), so
both require `--yes` to actually run; without it, they show what would
happen (available dumps, newest first, for the database one) and do
nothing. `restore-database` without `--from` restores the most recent
dump.

Both are preview-aware the same way `list`/`remove`/`deploy-all` are: a
shared-mode preview has nothing of its own to restore (it was never
separately backed up — there's no `<bucket>/<preview-name>/...`), so
running either command against one redirects to the **parent project**
with a loud warning, and restores the parent's actual database/uploads
— the ones every preview of it is currently sharing. An isolated-mode
preview restores its own, same as any normal site.

## Testing

`docker/` runs the actual provisioner — init, init-db, provision, deploy,
branch previews, backup/restore, remove — against real systemd, nginx,
PHP-FPM, MariaDB, sshd, and object storage in disposable containers. See
`docker/README.md`. `docker/test/run.sh` is the entry point.

## Assumptions to verify against a real deploy

- `PHP_EXTENSIONS` (`provisioner.conf`) covers what the CMS needs.
- The front-controller rewrite (`try_files $uri $uri/ /index.php?$query_string;`)
  matches the CMS's actual routing.
- Craft's and Bedrock's `.env` variable names (`lib/cms.sh`) are the
  frameworks' documented conventions, not verified against a real repo.
- Craft's migrate/cache CLI commands (`lib/cms.sh`) are documented
  defaults, not verified against a real project.
- Real ACME/DNS-01 and HTTP-01 certificate issuance, and ufw's actual
  packet-filtering behavior — `docker/`'s test harness mocks both (see
  its README for why) and everything else has been verified against it;
  these two still need a real domain / real VM to check.
