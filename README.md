# ddeploy

Provisions and deploys PHP sites on Ubuntu 24.04: nginx, one PHP-FPM
pool per site, one Linux user per site, one MariaDB database per site, a
shared wildcard TLS certificate. No containers. Reads a project's own
`.ddev/config.yaml` as config; never runs DDEV itself.

Built for staging/QA/client-review — no staging→production promotion
path, no web UI. One web server per project; a database server can be
shared across several (`init-db`).

## Requirements

- An Ubuntu 24.04 server (or two — see "Database server" for a
dedicated DB host), root/sudo access.
- A domain, with either Cloudflare DNS or manual DNS control (TLS is
issued via certbot either way).
- A git host reachable over SSH — GitHub, GitLab, Bitbucket, self-hosted.
- Docker, only if you want to run the test harness before touching a
real server (next section).

## See it work

```
docker/test/run.sh
```

Builds two systemd-enabled Ubuntu containers plus MinIO (stands in for
S3) and runs the full lifecycle for real: `init`, `provision`, `deploy`,
branch previews, git-push webhooks, backup/restore, rollback, `doctor`,
`remove`. Everything is real except ACME/DNS-01 issuance and `ufw`'s
packet filtering (mocked — see `docker/README.md`).

Unedited output from an actual run, provisioning one site:

```
$ ./provision.sh provision testsite ssh://gitfixture@127.0.0.1/srv/git/testsite.git
[info]  cloning ssh://gitfixture@127.0.0.1/srv/git/testsite.git -> /home/deploy/sites/testsite
Cloning into '/home/deploy/sites/testsite/releases/.staging-…'...
[info]  resolved: php=8.3 docroot='web' hostnames=[alt-testsite]
[info]  php8.3-fpm and configured extensions already installed
[info]  created system user www-testsite
[info]  installed FPM pool for testsite (php8.3, user=www-testsite, pm.max_children=20)
nginx: configuration file /etc/nginx/nginx.conf test is successful
[info]  installed vhost for testsite (testsite.staging.ddeploy.test alt-testsite.staging.ddeploy.test)
[info]  database 'testsite' ready (user 'testsite'@'10.88.90.4', scheme=laravel)
[info]  running first deploy for testsite
[info]  provisioned: https://testsite.staging.ddeploy.test
```

Needs Docker with `--privileged` containers allowed, and internet
egress for apt packages and a few real API calls.

## Quickstart: a real server

Fresh droplet, nothing on it yet. Copy `bootstrap.sh` onto it and run
once as root:

```
./bootstrap.sh <your-ddeploy-repo-url>
```

Installs git, creates `deploy` (added to `sudo`), clones this repo to
`/opt/ddeploy` (`root:root` — see [docs/security.md](docs/security.md)
for why). Doesn't touch SSH access for `deploy`; set that up yourself
first. Not meant to be curl-piped — the next step needs a real terminal.

Already have `deploy`, git, and a clone some other way? Make sure it's
root-owned, then run the same steps:

```
sudo ./provision.sh configure               # writes provisioner.conf (domain, paths, PHP versions)
# place a Cloudflare API token at CF_CREDENTIALS (chmod 600)
# place a shared git SSH key at GIT_DEPLOY_KEY (chmod 600) — see "Git access"
sudo ./provision.sh init                    # nginx/PHP/MariaDB/certbot, wildcard cert, firewall
sudo ./provision.sh provision <name> <repo-url>   # clone, config, vhost/FPM/DB, first deploy
```

`configure` + `init` are also just `./install.sh` (skips `configure` if
`provisioner.conf` already exists).

From there: `deploy <name>` on every push (or set up "Deploy on git
push"), `list` to see the fleet, `doctor` to check on it. For custom
domains, branch previews, backups, health-check paging: see
[docs/new-project.md](docs/new-project.md).

## Commands

```
configure                     create/update provisioner.conf (see -h)
init                          set up a web server (packages, PHP, TLS, firewall)
init-db                       set up a dedicated database server
provision <name> [repo-url]   add a site
deploy <name> [--rollback [<sha>]] [--history]   new release + re-apply vhost/FPM config + run deploy steps (see -h)
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
preview-url <project> <branch>   print the preview URL (site need not exist)
logs <name> [-n N] [-f]       tail a site or fleet log (see -h)
doctor [name]                 health check: nginx/PHP-FPM/DB/disk/certs (see -h)
```

`init`, `init-db`, `provision`, `deploy`, `remove`, `backup-uploads`,
`backup-database`, `logs`, and the `*-preview`/`prune-previews` commands need root.

## Configuration

Six places a setting can come from, in increasing order of "how
permanent is this":

| Where                                            | What goes here                                                                              | Lives in                               | Git-tracked                           |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- | -------------------------------------- | ------------------------------------- |
| `provisioner.conf`                               | Server-wide defaults — every site on this box starts from these                             | this repo, on the server               | no — gitignored, created by `./provision.sh configure` from the tracked `provisioner.example.conf` |
| `.ddev/config.yaml`                              | Real DDEV fields: `php_version`, `docroot`, `upload_dirs`, `hooks.post-start`, `database.*` | the client's repo                      | yes — it's DDEV's own file            |
| `.ddeploy/config.yaml`                           | ddeploy-only per-site keys that aren't real DDEV fields (below)                             | the client's repo, sibling to `.ddev/` | yes                                   |
| `generated/<name>.yaml`                          | Sidecar ddeploy writes itself for a repo with no `.ddev/config.yaml` yet                    | this repo, on the server               | no — `generated/` is gitignored       |
| `generated/<name>.override.yaml`                 | Operator override (`provision.sh override`, see "Overriding a project's config" below), wins over both of the above | this repo, on the server               | no — `generated/` is gitignored       |
| CLI flags (`--db`, `--hostnames`, `--auth`, ...) | A one-off override for this run of `provision`, always wins                                 | the terminal                           | n/a                                   |

**Precedence, per key:** CLI flag on `provision` > operator override
(`provision.sh override`) > `.ddeploy/config.yaml` > `.ddev/config.yaml`
(or the sidecar, whichever exists). `--db`, `--hostnames`,
`--custom-domains`, `--upload-dirs`, `--deploy-cmd` apply on every run
they're passed, not just the first (`provision -h`).

**Takes effect on next `deploy`:** `php_version`, `docroot`,
`basic_auth`, `client_max_body_size`, `fpm_max_children`, `php_ini`,
`additional_hostnames`, `additional_fqdns`. **`provision`-time only:**
`--db`, `--upload-dirs`, `--deploy-cmd`, `--custom-domains`, and the
fallback fields.

### Resolving a new site

`provision` resolution order:

1. `.ddev/config.yaml` in the repo, if present.
2. `generated/<name>.yaml` sidecar from a previous run.
3. `--non-interactive` with `--php`/`--docroot`/`--db`/`--hostnames`/
  `--custom-domains`/`--upload-dirs`/`--deploy-cmd` flags.
4. Interactive prompts.

3 and 4 write to the sidecar, so later runs (including `deploy`) don't
need the flags/prompts again.

No `.ddev/config.yaml`? `lib/cms.sh` detects CraftCMS, WordPress (plain
or Bedrock), or Charcoal from the repo (`composer.json`, `wp-load.php`,
a `craft` binary) and fills in docroot + deploy steps. Detected values
land in the sidecar and can be edited by hand.

`webserver_type` is read but not enforced — sites are always served by
nginx.

`docroot`, `upload_dirs`, `additional_hostnames`, `additional_fqdns` are
validated (`lib/config.sh`): no absolute path, no embedded newline, no
docroot that escapes the repo. `upload_dirs` is relative to **docroot**
(DDEV's own convention), not repo root — `..` is normal (a private
uploads dir next to `web/`) as long as it doesn't escape the repo root
itself.

### `.ddeploy/config.yaml`

`additional_hostnames`, `additional_fqdns`, `persistent_files`,
`db_env_scheme`, `queue_workers`, and `schedule` aren't real DDEV
fields. Declare them in `.ddeploy/config.yaml` instead, git-tracked,
sitting next to `.ddev/config.yaml`:

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
security_headers: true
static_cache: 30d
deny_php_in_uploads: true
redirects:
  - from: /old-page
    to: /new-page
    code: 301
queue_workers:
  - php craft queue/listen
schedule:
  - cron: "*/5 * * * *"
    cmd: php craft queue/run
```

Absent, or a key not declared: falls back to `.ddev/config.yaml` (or the
sidecar) — additive, not a required migration.

Per-site overrides of a server-wide `provisioner.conf` default:

- `basic_auth` — overrides `BASIC_AUTH_DEFAULT` (normal sites) or the
on-by-default for previews. `--auth`/`--no-auth` on the CLI wins over
both.
- `client_max_body_size` — overrides `CLIENT_MAX_BODY_SIZE` (default
`64m`; nginx's own stock default is `1m`).
- `fpm_max_children` — overrides `FPM_MAX_CHILDREN` (default `5`).

Off by default, no server-wide equivalent:

- `queue_workers` / `schedule` — persistent supervised queue workers and
cron-style scheduled commands, running as the site's own user. See
"Queue workers & scheduled tasks".
- `auth_exempt_paths` — URL path prefixes that bypass basic auth even
when it's on. Absolute paths only (`/webhook`, not `webhook`).
- `backup_exclude` — `rclone --exclude` glob patterns (e.g. `cache/**`),
applied to `backup-uploads` only.
- `db_backup_retention_days` — per-site override of the server-wide
`DB_BACKUP_RETENTION_DAYS`.
- `php_ini` — a map of PHP directive → value, rendered as
`php_admin_value[]` (not `php_value` — the app can't override it via
`ini_set`) in the site's own FPM pool only.

Scoped nginx knobs — not raw snippets, each value is charset-validated:

- `security_headers` — **on by default**; `false` to opt out. Sends
`X-Content-Type-Options: nosniff`, `Referrer-Policy:
strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN`. No
HSTS.
- `static_cache: 30d` — `expires` on static extensions (css/js/images/
fonts). Duration `1–9999` + `s`/`m`/`h`/`d`. Missing assets 404. Off by
default.
- `deny_php_in_uploads` — **on by default**; `false` to opt out. PHP
`deny all` + 404 for each web-accessible `upload_dirs` entry. Extra
prefixes: `deny_php_paths: [/media]`. `/` is refused.
- `redirects` — list of `{from, to, code}`. `from`/`to` are URL paths or
an `https://` URL; `code` is `301` or `302` (default 301). No `$`
variables, no `http://`, no quotes or semicolons.

Anything else: drop a **root-owned regular file** at
`/etc/nginx/ddeploy-extra/<name>.conf` (`init` creates the directory).
Included inside the site's `server{}` (wildcard and custom-domain
vhosts). It is never read from the client repo; `.ddeploy/nginx.conf` is
ignored if present. A symlink or a non-root-owned file is skipped with
a warning. Invalid extra config fails `nginx -t` and the deploy aborts.

### Overriding a project's config without touching the repo

For a change without repo write access, or without waiting on a commit:

```
sudo ./provision.sh override <name> key=value [key=value ...]
```

Writes `generated/<name>.override.yaml` (server-side only). Highest
precedence of the three config sources. Takes effect on the site's next
`deploy` (re-run it yourself to apply immediately).

Scalar keys: `basic_auth`, `client_max_body_size`, `fpm_max_children`,
`db_env_scheme`, `security_headers`, `static_cache`,
`deny_php_in_uploads`, `db_backup_retention_days`. List keys,
space-separated (quote the value): `additional_hostnames`,
`additional_fqdns`, `persistent_files`, `auth_exempt_paths`,
`backup_exclude`, `deny_php_paths`. Not supported here (need
`.ddeploy/config.yaml` in the repo): `redirects`, `php_ini`,
`queue_workers`, `schedule` — structured data, or (for `queue_workers`)
a command likely to contain its own spaces.

```
sudo ./provision.sh override client "additional_hostnames=alt-name alt2"
sudo ./provision.sh override client --show      # print current overrides
sudo ./provision.sh override client --unset basic_auth
sudo ./provision.sh override client --clear     # remove every override
```

## Site lifecycle

### Custom domains

Every site gets `<name>.$BASE_DOMAIN` free, on the shared wildcard cert.
For its own domain(s): `additional_fqdns` in `.ddeploy/config.yaml`, or
`--custom-domains "a.com www.a.com"` non-interactively. Issued via
HTTP-01 (not the wildcard's DNS-01), own certificate per site:

- DNS for the domain(s) must already point at this server before
`provision` runs — HTTP-01 fails otherwise, `provision` logs a warning
and leaves an HTTP-only vhost in place; re-run once DNS is live.
- All of a site's custom domains share one certificate, named after the
first one listed.
- If the server is behind Cloudflare, these domains need their own
orange/grey-cloud DNS record and don't inherit `$BASE_DOMAIN`'s proxy
setup — set that up per domain as needed.

Once issued, renewal is certbot's timer, same as the wildcard.

### Branch previews

```
provision-preview <project> <branch> [repo-url]
deploy-preview <project> <branch>
remove-preview <project> <branch> [--purge-db] [--purge-files]
```

Name is derived from `<project>` + `<branch>` (`preview_slug`,
`lib/preview.sh`). `repo-url` is normally omitted — read from the parent
project's git remote, or looked up in `./manifest`.

**Database and uploads are shared with the parent project by default**
(`PREVIEW_DB_MODE=shared`) — a preview's FPM pool runs as the parent's
own `www-<project>` user, not a new one. Tradeoff: two previews active
at once can conflict against that one shared database; `backup-database`
covers recovery from that. `--isolated` gives a preview its own
database/uploads/Linux user instead. `PREVIEW_SEED` (default `true`)
seeds an isolated preview once at creation from the parent's current
state; `--no-seed` for an empty database.

`deploy-preview` does `git fetch && reset --hard`, not `--ff-only pull`
— previews stay in-place, not atomic releases. Basic auth defaults **on**
for previews (`--no-auth` to turn off), unlike normal sites. `init`
generates a shared fallback htpasswd (`BASIC_AUTH_CREDENTIALS`, default
`/etc/nginx/htpasswd/default`) for any site with auth on and no htpasswd
file of its own; rotate by deleting the file and re-running `init`.

`remove-preview --purge-db` is a no-op for shared mode (database belongs
to the parent). `--purge-files` only removes the preview's own checkout
— a shared preview's uploads are symlinks into the parent's, never
touched.

`prune-previews [project]` diffs every provisioned preview against its
branch's actual remote state (`git ls-remote`) and removes ones whose
branch is gone — the safety net behind CI's own `remove-preview` on PR
close. Wire into `init` via `PREVIEW_PRUNE_ENABLED`/
`PREVIEW_PRUNE_SCHEDULE` for a periodic cron run.

Previews are transparent to the general commands: `list` shows a
`PREVIEW` column; `deploy-all` skips previews; plain `remove <name>` on
a preview delegates to `remove-preview` automatically.

### Deploy on git push

```
sudo ./provision.sh configure webhook
```

Sets `WEBHOOK_ENABLED=true`, generates `$WEBHOOK_SECRET` (default
`/etc/ddeploy/webhook.secret`, `root:root` `600`), and offers to
register the webhook itself via each forge's REST API (prompts for a
token/app-password, used once, never saved). Then:

```
sudo ./provision.sh init
```

Stands up `https://hooks.$BASE_DOMAIN` proxying to an unprivileged
listener on localhost; a root systemd worker runs the existing CLI.

The listener never holds `$WEBHOOK_SECRET` — HMAC verification happens
later, in a root-context step (see [docs/security.md](docs/security.md)
for why). Consequence: **every structurally-valid POST gets `202`**,
correctly signed or not. A missing signature header gets a synchronous
`401`; a present-and-wrong one (e.g. a typo'd secret) is accepted and
rejected later, asynchronously — check `journalctl -u
ddeploy-hook-worker` or this tool's own logs, not the forge's delivery
log.

| Forge           | URL                                    | Events                                                                 |
| --------------- | -------------------------------------- | ---------------------------------------------------------------------- |
| GitHub          | `https://hooks.$BASE_DOMAIN/github`    | `push`, `pull_request`                                                 |
| Bitbucket Cloud | `https://hooks.$BASE_DOMAIN/bitbucket` | `repo:push`, `pullrequest:created`, `updated`, `fulfilled`, `rejected` |

Both are org/workspace-level (Bitbucket has no workspace-level webhook
UI, so `configure webhook` drives both via API for consistency). To do
it by hand: `lib/register_webhook.py`, or directly:

```
# GitHub: an org-owned PAT (classic, admin:org_hook scope) or a
# fine-grained token with organization "Webhooks" write access.
curl -X POST https://api.github.com/orgs/<org>/hooks \
  -H "Authorization: Bearer <token>" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  -d '{"name":"web","active":true,"events":["push","pull_request"],
       "config":{"url":"https://hooks.'"$BASE_DOMAIN"'/github","content_type":"json",
                  "secret":"<the-webhook-secret>","insecure_ssl":"0"}}'

# Bitbucket: an app password with "Webhooks: Read and write", belonging
# to a workspace admin.
curl -X POST https://api.bitbucket.org/2.0/workspaces/<workspace>/hooks \
  -u "<username>:<app-password>" -H "Content-Type: application/json" \
  -d '{"description":"ddeploy","url":"https://hooks.'"$BASE_DOMAIN"'/bitbucket","active":true,
       "secret":"<the-webhook-secret>",
       "events":["repo:push","pullrequest:created","pullrequest:updated","pullrequest:fulfilled","pullrequest:rejected"]}'
```

Registering once covers every client repo. Optional
`WEBHOOK_SECRET_BITBUCKET` if the two forges shouldn't share a secret
(falls back to `$WEBHOOK_SECRET` otherwise).

What runs:

- Push to a site's checked-out branch (or its `deploy_branch` override,
"Default branch") → `deploy <name>`. Other branches ignored.
- PR opened/synced (same-repo only) → `provision-preview` or
`deploy-preview`.
- PR closed/merged/declined → `remove-preview --purge-files`
(`--purge-db` too if isolated).
- Fork PRs refused.
- Unprovisioned repo → `202` no-op.

If `PREVIEW_COMMENT_CREDENTIALS` is set (chmod 600, `GITHUB_TOKEN` and/or
`BITBUCKET_USER`+`BITBUCKET_APP_PASSWORD`), a successful preview upsert
posts/updates a PR comment `Preview: https://<slug>.$BASE_DOMAIN`. A
failed comment is a warning, not a failed deploy.

`provision.sh logs <name> [-n N] [-f]`, `provision.sh preview-url
<project> <branch>` — useful when CI is the deploy trigger instead of
the webhook.

`provision.sh deploy` over SSH is still valid. For repos that can't use
an org/workspace webhook:
`[examples/ci/github-action](examples/ci/github-action/action.yml)` or
`[examples/ci/bitbucket-pipelines.yml](examples/ci/bitbucket-pipelines.yml)`.

### Default branch

By default a site tracks whatever branch it was cloned on (the remote's
default). To pin a specific branch instead:

```
provision.sh provision <name> --branch develop
```

Saved server-side, not in the client's repo; takes effect immediately.
Next `deploy` fetches that branch and switches `current` onto it
(`git checkout -B <branch> origin/<branch>`, not a pull); after that it's
an ordinary `pull --ff-only` on the newly-tracked branch.
`--clear-branch` removes the setting. A git-push webhook recognizes a
push to the newly-configured branch immediately, even before HEAD has
switched.

For a brand-new site: `provision <name> <repo-url> --branch <name>`
clones that branch directly. Manifest onboarding takes it as an optional
3rd column: `<name> <repo-url> [branch]`. Branch previews are
unaffected — always pinned to their own PR branch.

### Rolling back

```
deploy <name> --rollback [<sha>]
deploy <name> --history
```

Without `<sha>`, rolls back to the most recent commit this tool has
itself deployed that differs from what's live. `--history` lists the
record (newest last).

`$SITES_ROOT/<name>/current` symlinks to `releases/<timestamp>-<sha>/`.
A forward `deploy` builds a new release, runs hooks, then retargets
`current` — a failed pull/hook leaves the previous tree serving.
`RELEASES_KEEP` (`provisioner.conf`, default 5) controls how many
releases are kept; the live one is never pruned.

Rollback retargets `current` at an earlier release still on disk (hooks
not replayed), or rebuilds one with `git reset --hard` + hooks if it's
been pruned. Recorded as a new deploy — a plain `deploy` afterward
fast-forwards back, a second `--rollback` walks further back or undoes
the first.

**Does not undo a database migration.** Restore the database too (see
"Restoring") or fix forward. Doesn't apply to branch previews (they stay
in-place, not rolled back).

### Persistent files

The git checkout is disposable — `remove --purge-files` deletes it
entirely. `upload_dirs` and the DB credential file (`.env` or
`config/config.local.json`) are content, not code: they live under
`PERSISTENT_ROOT` (`provisioner.conf`, default `/home/deploy/persistent`)
at `$PERSISTENT_ROOT/<name>/<path>`, and the checkout only holds a
symlink. `--purge-files` alone leaves this in place; `--purge-persistent`
deletes it too. Re-`provision`ing the same name re-links automatically
(including the DB password) — no separate restore step.

`persistent_files:` (`.ddeploy/config.yaml`) declares extra paths
(relative to repo root, not docroot). Trailing `/` marks a directory:

```yaml
persistent_files:
  - storage/app/
  - .env.local
```

Normal sites only — isolated previews stay disposable; shared previews
already point at the parent's store.

## Data protection

### Backups

Disaster-recovery only — one-way copies to S3-compatible object storage
on a schedule, via `rclone`. Config in `provisioner.conf`:

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

```
sudo ./provision.sh configure backups
```

Interactive: provider, bucket, keys — **tests credentials against the
real bucket** (`rclone lsd`) before writing, then turns
`BACKUP_ENABLED`/`DB_BACKUP_ENABLED` on. `BACKUP_ENDPOINT` by provider:

- **DigitalOcean Spaces**: `https://<region>.digitaloceanspaces.com`.
  Key pair under "API" → "Spaces access keys," account-wide.
- **AWS S3**: `https://s3.<region>.amazonaws.com`. IAM key scoped to
  `s3:GetObject`/`PutObject`/`DeleteObject`/`ListBucket`.
- **Any other S3-compatible** (MinIO, Backblaze B2, Wasabi, ...): same
  three fields.

One set of credentials + one bucket covers every project.

**Uploads** (`BACKUP_ENABLED`, `BACKUP_SCHEDULE`, default hourly):
`upload_dirs` synced to `<bucket>/<name>/<dir>`. Sites with none
declared are skipped. `backup-uploads [name]` to sync on demand.

**Database** (`DB_BACKUP_ENABLED`, `DB_BACKUP_SCHEDULE`, default hourly):
`mysqldump --single-transaction`, gzipped, to `<bucket>/<name>/db/`.
Dumps older than `DB_BACKUP_RETENTION_DAYS` (default 7) pruned each run.
`backup-database [name]` to dump on demand.

`init` installs `rclone`/`cron` and writes
`/etc/cron.d/ddeploy-backup-uploads` / `-database` (root). Not in
`crontab -l` for any user — check `cat
/etc/cron.d/ddeploy-backup-uploads` or `sudo ./provision.sh doctor`.

Both skip shared-mode previews (uploads/database are the parent's).

### Restoring

```
restore-uploads <name> --yes
restore-database <name> [--from <file> | --from-file <path>] --yes
```

Destructive — `--yes` required, otherwise shows what would happen and
exits. No `--from`/`--from-file`: restores the most recent object-storage
dump. `--from-file <path>`: loads a local `.sql`/`.sql.gz` dump directly,
no object storage involved (e.g. a client-provided export).

Shared-mode preview → redirects to the parent project (nothing of its
own to restore). Isolated preview restores its own.

### Health check

```
doctor [name]
```

Read-only checks: nginx config/service, disk space, database server,
certificate expiry; per site: vhost enabled, PHP-FPM pool running, last
deploy, DB connection test using the **site's own** credentials (not
admin). No name: every provisioned site, previews included.

Webhook listener, uploads backup, database backup, `prune-previews`:
always reported, `[ok] ... disabled (...)` when off — never silent. When
a backup is on: bucket reachability, recoverable dump count + age, and
whether uploads have synced anything at all (not a freshness check).
Shared-mode preview: skipped (covered by the parent's row).

Prints `[ok]`/`[warn]`/`[fail]` per line, exits nonzero on any failure —
wire into cron/monitoring. One site's malformed config only produces one
`[fail]` row, doesn't abort the rest.

`NOTIFY_WEBHOOK` in `provisioner.conf` pages on `[fail]` (not `[warn]`).
See "Failure paging."

## Failure paging

Set `NOTIFY_WEBHOOK` to a Slack incoming webhook, Discord webhook, or
any URL accepting a JSON POST with `text`/`content`. Credential — don't
commit it. Empty (default) is off.

Only **failures** page. Same command+site won't page again until
`NOTIFY_COOLDOWN` seconds pass (default 3600). SSH `deploy` doesn't page
(you're watching); a git-push deploy that fails after the `202` does.

## Server & operations

### Database server

Default `DB_HOST=127.0.0.1`: `init` installs MariaDB on the same server,
`provision`/`deploy` connect as local root over the unix socket.

To share one MariaDB instance across web servers: run `init-db` on a
dedicated database server (set `DB_ADMIN_CREDENTIALS`/`DB_ALLOWED_HOSTS`
— the web servers' IPs — first). Installs MariaDB, opens it to
`DB_ALLOWED_HOSTS` only (`ufw`, port 3306), writes an admin credentials
file. Copy it to each web server, then set:

```
DB_HOST="<database server's address>"
DB_ADMIN_CREDENTIALS="<path to the copied credentials file>"
DB_GRANT_HOST="<this web server's address>"
```

`DB_GRANT_HOST` (default `localhost`) should match an entry in
`DB_ALLOWED_HOSTS`.

**Accepted tradeoff:** the admin account `init-db` creates has
`GRANT ALL ON *.* WITH GRANT OPTION` — full control of every database on
that server, not just the ones this tool manages. Keep
`DB_ADMIN_CREDENTIALS` file permissions tight (600, root-owned) and
`DB_ALLOWED_HOSTS` as narrow as possible; see
[docs/security.md](docs/security.md) for why this can't easily be
scoped tighter.

### Database credentials

Set by `db_env_scheme` (from CMS detection, or an explicit `db_env_scheme:`
in `.ddeploy/config.yaml` or the sidecar):

| scheme     | written to                     | vars                                                                 |
| ---------- | ------------------------------ | -------------------------------------------------------------------- |
| `laravel`  | `.env`                         | `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`               |
| `craft`    | `.env`                         | `CRAFT_DB_*`                                                         |
| `charcoal` | `config/config.local.json`     | `databases.<default_database>.{hostname,database,username,password}` |
| `none`     | nowhere (e.g. plain WordPress) | saved root-only to `generated/<name>.dbpass`, never logged           |

`charcoal` creates `config/config.local.json` if it doesn't exist,
reuses its own `default_database` key if already set.

### Deploy hooks

`.ddev/config.yaml`'s `hooks.post-start` replays on every deploy, as
`www-<name>`, under the site's pinned PHP version. `exec`/`composer`
steps run; `exec-host` steps are logged and skipped. A step referencing
`ddev` or `/var/www/html` is skipped with a warning.

No `hooks.post-start` declared, but the repo has `composer.json`:
`composer install` is assumed by default (DDEV often installs implicitly
on `ddev start`, which this tool never sees). Only fills a completely
absent `hooks.post-start` — declaring steps without `composer` is
treated as deliberate.

Two more extension points:

- `.provisioner/post-provision.sh` / `.provisioner/post-deploy.sh` in
the client repo — run as `www-<name>`, same as any hook step.
`post-provision.sh` runs once after the first deploy; `post-deploy.sh`
runs every deploy.
- `hooks/post-provision.d/*.sh` / `hooks/post-deploy.d/*.sh` in this
repo — run as root, for every site. See `hooks/README.md`.

### Queue workers & scheduled tasks

For something running *between* deploys (Craft's `queue/listen`,
Laravel's `queue:work` + `schedule:run`). Two `.ddeploy/config.yaml`
keys, both optional:

```yaml
queue_workers:
  - php craft queue/listen
schedule:
  - cron: "*/5 * * * *"
    cmd: php craft queue/run
  - cron: "0 3 * * *"
    cmd: php craft gc
```

`queue_workers` — each entry becomes a **persistent, supervised systemd
service** (`ddeploy-worker-<name>-<index>.service`), running as
`www-<name>`, `Restart=always`. Restarted on every deploy (including
rollback). Fewer workers on redeploy stops/removes the extras. Check:
`systemctl status ddeploy-worker-<name>-0`, `journalctl -u
ddeploy-worker-<name>-0 -f`.

`schedule` — each `{cron, cmd}` becomes one line in
`/etc/cron.d/ddeploy-site-<name>`, running as `www-<name>`. Output
appends to `logs/<name>.log`. See
[docs/security.md](docs/security.md) for how these run a
project-declared command safely.

Not available for branch previews (shared-mode would double-process the
parent's queue). `remove <name>` always removes worker units + the
cron.d file.

### Isolation

Each site: own Linux user (`www-<name>`), FPM pool, socket, database,
DB user. Files owned `www-<name>:www-data`. The checkout itself is
root-owned, not `deploy`'s. Rationale for both, and for git/webhook
isolation: [docs/security.md](docs/security.md).

### Git access

All git operations authenticate with one shared SSH key, placed at
`GIT_DEPLOY_KEY` (`init` `chown root:root`/`chmod 600`s it). This should
be a machine-user account (bot GitHub/GitLab/Bitbucket user) added as a
read-only collaborator on each client repo or org — not a GitHub "deploy
key", which is limited to one repo and can't be reused across a fleet.
It's never copied into a site's own directory; see
[docs/security.md](docs/security.md) for how a hook step that genuinely
needs it (a private composer dependency, say) still gets access.

### Cloudflare

`CLOUDFLARE_PROXIED` in `provisioner.conf` (default `true`) controls two
`init` steps for a proxied (orange-cloud) domain:

- Writes `/etc/nginx/conf.d/cloudflare-realip.conf` so nginx/PHP see the
real visitor IP (`CF-Connecting-IP`) instead of Cloudflare's edge IP.
- Firewalls 80/443 to Cloudflare's published ranges via `ufw` (SSH stays
open). Without this the origin is reachable directly, bypassing
Cloudflare.

Refetched on every `init` run; a failed fetch leaves existing config as
is. `CLOUDFLARE_PROXIED=false` for grey-cloud (DNS-only) — DNS-01 cert
issuance uses the Cloudflare API either way.

Set the domain's SSL/TLS mode to "Full (strict)" in Cloudflare once
`init` has issued the origin cert.

## Layout

```
bootstrap.sh               deploy user + packages + clone, for a droplet with nothing on it yet
install.sh                 configure (if needed) + init, chained for a fresh server
provision.sh               entrypoint
provisioner.example.conf   tracked template; `configure` copies it to provisioner.conf
provisioner.conf           per-server config, gitignored — created by `configure`
manifest.example           tracked template; copy to manifest yourself if you want it
manifest                   name -> repo-url -> optional branch, used by provision-all, gitignored
templates/                 nginx vhost + FPM pool + webhook vhost templates
lib/                       implementation
docs/                      task-oriented guides + security.md (design rationale, not how-to)
hook/                      unprivileged git-forge webhook listener (Python)
hooks/                     ops scripts run for every site (see hooks/README.md)
generated/                 sidecar configs + DB credentials (created at runtime)
logs/                      per-site provision/deploy logs (created at runtime)
```

Lives at `/opt/ddeploy`, root-owned (see "Quickstart"). Sites are
checked out under `$SITES_ROOT` (`provisioner.conf`, default
`/home/deploy/sites`) — a separate tree, owned per-site by each
`www-<name>` user.

## Accepted tradeoffs

Deliberate choices with a real downside; full reasoning in the linked
section.

- **Branch previews share the parent's database by default**, not an
  isolated copy — two previews with diverging schema changes can
  conflict with each other against that one database. The alternative
  (an isolated preview database) guarantees content a client enters is
  lost when the branch merges. See "Branch previews."
- **The `init-db` admin account has `GRANT ALL ON *.*`** on the database
  server, not scoped to just the databases this tool manages — MySQL has
  no clean "can `CREATE DATABASE` and `GRANT` on what it creates, but
  nothing else" role. See "Database server."
- **`deploy --rollback` moves code, not schema** — a database migration
  a later deploy already ran forward is not undone by rolling the code
  back past it. See "Rolling back."

## Testing

`docker/` runs the actual provisioner — init, init-db, provision, deploy
(including rollback), git-push webhooks, branch previews, backup/restore,
doctor, remove — against real systemd, nginx, PHP-FPM, MariaDB, sshd, and
object storage in disposable containers. See `docker/README.md`.
`docker/test/run.sh` is the entry point.

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

- **Secrets/credential rotation** — a site's DB password, once
  generated, lives in plaintext on disk indefinitely, protected only by
  Unix file permissions, with no command to rotate it. The shared
  basic-auth password already has a rotation path (delete the htpasswd
  file, re-run `init`); per-site DB credentials don't.

