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
templates/         nginx vhost + FPM pool + webhook vhost templates
lib/               implementation
hook/              unprivileged git-forge webhook listener (Python)
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
deploy <name> [--rollback [<sha>]] [--history]   pull + run deploy steps + reload (see -h)
remove <name> [--purge-db] [--purge-files] [--purge-persistent]
list                          table of provisioned sites
provision-all                 provision every site in ./manifest
deploy-all                    deploy every provisioned site
backup-uploads [name]         sync upload_dirs to object storage (needs BACKUP_ENABLED=true)
backup-database [name]        dump + upload each site's DB (needs DB_BACKUP_ENABLED=true)
restore-uploads <name> --yes  overwrite local upload_dirs from the backup (see -h)
restore-database <name> [--from <file> | --from-file <path>] --yes   overwrite the DB from a dump (see -h)
provision-preview <project> <branch> [repo-url] [opts]   branch preview (see -h)
deploy-preview <project> <branch>       pull + redeploy a preview
remove-preview <project> <branch> [opts]   remove a preview (see -h)
prune-previews [project]      remove previews whose branch no longer exists
doctor [name]                 health check: nginx/PHP-FPM/DB/disk/certs (see -h)
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
are validated before use (`lib/config.sh`) — a `.ddev/config.yaml` lives in
the client's own repo, and these values get used in filesystem operations
and rendered nginx config, so an absolute path, an embedded newline, or a
docroot that tries to leave the repo is rejected outright rather than
trusted. `upload_dirs` is relative to **docroot** (DDEV's own convention —
same as `ddev pull`/`ddev push`), not the repo root, so `..` in one is
normal (a private, non-web-exposed uploads directory living next to
`web/`, say) — resolved against docroot and rejected only if that actually
overruns the repo root itself.

### `.ddeploy/config.yaml`

`additional_hostnames`, `additional_fqdns`, `persistent_files`, and
`db_env_scheme` aren't real DDEV fields — putting them in a real
`.ddev/config.yaml` risks a future DDEV schema-validation pass (or
`ddev config` regenerating the file) silently dropping them, and it's a
layering smell regardless: that file is DDEV's own, shared with the
client's dev team, not this tool's. Declare them instead in
`.ddeploy/config.yaml`, git-tracked, sitting next to `.ddev/config.yaml`:

```yaml
db_env_scheme: charcoal
additional_hostnames:
  - alt-name
additional_fqdns:
  - www.client.com
persistent_files:
  - storage/app/
  - .env.local
basic_auth: true
client_max_body_size: 256m
fpm_max_children: 20
auth_exempt_paths:
  - /webhook
backup_exclude:
  - cache/**
db_backup_retention_days: 30
php_ini:
  memory_limit: 256M
  upload_max_filesize: 64M
```

If it's absent, or doesn't declare a given key, that key falls back to
`.ddev/config.yaml` (or the sidecar) exactly as before — a project with
one of these already set by hand in a real `.ddev/config.yaml` keeps
working unchanged; `.ddeploy/config.yaml` is additive, not a required
migration.

Three of these are per-site overrides of a server-wide `provisioner.conf`
default, for a project that needs something different from the fleet:

- `basic_auth` — overrides `BASIC_AUTH_DEFAULT` for a normal site, or the
  on-by-default for a preview (still beaten by `--auth`/`--no-auth` on
  the CLI, which wins over both).
- `client_max_body_size` — overrides `CLIENT_MAX_BODY_SIZE` (nginx's
  upload-size ceiling, default `64m` — nginx's own stock default is a
  restrictive `1m`, which breaks most real media uploads out of the box).
- `fpm_max_children` — overrides `FPM_MAX_CHILDREN` (PHP-FPM pool
  concurrency ceiling, default `5`) for a site that needs more (or less)
  headroom than the rest of the fleet.

Three more with no server-wide equivalent — off by default, only active
when declared:

- `auth_exempt_paths` — URL path prefixes that bypass basic auth even
  when it's on (a webhook or health-check endpoint on an otherwise-gated
  preview, say). Absolute paths only (`/webhook`, not `webhook`).
  Implemented as an nginx `map` on `$uri` feeding `auth_basic` a variable
  rather than a location-block trick — the app is a front-controller
  that rewrites everything to `index.php` via `try_files`, and that
  internal rewrite re-runs nginx's location search from scratch, so a
  nested location inside an exempt-path location never actually gets
  used. `auth_basic` is evaluated against the real, pre-rewrite `$uri`,
  which is what makes this work.
- `backup_exclude` — `rclone --exclude` glob patterns (e.g. `cache/**`),
  applied to `backup-uploads` only; `restore-uploads` naturally only
  pulls back what actually made it to object storage, so nothing extra
  is needed on that side.
- `db_backup_retention_days` — per-site override of the server-wide
  `DB_BACKUP_RETENTION_DAYS`.
- `php_ini` — a map of PHP directive → value, rendered as
  `php_admin_value[]` lines in the site's own FPM pool — never touches
  the shared `php.ini`, so one site's override can't affect any other.
  `php_admin_value`, not `php_value`: the app itself can't override
  these back at runtime via `ini_set`, so the ceiling actually holds.

## Custom domains

Every site gets `<name>.$BASE_DOMAIN` for free, covered by the shared
wildcard cert. A site can also have its own domain(s) — `additional_fqdns`
in `.ddeploy/config.yaml` (see "Site config resolution"; a real
`.ddev/config.yaml` and the sidecar both still work too) or
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

`repo-url` is normally omitted — it's read from the parent project's own
git remote if already provisioned (the common case: shared mode, the
default, requires the parent already be provisioned anyway), or looked
up by project name in `./manifest` otherwise. Only needed on the CLI for
an isolated-mode preview of a project that's neither provisioned nor
listed in the manifest yet.

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

## Deploy on git push

Set `WEBHOOK_ENABLED=true` in `provisioner.conf` and re-run `init`. That
stands up `https://hooks.$BASE_DOMAIN` (wildcard cert) proxying to an
unprivileged listener on localhost. A root systemd worker then runs the
existing CLI — nothing in the HTTP request is executed as a command.

| Forge | URL | Events |
|---|---|---|
| GitHub | `https://hooks.$BASE_DOMAIN/github` | `push`, `pull_request` |
| Bitbucket Cloud | `https://hooks.$BASE_DOMAIN/bitbucket` | `repo:push`, `pullrequest:created`, `updated`, `fulfilled`, `rejected` |

HMAC secret is generated at `$WEBHOOK_SECRET` (default
`/etc/ddeploy/webhook.secret`, chmod 640). Paste it into the GitHub org
webhook and/or the Bitbucket workspace webhook. Optional
`WEBHOOK_SECRET_BITBUCKET` if the two forges should not share a secret.

What actually runs:

- Push to the branch a provisioned (non-preview) site currently has
  checked out → `deploy <name>`. Other branches are ignored on push.
- PR opened / synced (same-repo only) → `provision-preview` or
  `deploy-preview` of that parent site.
- PR closed / merged / declined → `remove-preview --purge-files`
  (`--purge-db` too if the preview was isolated).
- Fork PRs are refused (shared-mode previews would run untrusted code
  against the parent's live database).
- A repo that isn't provisioned on this box is a 202 no-op, so one org
  or workspace hook can cover every client repo.

`provision.sh deploy` over SSH is still valid. For repos that cannot use
an org/workspace webhook, copy
[`examples/ci/github-action`](examples/ci/github-action/action.yml) or
[`examples/ci/bitbucket-pipelines.yml`](examples/ci/bitbucket-pipelines.yml).
Do not have CI fake a forge payload.

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

Set by `db_env_scheme` (from CMS detection, or an explicit `db_env_scheme:`
in `.ddeploy/config.yaml` or the sidecar):

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

If `hooks.post-start` isn't declared at all and the repo has a
`composer.json`, a `composer install` step is assumed by default — DDEV
itself often installs dependencies implicitly on `ddev start` without an
explicit hook, which this tool has no way to see since it never runs
DDEV; without this fallback that shows up as a 500 from a missing
`vendor/autoload.php` on first deploy. This only fills in a completely
absent `hooks.post-start` — a config that declares some steps but skips
composer is treated as deliberate and left alone. Add an explicit
`hooks.post-start` (with or without a `composer` step) to `.ddev/config.yaml`
to override either way.

Two more extension points:

- `.provisioner/post-provision.sh` / `.provisioner/post-deploy.sh` in
  the client repo — run as `www-<name>`, same as any hook step.
  `post-provision.sh` runs once after the first deploy; `post-deploy.sh`
  runs every deploy.
- `hooks/post-provision.d/*.sh` / `hooks/post-deploy.d/*.sh` in this
  repo — run as root, for every site. See `hooks/README.md`.

## Rolling back

`deploy <name> --rollback [<sha>]` moves a site's code backward instead
of pulling forward. Without `<sha>`, it rolls back to the most recent
commit this tool has itself deployed that differs from what's live now —
`deploy <name> --history` lists that record (newest last) if you want to
pick a specific, earlier `<sha>` instead.

Mechanically this is a `git reset --hard` to that commit (every site is
cloned in full, so its own history is always available locally — no
separate release directory to manage) followed by the exact same hook
replay + reload a normal deploy runs. A rollback is itself recorded as a
new deploy, so it composes normally: a plain `deploy` afterward fast-
forwards right back to where you rolled back from (origin hasn't moved),
and a second `--rollback` walks one step further back, or forward again
to undo the rollback, whichever you ask for.

**What this does not do:** undo a database migration. If a deploy you're
rolling back past ran `migrate` (or any other forward-only step) against
the database, rolling the code back does not reverse it — you'll have
older code pointed at newer schema. For a rollback driven by a bad
migration, restore the database too (see "Restoring") or fix forward
instead. This also doesn't apply to branch previews — they're meant to
be disposable, not rolled back.

## Persistent files

A site's own git checkout is disposable by design — `provision`/`deploy`
clone and pull it freely, and `remove --purge-files` deletes it outright.
Some of what lives under that checkout isn't disposable at all, though:
`upload_dirs` (client-uploaded files, genuinely irreplaceable) and the DB
credential file (`.env` for laravel/craft, `config/config.local.json` for
charcoal) are content, not code. Those — plus anything declared in a new
`persistent_files:` key — actually live under `PERSISTENT_ROOT`
(`provisioner.conf`, default `/home/deploy/persistent`), at
`$PERSISTENT_ROOT/<name>/<path>`; the checkout only ever holds a symlink
at that path. `remove --purge-files` deletes the checkout (code) but
never touches this (content) unless `--purge-persistent` is also given —
and a later `provision` on the same name re-links to whatever's still
there automatically, so bringing a removed project back is just
re-provisioning it, no separate restore step. The DB user's existing
password is picked up the same way (`read_db_password` finds it already
in the persistent store), so this isn't just "the files survive" — the
site reconnects with zero credential churn.

`persistent_files:` (in `.ddeploy/config.yaml` — see "Site config
resolution" — not a real DDEV key) declares arbitrary extra paths beyond
`upload_dirs` and the DB credential file — a custom `.env.local`, a
`storage/app` directory, etc. — relative to the repo root, not the
docroot. A trailing `/` marks a directory; without one, a file:

```yaml
persistent_files:
  - storage/app/
  - .env.local
```

This only applies to normal sites — isolated-mode previews stay exactly
as disposable as before (shared-mode previews already point at the
parent's persistent store transitively, through the parent's own
symlink, with no changes needed).

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

`restore-uploads <name> --yes` and
`restore-database <name> [--from <file> | --from-file <path>] --yes`
pull a backup back down — genuinely destructive (that's the point), so
both require `--yes` to actually run; without it, they show what would
happen (available dumps, newest first, for the database one) and do
nothing. `restore-database` without `--from`/`--from-file` restores the
most recent object-storage dump; `--from <file>` picks a specific one by
name.

`--from-file <path>` instead loads an arbitrary local `.sql` or `.sql.gz`
dump — no object storage involved — for seeding a freshly-provisioned
site from a client-provided export without ever needing direct DB access
yourself (scp the file up, run one command).

Both commands are preview-aware the same way `list`/`remove`/`deploy-all`
are: a shared-mode preview has nothing of its own to restore (it was
never separately backed up — there's no `<bucket>/<preview-name>/...`),
so running either against one redirects to the **parent project** with a
loud warning, and restores the parent's actual database/uploads — the
ones every preview of it is currently sharing. An isolated-mode preview
restores its own, same as any normal site.

## Health check

`doctor [name]` runs a set of read-only checks — nginx config/service,
disk space, the database server itself, certificate expiry, and (per
site) vhost enabled, PHP-FPM pool running, last deploy, and a connection
test using that **site's own** database credentials, not the admin
connection the server-wide check already covers, so a revoked grant or a
drifted credential file shows up here even when the DB server itself is
fine. Without a name, every provisioned site is checked (previews
included); with one, just that site.

Each line prints `[ok]`/`[warn]`/`[fail]`; the command exits nonzero if
anything failed — wire it into cron/monitoring rather than only running
it by hand mid-incident. A malformed config for one site can't take the
whole run down: each site's checks run in their own subshell, so a `die`
there just becomes one `[fail]` row instead of aborting `doctor` for
every other site.

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

## Planned

Not built yet, roughly in priority order:

- **Notification routing** — backup/deploy failures currently only show
  up in logs; nothing pings anyone. Likely per-project override (a
  specific client's failures paging someone specific) over a purely
  server-wide setting.
- **Custom nginx snippet injection** — an escape hatch for a project
  that needs nginx config the standard template doesn't cover. Bigger
  security-review lift than the other `.ddeploy/config.yaml` keys, since
  it'd be raw server config sourced from a client repo, not a scoped
  value substituted into one — deliberately not rushed.
