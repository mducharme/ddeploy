# ddeploy

Provisions and deploys PHP sites on Ubuntu 24.04: nginx, one PHP-FPM
pool per site, one Linux user per site, one MariaDB database per site, a
shared wildcard TLS certificate, and an on-server frontend build (Node
via nvm, per-site version). No containers. Reads a project's own
`.ddev/config.yaml` as config; never runs DDEV itself.

Built for staging/QA/client-review — no staging→production promotion
path. Optional web UI:
[webddeploy](https://github.com/mducharme/webddeploy), driven through `ddeploy api`. One web server per project; a database server can be
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
[info]  resolved: php=8.3 node=20 build=true docroot='web' hostnames=[alt-testsite]
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
ddeploy provision <name> <repo-url>         # clone, config, vhost/FPM/DB, first deploy
```

`init` installs the **`ddeploy` command** (`/usr/local/bin/ddeploy`), so
from then on it's `ddeploy <command>` from any directory, no `sudo`
needed — it adds sudo itself (as `sudo <checkout>/provision.sh ...`, so
a sudoers rule scoped to provision.sh still matches), and skips it for
`-h`/`help`. Bash completion for commands and site names comes with it.
`./provision.sh <command>` works too. After moving the checkout, run
`sudo ./provision.sh install-cli` to point the command at its new path.

`configure` + `init` are also just `./install.sh` (skips `configure` if
`provisioner.conf` already exists).

From there: `deploy <name>` on every push (or set up "Deploy on git
push"), `list` to see the fleet, `doctor` to check on it.

**Putting a project on the server?** Follow
[docs/new-project.md](docs/new-project.md): provision, environment,
importing the database and uploads, checks, troubleshooting, then each
optional feature (custom domain, auto-deploy, previews, backups, Slack).

## Commands

`ddeploy <command>` (or `./provision.sh <command>` from the checkout):

```
configure                     create/update provisioner.conf (see -h)
init                          set up a web server (packages, PHP, TLS, firewall)
init-db                       set up a dedicated database server
provision <name> [repo-url]   add a site
deploy <name> [--rollback [<sha>] | --force] [--history] [--if-changed]   new release + re-apply vhost/FPM config + run deploy steps (see -h)
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
logs <name> [-n N] [-f]       tail a site or fleet log; `logs webhook` / `logs webhook-other` for git-push deliveries (see -h)
env <name> [KEY=value] [opts] show/edit a site's persistent .env (see -h)
notify <name> [opts]          per-site Slack/Discord channel for deploy notifications (see -h)
doctor [-v] [name]            health check: nginx/PHP-FPM/DB/disk/certs (see -h)
node-gc [--yes]               remove Node versions nothing uses any more (see -h)
init-web [--disable]          web UI user, sudoers rule and vhost (see "Web UI")
api <verb> [args]             JSON interface the web UI drives (see "Web UI")
install-cli                   (re)install the ddeploy command + bash completion (init does this)
```

`init`, `init-db`, `provision`, `deploy`, `remove`, `backup-uploads`,
`backup-database`, `logs`, `env`, `notify`, `node-gc`, `install-cli`, `init-web`, `api`, and the `*-preview`/`prune-previews` commands need root.

## Configuration

Six places a setting can come from, in increasing order of "how
permanent is this":

| Where                                            | What goes here                                                                              | Lives in                               | Git-tracked                           |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- | -------------------------------------- | ------------------------------------- |
| `provisioner.conf`                               | Server-wide defaults — every site on this box starts from these                             | `/etc/ddeploy/` on the server          | no — created by `./provision.sh configure` from the tracked `provisioner.example.conf` |
| `.ddev/config.yaml`                              | Real DDEV fields: `php_version`, `nodejs_version`, `docroot`, `upload_dirs`, `hooks.post-start`, `database.*` | the client's repo                      | yes — it's DDEV's own file            |
| `.ddeploy/config.yaml`                           | ddeploy-only per-site keys that aren't real DDEV fields (below)                             | the client's repo, sibling to `.ddev/` | yes                                   |
| `<name>.yaml` (in `/var/lib/ddeploy/generated/`) | Sidecar ddeploy writes itself for a repo with no `.ddev/config.yaml` yet                    | the server                             | no                                    |
| `<name>.override.yaml` (same place)              | Operator override (`ddeploy override`, see "Overriding a project's config" below), wins over both of the above | the server                             | no                                    |
| CLI flags (`--db`, `--hostnames`, `--auth`, ...) | A one-off override for this run of `provision`, always wins                                 | the terminal                           | n/a                                   |

**Precedence, per key:** CLI flag on `provision` > operator override
(`ddeploy override`) > `.ddeploy/config.yaml` > `.ddev/config.yaml`
(or the sidecar, whichever exists). `--db`, `--hostnames`,
`--custom-domains`, `--upload-dirs`, `--deploy-cmd` apply on every run
they're passed, not just the first (`provision -h`).

**Takes effect on next `deploy`:** `php_version`, `nodejs_version`,
`build`, `docroot`, `basic_auth`, `client_max_body_size`,
`fpm_max_children`, `php_ini`, `additional_hostnames`,
`additional_fqdns`. **`provision`-time only:**
`--db`, `--upload-dirs`, `--deploy-cmd`, `--custom-domains`, and the
fallback fields.

### Resolving a new site

`provision` resolution order:

1. `.ddev/config.yaml` in the repo, if present.
2. `/var/lib/ddeploy/generated/<name>.yaml` sidecar from a previous run.
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
`db_env_scheme`, `queue_workers`, `schedule`, `preview_branches`, and `build` aren't real
DDEV fields. Declare them in `.ddeploy/config.yaml` instead, git-tracked,
sitting next to `.ddev/config.yaml`:

```yaml
db_env_scheme: charcoal
nodejs_version: "22"        # also read from .ddev/config.yaml, .nvmrc — see "Frontend builds"
composer_dev: true          # keep dev packages in the default composer step — see "Deploy hooks"
build:
  script: build
  outputs:
    - web/dist
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
preview_branches:            # previews from a plain push, no PR needed — see "Branch previews"
  - feature/*
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
ddeploy override <name> key=value [key=value ...]
```

Writes `/var/lib/ddeploy/generated/<name>.override.yaml` (server-side only). Highest
precedence of the three config sources. Takes effect on the site's next
`deploy` (re-run it yourself to apply immediately).

Scalar keys: `basic_auth`, `client_max_body_size`, `fpm_max_children`,
`db_env_scheme`, `security_headers`, `static_cache`,
`deny_php_in_uploads`, `db_backup_retention_days`, `nodejs_version`,
`build` (`false` turns a site's frontend build off; `true` just
doesn't), `composer_dev` (`true` keeps dev packages in ddeploy's default
composer step). List keys,
space-separated (quote the value): `additional_hostnames`,
`additional_fqdns`, `persistent_files`, `auth_exempt_paths`,
`backup_exclude`, `deny_php_paths`, `preview_branches`. Not supported here (need
`.ddeploy/config.yaml` in the repo): `redirects`, `php_ini`,
`queue_workers`, `schedule`, `hooks`, a `build:` map — structured data, or (for `queue_workers`)
a command likely to contain its own spaces.

```
ddeploy override client "additional_hostnames=alt-name alt2"
ddeploy override client --show      # print current overrides
ddeploy override client --unset basic_auth
ddeploy override client --clear     # remove every override
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
state; `--no-seed` for an empty database. An isolated preview's database
and user are always named after the preview itself, even when the
repository's config declares `database.name`/`database.user` (that names
the parent's). `remove-preview --purge-db` refuses to drop anything that
is the parent's database or user.

**Each preview has its own config, seeded from its parent's** at
creation — never overwritten afterwards, so tune a preview without
touching the parent:

- `.env` (or `config/config.local.json`): a copy of the parent's, with
  DB credentials rewritten (the parent's DB in shared mode, a fresh
  database user in isolated mode) and URLs pointed at the preview —
  every literal `https://<project>.$BASE_DOMAIN` is replaced, and
  `PRIMARY_SITE_URL` (Craft) / `APP_URL` (Laravel) is set to the
  preview's URL outright. Lives in the persistent store like any site's
  (`$PERSISTENT_ROOT/<preview>/.env`), so `deploy-preview`'s reset can't
  touch it. Edit with `ddeploy env <preview> ...`.
- `/var/lib/ddeploy/generated/<preview>.override.yaml`: a copy of the parent's operator
  overrides (`ddeploy override`), minus hostnames. Edit with
  `ddeploy override <preview> ...`.

A preview never inherits the parent's `additional_hostnames` /
`additional_fqdns` (those belong to the parent's vhost); give it one
with `override <preview> additional_hostnames=...` if needed.
`remove-preview --purge-files` deletes both files with the preview.

**Previews without a PR (opt-in).** List branch patterns under
`preview_branches:` in `.ddeploy/config.yaml` (or `ddeploy override
<name> "preview_branches=feature/* fix/*"`), and a push to a matching
branch creates or updates its preview, no PR needed; deleting the branch
removes it. `*` matches across `/`, so `feature/*` covers
`feature/a/b`, and `*` alone is every branch. The branches a site from
that repo deploys (`main`, `develop`...) never get a preview, `*` or not.
These previews get no PR comment (`ddeploy preview-url <project>
<branch>` prints the URL), and every matching push runs a build and,
with the default shared database, the branch's migrations against the
parent's data — prefer narrow patterns over `*`.

For every site at once, set `PREVIEW_BRANCHES="feature/* fix/*"` in
`provisioner.conf`. A site's own `preview_branches` replaces it, and an
empty one turns it off for that site: `preview_branches: []` in the
repo, or `ddeploy override <name> "preview_branches="`
(`--unset preview_branches` goes back to the server default).

`deploy-preview` does `git fetch && reset --hard`, not `--ff-only pull`
— previews stay in-place, not atomic releases. Like `deploy`, it then
re-applies the preview's FPM pool and vhost from its config (a
`php_version` change on the branch, or `ddeploy override <preview> ...`,
takes effect on the next one), and re-owns whatever the reset changed.

A preview's name is `<project>-<branch>`, so it can collide with a
regular site (project `client`, site `client-shop`, branch `shop`) or
with another project's preview. Every preview command — and the webhook —
refuses to act on a name that isn't this project's preview, so a PR can
never touch an unrelated site; the webhook log says
`skip <name>: that name is already a regular site...`. Rename the branch
to get a preview. Basic auth defaults **on**
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

Previews are transparent to the general commands: `list` shows each
site's `BRANCH` and marks previews (with their DB mode) in `PREVIEW`;
`deploy-all` skips previews; plain `remove <name>` on a preview
delegates to `remove-preview` automatically.

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
rejected later, asynchronously — so the forge's delivery log shows it
as delivered. Check `ddeploy logs webhook` instead (and turn on the
`webhook-rejected` notification, see "Notifications").

**The webhook log** (`ddeploy logs webhook [-n N] [-f]`, file
`/var/log/ddeploy/webhook.log`) has every delivery that concerns a site on this
server, every rejected delivery, and one line per action each led to,
tagged with the forge's delivery id (first 8 chars — the same id
GitHub/Bitbucket show in their webhook UI):

```
2026-09-30T14:02:11Z [3f9a1c02] github push repo=org/site branch=main by=someone from=140.82.115.4 -> accepted: push_head
2026-09-30T14:02:11Z [3f9a1c02] deploy site: started
2026-09-30T14:02:58Z [3f9a1c02] deploy site: OK @ a1b2c3d (47s)
2026-09-30T14:05:40Z [77e0b5d1] github push repo=org/site branch=feature-x -> accepted: push_head
2026-09-30T14:05:40Z [77e0b5d1] skip site: it deploys 'main', push was to feature-x
2026-09-30T14:09:03Z [c41d9e8a] github push from=203.0.113.9 -> REJECTED: HMAC verification failed (...) — dropped
```

The webhook is org-wide, so most deliveries are for repos with no site
here; those, and events with nothing to do (pings, branch deletions, PR
labels), get one line each in `ddeploy logs webhook-other`
(`/var/log/ddeploy/webhook-other.log`, trimmed automatically past ~2 MB):

```
2026-09-30T14:03:20Z [9d1e44b0] github push repo=org/other-project branch=main -> accepted: push_head — no site on this server uses github.com/org/other-project
2026-09-30T14:10:00Z [0b6f2a7e] github ping repo=org/site -> ignored: nothing to do for event 'ping'
```

A failed action logs `FAILED (exit N, 12s)` with the tail of the site's
own log; `ddeploy logs <site>` has the full build output. Requests
refused before they're queued (no signature header, oversized body)
only show up in `journalctl -u ddeploy-hook`.

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
"Default branch") → `deploy <name> --if-changed`. Other branches ignored.
- PR opened/synced (same-repo only) → `provision-preview` or
`deploy-preview --if-changed`.
- Push to a branch matching the site's `preview_branches` (and not a
branch any site from that repo deploys) → the same, no PR needed.
- Branch deleted → `remove-preview` of that branch's preview, if it has
one (however it was created).
- `--if-changed` skips the deploy when the live code is already at the
branch's remote tip. Several pushes queued behind one slow build
collapse into one deploy of the latest commit, and a forge redelivering
a push is a no-op. A preview whose last deploy failed is always
redeployed.
- PR closed/merged/declined → `remove-preview --purge-files`
(`--purge-db` too if isolated).
- Fork PRs refused.
- Unprovisioned repo → `202` no-op.

If `PREVIEW_COMMENT_CREDENTIALS` is set (chmod 600, `GITHUB_TOKEN` and/or
`BITBUCKET_USER`+`BITBUCKET_APP_PASSWORD`), a successful preview upsert
posts/updates a PR comment `Preview: https://<slug>.$BASE_DOMAIN`. A
failed comment is a warning, not a failed deploy.

`ddeploy logs <name> [-n N] [-f]`, `ddeploy preview-url
<project> <branch>` — useful when CI is the deploy trigger instead of
the webhook.

`ddeploy deploy` over SSH is still valid. For repos that can't use
an org/workspace webhook:
`[examples/ci/github-action](examples/ci/github-action/action.yml)` or
`[examples/ci/bitbucket-pipelines.yml](examples/ci/bitbucket-pipelines.yml)`.

### Default branch

By default a site tracks whatever branch it was cloned on (the remote's
default). To pin a specific branch instead:

```
ddeploy provision <name> --branch develop
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

### Force-pushed branches

A deploy fast-forwards to the branch's tip. If the branch was rewritten
since the last deploy (force-push, rebase, amend), the live commit is no
longer on it, and the deploy fails without touching what's live:

```
'mysite': origin/main was force-pushed (live f24c640 is no longer on it, tip is now 9a1b2c3) — …
```

`deploy <name> --force` deploys the new tip anyway. On a staging server,
where branches are rewritten routinely, `ALLOW_FORCE_PUSH="true"` in
`provisioner.conf` does that on every deploy, webhook ones included —
with a `[warn]` and a line in the site log each time. Either way it's an
ordinary new release: the previous one stays on disk, so
`deploy <name> --rollback` returns to the pre-force-push commit.
Previews always follow force-pushes.

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

Normal sites only — previews get their own `.env` in the store (see
"Branch previews"), but their uploads stay disposable (isolated) or are
the parent's own (shared).

**Editing `.env`.** `<site>/current/.env` is a symlink into the
persistent store, and a few editing habits break on that: `sudoedit`
refuses symlinks outright, and anything that writes a temp file and
renames it over the path replaces the link with a plain file in that
one release — the next deploy re-links it and your edit is gone. Use:

```
ddeploy env <name>                        # show (secrets masked; --reveal for all)
ddeploy env <name> KEY=value OTHER=value  # set
ddeploy env <name> --unset KEY
ddeploy env <name> --edit                 # $EDITOR on the real file
ddeploy env <name> --path                 # where it really is
```

Or edit `$PERSISTENT_ROOT/<name>/.env` directly. Changes are live on
the next request (PHP reads `.env` per request) unless the app caches
its config.

## Data protection

### Backups

Disaster-recovery only — one-way copies to S3-compatible object storage
on a schedule, via `rclone`. Config in `provisioner.conf`:

```
BACKUP_CREDENTIALS="..."   # path to a file (chmod 600), see below
```

`BACKUP_CREDENTIALS` points at a file containing:

```
BACKUP_ENDPOINT="https://nyc3.digitaloceanspaces.com"
BACKUP_BUCKET="..."        # the bucket / Space name
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
  Key pair under "API" → "Spaces access keys," account-wide. Not the
  Space's "Origin Endpoint" (`https://<space>.<region>...`): with the
  bucket name in the endpoint, backups are filed under
  `<bucket>/<bucket>/` and can't be listed or restored. `configure
  backups` offers the corrected endpoint, and `doctor` fails on it with
  the fix.
- **AWS S3**: `https://s3.<region>.amazonaws.com`. IAM key scoped to
  `s3:GetObject`/`PutObject`/`DeleteObject`/`ListBucket`.
- **Any other S3-compatible** (MinIO, Backblaze B2, Wasabi, ...): same
  three fields.

One set of credentials + one bucket covers every project. Create the
bucket (Space) first: ddeploy never creates it. That way a key limited to
that one bucket works (DigitalOcean's per-Space keys, an S3 policy without
`CreateBucket`). The key needs to list, read, write and delete objects in it.
(`BACKUP_BUCKET` used to live in `provisioner.conf`; that still works, but
the credentials file wins, and doctor warns if the two differ.)

**Uploads** (`BACKUP_ENABLED`, `BACKUP_SCHEDULE`, default hourly):
`upload_dirs` synced to `<bucket>/<name>/<dir>`. Sites with none
declared are skipped. `backup-uploads [name]` to sync on demand.
**Versioned:** whatever a sync would overwrite or delete in that mirror is
moved to `<bucket>/<name>/.versions/<run>/<dir>/` instead. A file deleted
or broken on the site is still recoverable from the run that caught it,
for `UPLOADS_BACKUP_VERSIONS_DAYS` (default 30; `0` = plain mirror, as
before). Without this, a deletion reached the backup within the hour.

**Database** (`DB_BACKUP_ENABLED`, `DB_BACKUP_SCHEDULE`, default hourly):
`mysqldump --single-transaction`, gzipped, to `<bucket>/<name>/db/`.
Dumps older than `DB_BACKUP_RETENTION_DAYS` (default 7; per site:
`db_backup_retention_days`) pruned each run. Dumps moved to
`<bucket>/<name>/db-kept/` ("keep" in the web UI) are never pruned.
`backup-database [name]` to dump on demand.

**History.** Every site's backup, scheduled or on demand, is an event
in its history (`backup-database` / `backup-uploads`, with the dump name
or what was synced, or the error). With a site name,
`backup-database <name>` and `backup-uploads <name>` are full runs, with
their own output log.

**Restoring from a backup**, each taking a local snapshot first so it can be
undone:

```
db-import <name> --from-backup <dump> --yes                    database from a dump (db/ or db-kept/)
uploads-import <name> --dir <d> --from-backup --yes            folder from the mirror (replaces it)
uploads-import <name> --dir <d> --from-backup --version <run> --yes   files that run overwrote/deleted (merged back)
```

Downloads go into a staging folder owned by the site and are then
moved into place, so restored files belong to the site's user.
(`restore-uploads` / `restore-database` still work as before.)

`init` installs `rclone`/`cron` and writes
`/etc/cron.d/ddeploy-backup-uploads` / `-database` (root). Not in
`crontab -l` for any user — check `cat
/etc/cron.d/ddeploy-backup-uploads` or `ddeploy doctor`.

Both skip shared-mode previews (uploads/database are the parent's).

### Database snapshots and imports

```
db-snapshot <name> [--reason <word>]     local safety dump (DB_SNAPSHOT_KEEP per site, default 5)
db-snapshot <name> --list
db-import <name> --from-file <dump.sql[.gz]> --yes   replace the database with a dump
db-import <name> --snapshot <id> --yes               ...or with one of its snapshots
```

`db-import` snapshots the current database first (`--no-snapshot` to
skip), then drops every table and view and loads the dump as the site's
own DB user — a replace, not a merge (`--keep-existing` to load over what's
there). It prints the command that undoes it. Snapshots are local and
root-only (`/var/lib/ddeploy/db-snapshots/<site>/`), a short-term undo,
not a backup. A shared-mode preview's database is its parent's: importing
there changes the parent's. The web UI's Database tab drives exactly these
(upload, download, snapshots, restore).

### Uploaded files: import, snapshots, download

```
uploads-import <name> --dir <upload_dir> --from-file <archive> --yes [--mode merge|replace]
uploads-import <name> --dir <upload_dir> --from-ssh <user@host:path> [--ssh-port n] --yes [--mode merge|replace]
uploads-import <name> --snapshot <id> --yes          put a folder back as it was
uploads-snapshot <name> [--dir <upload_dir>]         hardlink snapshot (free until files change)
fetch-key [--forget <host>]                          the key --from-ssh logs in with
uploads-snapshot <name> --list
```

Unpacks a `.zip`, `.tar` or `.tar.gz` into one of the site's
`upload_dirs` (the persistent folder every release links to). `merge`
(the default) adds files and overwrites same-path ones; `replace` makes the
folder exactly the archive. A snapshot comes first either way
(`UPLOADS_SNAPSHOT_KEEP` per site, default 3, kept root-only under
`$PERSISTENT_ROOT/<site>/.uploads-snapshots/`). An archive whose only
top-level folder is named like the target (someone zipped the `uploads`
folder itself) is unwrapped.

The archive is untrusted input, so `lib/uploads_extract.py` checks every
member before writing anything: only plain files and folders (no links,
devices, absolute or `..` paths), declared sizes within the free disk
space. It then unpacks **as the site's own user** into a staging folder,
which is moved or hardlinked into place. `__MACOSX/`, `.DS_Store` and
`Thumbs.db` are skipped. The web UI's Files tab uses the same command for
dropped folders: the browser packs them into a tar, which arrives as a
single upload.

**Copying from another server** (`--from-ssh`, the Files tab's "Copy from
another server"): this server pulls the folder with rsync over SSH. The
connection goes out, like git and backups, so ddeploy's firewall needs
nothing; the old server must accept SSH from this one. It logs in with
one server-wide key, `/etc/ddeploy/fetch-key` (created by `fetch-key` or
on first use). On the old server, bind it to the folder, read-only:

```
command="rrsync -ro /var/www/site/uploads",restrict ssh-ed25519 AAAA… ddeploy-fetch@<host>
```

`rrsync` ships with rsync 3.2.4+ (Ubuntu 22.04+, Debian 12+). With it, the
copy's path is relative to that folder: give `user@host:` with an empty
path. Host keys are never accepted blindly. The web UI shows the
fingerprint, and the copy only runs once an admin has confirmed it
(`/etc/ddeploy/fetch-known-hosts`). A different key later is refused
until forgotten (`fetch-key --forget <host>`). rsync copies into a
root-only staging folder with no links, devices or special files, and
fixed modes (folders 2750, files 640), after a dry run checks the size
against free disk space. Then the usual snapshot and merge/replace apply.

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
doctor [-v] [name]
doctor --snapshot
```

Read-only checks: nginx config/service, disk space, database server,
certificate expiry, and whether any directory above the checkout is
writable by a non-root user (who could then replace the code root runs —
docs/security.md); per site: vhost enabled, PHP-FPM pool running, last
deploy, DB connection test using the **site's own** credentials (not
admin), and whether the site actually answers: a GET of `/` through this
server's own nginx (`http` — 2xx/3xx/401 ok, other 4xx warn, 5xx or no
answer fail). No name: every provisioned site, previews included.

Webhook listener, uploads backup, database backup, `prune-previews`:
always reported, `[off] ... disabled (...)` when off — never silent. When
a backup is on: bucket reachability, recoverable dump count + age, and
whether uploads have synced anything at all (not a freshness check).
Shared-mode preview: skipped (covered by the parent's row).

Output is a **Server** section (every check) and a **Sites** section:
one line per site with its worst status and what's deployed
(`branch @ sha (date)`), expanded only where something is `[warn]` or
`[fail]` — `-v` expands every site, and `doctor <name>` always shows
all of that site's checks. Colored on a terminal, plain when piped
(or with `NO_COLOR`).

Prints `[ok]`/`[warn]`/`[fail]`/`[off]` per check, exits nonzero on any failure —
wire into cron/monitoring. One site's malformed config only produces one
`[fail]` row, doesn't abort the rest.

`NOTIFY_WEBHOOK` in `provisioner.conf` pages on `[fail]` (not `[warn]`).
See "Notifications."

**Scheduled snapshot.** `init` installs `/etc/cron.d/ddeploy-doctor`,
running `doctor --snapshot` on `DOCTOR_SCHEDULE` (default every 10
minutes, log in `doctor.log`). It checks every site and stores the
result under `/var/lib/ddeploy/index/doctor/` (root-only) instead of
printing a table: `api sites` then carries each site's last `health` and
`health_checked_at`, and `api doctor --snapshot` returns the stored
checks without running any. It pages `NOTIFY_WEBHOOK` only when a check
**starts** failing, and again when it recovers — a site down for a day
pages once. Every `api doctor` refreshes the snapshot too.

## Web UI

[webddeploy](https://github.com/mducharme/webddeploy) is a web front end
for admins: the fleet, deploy and preview history, live run output, logs,
`doctor`, starting a deploy, provisioning a project. Google SSO.

**Setup.** `WEB_ENABLED=true` in `provisioner.conf`, then `ddeploy
init-web` (`init` runs it too when enabled). It creates `WEB_USER`
(default `ddeploy-web`), gives it exactly one sudoers rule —
`provision.sh api *` — and an nginx vhost for `WEB_HOSTNAME` (default
`ddeploy.$BASE_DOMAIN`, on the wildcard cert) proxying to `WEB_LISTEN`
(default `127.0.0.1:8790`). The app itself installs from its own repo.
`doctor` reports it. `init-web --disable` removes the rule and vhost.
Why the boundary is drawn there: [docs/security.md](docs/security.md#the-web-ui-reaches-root-through-one-allowlisted-subcommand).

**`ddeploy api`.** One JSON object per call (`{"api_version": 1, ...}`,
or `{"error": {"code", "message"}}` and exit 1). `ddeploy api -h` lists
every verb. Usable from scripts too.

- Read: `info`, `sites`, `site <name>`, `events`, `previews <project>`,
  `doctor [name]`, `logs [<name>]`, `inspect-repo <url>`, `env <name>`,
  `branches <name>`, `commits <name> <from> <to>`, `db info|credentials
  <name>`, `db dump <name>` (gzipped SQL on stdout), `uploads <name>`,
  `uploads download <name> --dir <d>` (.tar.gz on stdout), `backups
  <name>`, `backups download <name> --file <dump>`, `run show|log <id>`,
  `config` (server settings; secrets masked), `files <name> [--read
  <path>]` (the persistent config files: charcoal's
  `config/config.local.json`, `persistent_files` — not `.env`).
- Write (each needs `--actor <email>`): `run start deploy|rollback|
  provision|db-import|db-restore|db-snapshot|preview-create|
  preview-deploy|preview-remove|uploads-import|uploads-fetch|uploads-restore|
  uploads-snapshot|backup-database|backup-uploads|backup-restore-db|
  backup-restore-uploads`, `fetch-test` (host-key check, `--accept
  <fingerprint>` to remember it, then a dry run), `fetch-key forget`,
  `files <name> --write <path>` (content on stdin; checked as
  JSON/YAML/`php -l`/env, refused if it changed since `--expect-sha`,
  previous version kept root-only under `/var/lib/ddeploy/file-versions/`)
  and `files --restore`,
  `backups keep|unkeep|delete`, `run cancel <id>`, `env
  <name> --apply` (values on stdin, never argv), `settings <name>`
  (operator overrides and the tracked branch — every `override` key except
  `db_env_scheme` and `persistent_files`), `config set` (`KEY=value` lines
  on stdin: an allowlist of `provisioner.conf` keys — site defaults,
  previews, backup schedules and retention, notifications, limits — each
  validated; the file is backed up to `provisioner.conf.bak-<time>` first
  and restored if it no longer loads; cron and the web vhost are rewritten
  when a key needs it; changes logged to `server-config.log`). Provision
  takes a fixed flag set (no `--deploy-cmd`).

**Runs and history** (CLI, webhook and web alike — not just the UI):

- Every `deploy`, `provision`, `provision-preview`, `deploy-preview` gets a
  run id; its full output lands in `/var/log/ddeploy/runs/<id>.log`
  (kept `RUN_LOG_RETENTION_DAYS`, default 30) — not just the last 25
  lines in the site log on failure.
- Start and end of each run (and `remove-preview`) are appended to
  `/var/lib/ddeploy/events/<site>.jsonl`: kind (deploy/rollback/...),
  outcome (succeeded/failed/skipped), who (`web (<email>)`, `manual
  (<sudo user>)`, `webhook [<id>]`), SHAs, duration, error line. That's
  what history views read; removed previews stay in it. `.deploys` is
  unchanged (rollback still reads it).
- `api run start` doesn't run anything in the web request: it starts a
  transient systemd unit (`ddeploy-run-<id>`), so a deploy outlives the
  request and a restart of the UI.
- `api run cancel` stops a run the web UI started (its systemd unit). A
  run that's stopped — that way, by `systemctl stop`, or a reboot's
  SIGTERM — still records a `failed: interrupted` event. One that never
  recorded an end at all (SIGKILL, power loss) shows as "no result" in the
  UI after 3 hours.
- Config changes are events too (`env-change`, `settings-change`, keys
  only — never values), from the api (`env --apply`, `settings`) and
  the CLI (`env`, `override`) alike, so a site's history shows who
  changed what alongside its deploys. `remove` records a `remove` event.
- **The fleet feed.** Every event also lands in `events/_fleet.jsonl`
  with a fleet-wide `seq` that only grows (written under one lock, so
  concurrent runs never lose or reorder a line). `api events` with no
  `--site`/`--project` reads that tail; `api events --after <seq>` returns
  only newer events, oldest first, with `"seq"` (where to continue) and
  `"truncated"` (the cursor fell out of the trimmed tail: reload instead).
  That's the change feed webddeploy's mirror follows; `api info` lists
  `event_feed` and `doctor_snapshot` under `capabilities`.
- Event files are trimmed to their newest 4000 lines past 2 MB.
- **The read index.** `api sites`, `api site` and `list` read each site's
  row from `/var/lib/ddeploy/index/` (root-only), rebuilt only when one
  of its inputs changed: a fingerprint of every file the row is computed
  from (configs, overrides, `package.json`/lockfiles, `.nvmrc`, the
  `current` symlink and HEAD, the event file, `provisioner.conf`...), all
  sites' from a single `stat`. Nothing has to remember to refresh it: a
  changed file is a stale row. Reads never wait on a running deploy.
- **Per-site web server logs.** Each site's vhost writes its own
  `/var/log/nginx/<name>.access.log` and `<name>.error.log` (from the
  site's next deploy on). PHP errors land in the error log too, since nginx
  records what PHP-FPM writes to stderr. They're rotated with the rest of
  `/var/log/nginx/*.log`. `ddeploy api logs` reads them as
  `<name>.access` / `<name>.error`, plus the server-wide
  `nginx_access`, `nginx_error` and `phpX.Y_fpm` (pool warnings like
  "max_children reached").
- **Runs on one site are serialized**, whoever starts them: `provision`,
  `deploy`, `remove` and the preview commands take the site's lock (the
  one webhook deploys always took). A second run waits, and says so in its
  output, instead of racing the first.

## Notifications

Set `NOTIFY_WEBHOOK` (`provisioner.conf`) to a Slack incoming webhook
(Slack → Apps → Incoming Webhooks → pick a channel → copy the URL), a
Discord webhook, or any URL accepting a JSON POST. Credential — don't
commit it. Empty (default) is off. Try it: `ddeploy notify --test`.

`NOTIFY_EVENTS` picks what's sent (default: all of them):

| Event              | When                                                                  |
| ------------------ | --------------------------------------------------------------------- |
| `deploy-success`   | `deploy`, `deploy-preview`, `provision` finished — URL, commit, duration, and who triggered it (`webhook [id]` or the sudo user) |
| `deploy-failure`   | any of those failed — the error line and where the full log is       |
| `preview-created`  | a branch preview is up, with its URL                                  |
| `preview-removed`  | a branch preview was torn down                                        |
| `webhook-rejected` | a delivery failed HMAC verification — almost always a wrong secret in the forge's webhook settings |

Slack and Discord get colored messages (green/red); any other URL gets a
flat JSON object (`text`, `content`, `event`, `site`, `status`, ...).
`webhook-rejected` won't repeat for `NOTIFY_COOLDOWN` seconds (default
3600); deploy messages are never rate-limited.

**Per-site channel.** A site's own events can also go to a channel of
its own — a client's, say — on top of the server-wide one:

```
echo "$SLACK_URL" | ddeploy notify <name> --set-url   # or run it and paste at the prompt
ddeploy notify <name> --test
ddeploy notify <name> --unset
```

Stored root-only in `/var/lib/ddeploy/generated/<name>.notify-url` (read from stdin so it
never lands in shell history or `ps`). Previews use their parent's
channel unless given their own.

**Failure paging** for unattended commands (`backup-uploads`,
`backup-database` cron, `prune-previews`, `doctor`) goes to
`NOTIFY_WEBHOOK` only, regardless of `NOTIFY_EVENTS`; the same
command+site won't page again until `NOTIFY_COOLDOWN` passes.

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
| `none`     | nowhere (e.g. plain WordPress) | saved root-only to `/var/lib/ddeploy/generated/<name>.dbpass`, never logged           |

`charcoal` creates `config/config.local.json` if it doesn't exist,
reuses its own `default_database` key if already set.

`craft` also gets the other keys Craft won't boot without, **added only
when missing** (never overwritten, so an existing `.env` is left alone):
`CRAFT_APP_ID`, `CRAFT_SECURITY_KEY` (random), `CRAFT_ENVIRONMENT=staging`,
`PRIMARY_SITE_URL=https://<name>.$BASE_DOMAIN`. If the database comes
from another environment, set that environment's security key
(`ddeploy env <name> CRAFT_SECURITY_KEY=...`) — anything Craft
encrypted with the old one won't decrypt otherwise.

**Lost the `.env`, or the password in it?** Re-run `provision <name>`
(no repo URL needed). It reads the password from `.env`, generates a new
one if it's missing, and always `ALTER USER`s MariaDB to match — the
database itself is untouched.

### Deploy hooks

`.ddev/config.yaml`'s `hooks.post-start` replays on every deploy, as
`www-<name>`, under the site's pinned PHP version. `exec`/`composer`
steps run; `exec-host` steps are logged and skipped. A step referencing
`ddev` or `/var/www/html` is skipped with a warning.

**Steps for the server only** go in `.ddeploy/config.yaml` — DDEV never
reads it, so they don't run on `ddev start`. Same step format:

```yaml
hooks:
  post-deploy:          # every deploy, after everything else (frontend build included)
    - exec: php craft migrate/all --interactive=0
    - exec: php craft project-config/apply --force
  post-provision:       # once, after a site's or preview's first deploy
    - exec: php craft clear-caches/all
  post-start:           # optional: replaces .ddev's hooks.post-start on the server
    - composer: install --no-dev --optimize-autoloader
```

So a deploy runs: the regular steps (`.ddeploy`'s `post-start` if set,
else `.ddev`'s, else the default composer step below), the frontend
build, then `post-deploy` — and on the first deploy, `post-provision`.

No `hooks.post-start` declared, but the repo has `composer.json`:
`composer install --no-dev --optimize-autoloader` runs by default (DDEV
often installs implicitly on `ddev start`, which this tool never sees).
The same production-style install is what ddeploy uses whenever it picks
the composer step itself (a detected CMS, `--deploy-cmd`). A project that
needs its dev packages on the server sets `composer_dev: true` in
`.ddeploy/config.yaml` (or `ddeploy override <name> composer_dev=true`).
This only fills a completely absent `hooks.post-start` (in both files) —
declared steps, `composer` ones included, run exactly as written, and
declaring steps without `composer` is treated as deliberate. Every step runs with
`COMPOSER_NO_INTERACTION=1`, so a composer prompt fails the deploy
instead of hanging it.

Two more extension points:

- `.ddeploy/post-provision.sh` / `.ddeploy/post-deploy.sh` in the client
repo — scripts, for anything too long for a step. Run as `www-<name>`,
after the steps above: `post-provision.sh` once after the first deploy,
`post-deploy.sh` every deploy.
- `/etc/ddeploy/hooks/post-provision.d/*.sh` / `/etc/ddeploy/hooks/post-deploy.d/*.sh` on the
server — run as root, for every site. See `hooks/README.md`.

### Frontend builds

Node comes from one shared nvm install at `NVM_ROOT` (default
`/opt/nvm`), root-owned, pinned to a verified nvm commit by `init`.
Every step that runs as the site user — `hooks.post-start`,
`.ddeploy/*.sh`, queue workers, `schedule` — gets the site's Node on
`PATH` next to its pinned PHP, so an existing `exec: npm run build` hook
just works.

**Which Node version**, first match wins:

1. `ddeploy override <name> nodejs_version=20`
2. `nodejs_version` in `.ddeploy/config.yaml`
3. `nodejs_version` in `.ddev/config.yaml` (DDEV's `auto`, or empty,
   falls through to the next)
4. `.nvmrc` / `.node-version` (in `build.path`, then the repo root)
5. `DEFAULT_NODE` (`provisioner.conf`)

`22`, `22.11.0`, `lts/*`, `lts/jod` and `node` are accepted. A
major-only version uses the newest installed patch of that major; a
version nothing installed matches is installed on the spot
(`nvm install -b` — prebuilt binary, SHA-256-checked, never compiled
from source). `init` pre-installs `BASELINE_NODE` and refreshes it to
the newest patch release on every run.

**What gets built.** Automatic when the repo root's `package.json` has
a `build` script **and** a lockfile, unless `hooks.post-start` already
runs npm/pnpm/yarn itself. Or explicitly, in `.ddeploy/config.yaml`:

```yaml
build:
  path: web/themes/site      # dir with package.json (default: repo root)
  package_manager: auto      # auto | npm | pnpm | yarn
  install: true              # lockfile-exact install first
  script: build              # runs `<pm> run build` — or command: "..." instead
  env:
    VITE_BASE: /dist/
  outputs:                   # checked after the build: missing/empty fails the deploy
    - web/dist
  keep_node_modules: false
```

`build: false` turns it off (so does `override <name> build=false`);
`build: true` uses the defaults but fails the deploy if there's nothing
to build. The build runs as a deploy step right after the composer
steps (so it can read `vendor/`), before migrations/cache clears — in
the new release, before `current` switches. A failed install or build
leaves the previous release serving; a rollback to a release still on
disk reuses its build output instead of rebuilding.

**Package manager and install.** `package.json`'s `packageManager`
field wins, then the lockfile:

| Lockfile            | Install                                                    |
| ------------------- | ---------------------------------------------------------- |
| `package-lock.json` | `npm ci`                                                   |
| `pnpm-lock.yaml`    | `pnpm install --frozen-lockfile`                           |
| `yarn.lock`         | `yarn install --immutable` (berry) / `--frozen-lockfile` (classic) |

No lockfile: refused (commit one, or `install: false`) — a build that
resolves fresh dependencies every deploy isn't one a rollback can
reproduce. Bun isn't supported. pnpm and yarn run through corepack,
which honors (and hash-checks) a pinned `packageManager` version.

**Environment.** The install runs without `NODE_ENV` (devDependencies —
vite, webpack, tailwind — are needed to build); the build step gets
`NODE_ENV=production` unless `env:` sets it. `CI=true` for both. Package
caches (npm, pnpm store, corepack) live in the site's own `$HOME`, never
shared between sites. `node_modules` is deleted after a successful build
unless `keep_node_modules: true`.

**Limits.** `NODE_BUILD_TIMEOUT` (default 1200s) and
`NODE_BUILD_MEMORY_MAX` (default `2G`, a systemd scope; V8's heap is
capped at ¾ of it) apply to the install and the build separately — an
out-of-memory build is killed on its own, not php-fpm or MariaDB with
it.

**DDEV compatibility.** A `hooks.post-start` step that is exactly
`ddev npm|npx|pnpm|yarn ...` (typically `exec-host: ddev npm run build`)
is rewritten to a plain `exec` step. Any other `ddev` reference still
hits the guardrail.

**Reusing `node_modules`.** After a successful build, `node_modules` is
moved (not deleted) into a root-only cache outside the releases
(`$SITES_ROOT/.node-modules-cache/<name>/`), keyed on the lockfile,
`package.json`, `.npmrc`/`.yarnrc.yml`, the Node version and the package
manager. The next deploy with the same key moves it back and skips the
install entirely; any change is a normal install. `NODE_REUSE_MODULES=false`
turns it off. `remove`/`remove-preview` delete the site's cache.

**Not served.** Wherever a `package.json` sits under the docroot (the
whole repo when the docroot is the repo root, or a theme folder inside
it), nginx 404s its `node_modules/` and the package manifests/lockfiles.

**At provision time.** `provision <name> --node 20` pins the version
and `--no-build` turns the build off (`--build` undoes it); both are
saved as operator overrides, so later deploys keep honoring them. With
no `.ddev/config.yaml`, the interactive setup asks for a Node version
and whether to build when the repo has a `package.json`.

**Checking on it.** `doctor` reports the nvm install (pinned commit,
installed versions, missing `BASELINE_NODE`), each site's resolved Node
version, and its last build — with a `[warn]` when the most recent
build failed and an older release is still live. `list` has a `NODE`
column (`20+build` = Node 20, builds a frontend).

**Cleaning up old versions.** Versions accumulate: `init` refreshes
each `BASELINE_NODE` major to its newest patch (the old one stays), and
a site that changes `nodejs_version` leaves the previous one behind.
`node-gc` lists what it would keep (and why) and remove; `node-gc --yes`
removes it. Kept: `DEFAULT_NODE`/`BASELINE_NODE`, every site's and
preview's resolved version, anything a queue-worker/schedule wrapper or
a running process uses, and anything installed in the last hour. It
refuses to run while any site's config can't be resolved.

Branch previews build too, in place, as the same user their other
deploy steps run as.

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
appends to `/var/log/ddeploy/<name>.log`. See
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

A hostname no site claims (`typo.$BASE_DOMAIN`, a removed site, any
other domain pointed at the server) gets a 404 from a catch-all vhost
`init` installs (`/etc/nginx/sites-available/000-ddeploy-default.conf`),
never another site's content — nginx would otherwise fall back to
whichever site's vhost it loaded first.

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
provision.sh               entrypoint (`ddeploy` in /usr/local/bin runs this — see "Quickstart")
provisioner.example.conf   tracked template; `configure` copies it to /etc/ddeploy/provisioner.conf
manifest.example           tracked template; copy to /etc/ddeploy/manifest yourself if you want it
templates/                 nginx vhost + FPM pool + webhook vhost templates
lib/                       implementation
docs/                      task-oriented guides + security.md (design rationale, not how-to)
hook/                      unprivileged git-forge webhook listener (Python)
hooks/                     README + examples for ops hooks (the hooks themselves: /etc/ddeploy/hooks/)
```

Lives at `/opt/ddeploy`, root-owned (see "Quickstart"), and holds code
only — everything specific to this server lives in the standard places,
so the checkout can be moved, re-cloned or `git clean`ed without losing
anything:

```
/etc/ddeploy/provisioner.conf     server config (`configure` writes it)
/etc/ddeploy/manifest             name -> repo-url -> optional branch, for provision-all (optional)
/etc/ddeploy/hooks/<stage>.d/     ops hooks run for every site (hooks/README.md)
/etc/ddeploy/*                    secrets: webhook secret, backup/comment credentials...
/var/lib/ddeploy/generated/       per-site state: sidecars, overrides, preview metadata, deploy
                                  history, worker/schedule scripts, *.dbpass, *.notify-url
/var/lib/ddeploy/                 also: webhook queue, locks, notification cooldowns, PHP shims
/var/lib/ddeploy/events/          per-site run history, one JSON event per line ("Web UI")
/var/lib/ddeploy/runs/            metadata of runs started via `api run start`
/var/log/ddeploy/                 site, fleet and webhook logs (`ddeploy logs`), rotated weekly
/var/log/ddeploy/runs/            full output of every run, by run id
```

Sites are
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

