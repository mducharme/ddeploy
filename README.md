# ddeploy

Provisions and deploys PHP sites on a plain Ubuntu 24.04 server: nginx,
one PHP-FPM pool per site, one Linux user per site, one MariaDB database
per site, a shared wildcard TLS certificate. No containers. It reads a
project's own `.ddev/config.yaml` as configuration instead of asking for
a second one, and it never runs DDEV itself.

It's built for the staging/QA/client-review stage of a project's life —
there's no staging→production promotion path, no web UI, and no
cron/queue-worker management yet. One web server per project; a database
server can be shared across several web servers (`init-db`). If none of
that matches what you need, this probably isn't the right tool for it.

## Requirements

- An Ubuntu 24.04 server (or two — see "Database server" for a
dedicated DB host), root/sudo access.
- A domain, with either Cloudflare DNS or manual DNS control (TLS is
issued via certbot either way).
- A git host reachable over SSH — GitHub, GitLab, Bitbucket, self-hosted.
- Docker, only if you want to run the test harness before touching a
real server (next section).

## See it work

`docker/test/run.sh` builds two systemd-enabled Ubuntu containers plus a
MinIO instance standing in for S3, and runs the entire lifecycle against
them for real: `init`, `provision`, `deploy`, branch previews, git-push
webhooks, backup/restore, rollback, `doctor`, `remove`. Nothing here is
mocked except ACME/DNS-01 certificate issuance and `ufw`'s packet
filtering — `docker/README.md` says exactly why, and everything else has
been verified against this harness, not just read.

This is genuine, unedited output from an actual run — provisioning one
site, partway through that suite:

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

That's a real Linux user, a real nginx vhost that `nginx -t` actually
validated, a real PHP-FPM pool, a real MariaDB database and grant —
served by real nginx over TLS to a real `curl` request. Run
`docker/test/run.sh` yourself and watch the rest happen (needs Docker
with `--privileged` containers allowed, and internet egress for apt
packages and a few real API calls).

## Quickstart: a real server

1. `git clone` this repo onto the server, at `/home/deploy/provisioner`
  (`provisioner.conf`'s defaults assume this path).
2. Edit `provisioner.conf` — domain, paths, PHP versions, DB credentials
  path, git key path.
3. Place a Cloudflare API token at `CF_CREDENTIALS` (`chmod 600`).
4. Place a shared git SSH key at `GIT_DEPLOY_KEY` (`chmod 600`) — see
  "Git access."
5. `sudo ./provision.sh init` — installs nginx/PHP/MariaDB/certbot,
  issues the wildcard cert, sets up the firewall.
6. `sudo ./provision.sh provision <name> <repo-url>` — clones, detects
  or asks for config, stands up the vhost/FPM pool/database, runs the
   first deploy.

From there: `deploy <name>` on every push (or set up "Deploy on git
push" so that happens on its own), `list` to see the fleet, `doctor` to
check on it.

## Commands

```
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

Five places a setting can come from, in increasing order of "how
permanent is this":

| Where                                            | What goes here                                                                              | Lives in                               | Git-tracked                           |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- | -------------------------------------- | ------------------------------------- |
| `provisioner.conf`                               | Server-wide defaults — every site on this box starts from these                             | this repo, on the server               | no — per-server, edited after cloning |
| `.ddev/config.yaml`                              | Real DDEV fields: `php_version`, `docroot`, `upload_dirs`, `hooks.post-start`, `database.*` | the client's repo                      | yes — it's DDEV's own file            |
| `.ddeploy/config.yaml`                           | ddeploy-only per-site keys that aren't real DDEV fields (below)                             | the client's repo, sibling to `.ddev/` | yes                                   |
| `generated/<name>.yaml`                          | Sidecar ddeploy writes itself for a repo with no `.ddev/config.yaml` yet                    | this repo, on the server               | no — `generated/` is gitignored       |
| CLI flags (`--db`, `--hostnames`, `--auth`, ...) | A one-off override for this run of `provision`, always wins                                 | the terminal                           | n/a                                   |

**Precedence, per key:** an explicit CLI flag on `provision` always
wins, even against a project that already has a real `.ddev/config.yaml`
— `--db`, `--hostnames`, `--custom-domains`, `--upload-dirs`, and
`--deploy-cmd` aren't just "what to use the first time a site is
provisioned," they override every run they're passed on (see `provision -h`). Short of an explicit flag: `.ddeploy/config.yaml` wins for any key
it declares; otherwise whichever of `.ddev/config.yaml` or the sidecar
was actually used (`.ddev/config.yaml` if the repo has one, else the
sidecar ddeploy already wrote for it).

**When does a config change actually take effect?** `php_version`,
`docroot`, `basic_auth`, `client_max_body_size`, `fpm_max_children`,
`php_ini`, `additional_hostnames`, and `additional_fqdns` are all
re-applied on every `deploy`, not just `provision` — push a commit that
changes one in `.ddev/config.yaml`/`.ddeploy/config.yaml`, and the next
deploy (however it's triggered: SSH, CI, or a git-push webhook) picks it
up, same as code. `provision`-only flags (`--db`, `--upload-dirs`,
`--deploy-cmd`, `--custom-domains`, and the non-interactive/interactive
fallback fields) still only apply at provision time — those are either
one-off overrides or determine what config gets written in the first
place, not values `deploy` re-reads from a source that could change.

### Resolving a new site

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

`additional_hostnames`, `additional_fqdns`, `persistent_files`,
`db_env_scheme`, and `deploy_branch` aren't real DDEV fields — putting them in a real
`.ddev/config.yaml` risks a future DDEV schema-validation pass (or
`ddev config` regenerating the file) silently dropping them, and it's a
layering smell regardless: that file is DDEV's own, shared with the
client's dev team, not this tool's. Declare them instead in
`.ddeploy/config.yaml`, git-tracked, sitting next to `.ddev/config.yaml`:

```yaml
db_env_scheme: charcoal
deploy_branch: develop
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

Four more with no server-wide equivalent — off by default, only active
when declared:

- `deploy_branch` — which branch a normal (non-preview) site tracks,
instead of whatever branch it happened to be cloned on. See "Default
branch".
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

Four more scoped nginx knobs. These are **not** raw snippets — a
client repo cannot inject nginx directives. Each value is validated to
a charset that cannot break out of the template, and the actual
`location` / `add_header` / `expires` syntax is owned by this tool:

- `security_headers: true` — sends `X-Content-Type-Options: nosniff`,
`Referrer-Policy: strict-origin-when-cross-origin`, and
`X-Frame-Options: SAMEORIGIN`. Header names and values are not
configurable from the repo. No HSTS (custom domains start HTTP-only
until their cert issues; Cloudflare often already sets this).
- `static_cache: 30d` — `expires` on a fixed list of static extensions
(css/js/images/fonts). The duration is `1–9999` plus `s`/`m`/`h`/`d`;
the location regex is not. Missing assets 404 rather than falling
through to PHP.
- `deny_php_in_uploads: true` — for each `upload_dirs` entry that is
actually under the docroot (so nginx would serve it), PHP is `deny
all` and missing files 404. A private dir like `../private-uploads`
is skipped — it is not a URL. Extra prefixes: `deny_php_paths: [/media]`.
`/` is refused (that would turn off PHP for the whole site).
- `redirects` — a list of `{from, to, code}` maps. `from` is a URL
path; `to` is a URL path or an `https://` URL; `code` is `301` or
`302` (default 301). No `$` variables, no `http://`, no quotes or
semicolons.

Anything those four don't cover: drop a **root-owned regular file** at
`/etc/nginx/ddeploy-extra/<name>.conf`. `init` creates that directory.
It is included inside the site's `server{}` (wildcard and custom-domain
vhosts). It is never read from the client repo; `.ddeploy/nginx.conf` is
ignored if present. A symlink or a non-root-owned file is skipped with
a warning. Invalid extra config fails `nginx -t` and the deploy aborts.

## Site lifecycle

### Custom domains

Every site gets `<name>.$BASE_DOMAIN` for free, covered by the shared
wildcard cert. A site can also have its own domain(s) — `additional_fqdns`
in `.ddeploy/config.yaml` (see "Configuration"; a real
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

### Branch previews

`provision-preview <project> <branch> [repo-url]` stands up a site for
one branch of an existing project, at a name derived deterministically
from `<project>` + `<branch>` (`preview_slug` in `lib/preview.sh` —
lowercased, slugified, truncated with a hash suffix to fit the 28-char
name cap). `deploy-preview`/`remove-preview` take the same `(project, branch)` pair and resolve the same name, so nothing needs to remember or
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
nothing local worth protecting on a preview. Previews stay in-place;
they are not atomic releases. Basic auth defaults to on
for previews (`--no-auth` to turn it off), unlike normal sites, since
these are meant for internal/client eyes, not public or indexed.

nginx doesn't validate that `auth_basic_user_file` exists at `nginx -t`
time, only at request time — so a preview with no htpasswd file of its
own would 500 on every request. `init` generates a shared fallback
(`BASIC_AUTH_CREDENTIALS`, default `/etc/nginx/htpasswd/default`) once,
with a random password logged to stdout — every site with auth on and
no htpasswd file of its own (`htpasswd -c /etc/nginx/htpasswd/<name> <user>`) uses that shared one instead. Rotate it by deleting the file
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

### Deploy on git push

Set `WEBHOOK_ENABLED=true` in `provisioner.conf` and re-run `init`. That
stands up `https://hooks.$BASE_DOMAIN` (wildcard cert) proxying to an
unprivileged listener on localhost. A root systemd worker then runs the
existing CLI — nothing in the HTTP request is executed as a command.

| Forge           | URL                                    | Events                                                                 |
| --------------- | -------------------------------------- | ---------------------------------------------------------------------- |
| GitHub          | `https://hooks.$BASE_DOMAIN/github`    | `push`, `pull_request`                                                 |
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

If `PREVIEW_COMMENT_CREDENTIALS` is set (a chmod 600 file with
`GITHUB_TOKEN` and/or Bitbucket `BITBUCKET_USER`+`BITBUCKET_APP_PASSWORD`,
see `provisioner.conf`), a successful preview upsert also posts a PR
comment `Preview: https://<slug>.$BASE_DOMAIN`. Later pushes **update**
that comment (it is marked `<!-- ddeploy-preview -->`) instead of
stacking a new one. The repo is taken from the job's canonical
`github.com/…` / `bitbucket.org/…` URLs, not from an unvalidated
`full_name` field. A failed comment is a warning, not a failed deploy.
The token is never logged.

`provision.sh logs <name>` tails `$LOG_DIR/<name>.log` without hunting
the box (`-n`, `-f`). `provision.sh preview-url <project> <branch>`
prints the same URL the comment uses — handy when CI is the deploy
trigger instead of the webhook. Neither interpolates an unvalidated
name into a path or an API URL.

`provision.sh deploy` over SSH is still valid. For repos that cannot use
an org/workspace webhook, copy
`[examples/ci/github-action](examples/ci/github-action/action.yml)` or
`[examples/ci/bitbucket-pipelines.yml](examples/ci/bitbucket-pipelines.yml)`.
Do not have CI fake a forge payload.

### Default branch

By default a site tracks whatever branch it happened to be cloned on —
normally the remote's actual default branch (`main`/`master`), decided
by git, not by ddeploy. `<project>.$BASE_DOMAIN` deploys from that branch
forever, since `deploy` just does `git pull --ff-only` on whatever's
currently checked out.

To pin a project to a specific branch instead — `develop`, `staging`,
whatever the team has actually agreed is "production" — declare it in
`.ddeploy/config.yaml`:

```yaml
deploy_branch: develop
```

Commit and push that onto whatever branch the site is *currently*
tracking. `deploy` always pulls the tracked branch first (an ordinary
pull, same as any other config change), then checks the config it just
pulled: if it now names a different branch than the one actually checked
out, that same deploy fetches the configured branch and switches
`current`'s checkout onto it — a `git checkout -B <branch>
origin/<branch>`, not a `pull`, since there's no reason to assume the
previously-tracked branch fast-forwards into the new one. So **one push
is enough**: the deploy it triggers both picks up the declaration and
performs the switch, in a single step. From then on it's an ordinary
`pull --ff-only` again, on the newly-configured branch. Change
`deploy_branch:` again later (or remove it, to go back to "whatever git
clone picked") and the same thing happens again.

A git-push webhook (`push_head`, README "Deploy on git push") matches a
push's branch against both the site's *current* checked-out branch and
its *configured* `deploy_branch` — not just the current one. This mostly
matters before a site's very first deploy: if `deploy_branch:` is already
present in the very first commit a site is provisioned from (nothing has
pulled or switched anything yet, so HEAD and the configured branch can
genuinely disagree), a push to that configured branch is still recognized
and triggers the deploy that performs the switch — instead of being
silently ignored because HEAD hasn't caught up yet.

For a brand-new site, `provision <name> <repo-url> --branch <name>`
clones that branch directly instead of the remote's default, skipping the
"clone default, then switch on first deploy" indirection. This only
affects the initial clone; changing the tracked branch afterward is
always `deploy_branch:` in config, above. (Branch previews are unaffected
either way — a preview is inherently pinned to its own PR branch by
definition, via `provision-preview <project> <branch>` /
`deploy-preview`.)

### Rolling back

`deploy <name> --rollback [<sha>]` moves a site's code backward instead
of building a new forward release. Without `<sha>`, it rolls back to the
most recent commit this tool has itself deployed that differs from
what's live now — `deploy <name> --history` lists that record (newest
last) if you want to pick a specific, earlier `<sha>` instead.

Normal sites use a Capistrano-style layout: `$SITES_ROOT/<name>/current`
is a symlink to `releases/<timestamp>-<sha>/`, nginx's root follows
`current`, and persistent files already live outside the checkout (see
below). A forward `deploy` clones the live tree, `git pull --ff-only`s
as the site user, runs hooks on the NEW directory, and only then
retargets `current`. A failed pull or hook leaves the previous tree
serving. `RELEASES_KEEP` in `provisioner.conf` (default 5) is how many
release directories to keep; the live one is never pruned.

Rollback retargets `current` at an earlier release when that tree is
still on disk (hooks already ran when it was first deployed, so they
are not replayed). If it has been pruned, a new release is built with
`git reset --hard` and hooks run before the swap. A rollback is itself
recorded as a new deploy, so it composes normally: a plain `deploy`
afterward fast-forwards right back to where you rolled back from
(origin hasn't moved), and a second `--rollback` walks one step further
back, or forward again to undo the rollback, whichever you ask for.

**What this does not do:** undo a database migration. If a deploy you're
rolling back past ran `migrate` (or any other forward-only step) against
the database, rolling the code back does not reverse it — you'll have
older code pointed at newer schema. For a rollback driven by a bad
migration, restore the database too (see "Restoring") or fix forward
instead. This also doesn't apply to branch previews — they stay
in-place (`fetch` + `reset --hard`) and are meant to be disposable, not
rolled back.

### Persistent files

A site's own git checkout is disposable by design — `provision`/`deploy`
clone it into `releases/` and retarget `current`, and `remove --purge-files`
deletes the whole wrapper (every release, plus `current`).
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

`persistent_files:` (in `.ddeploy/config.yaml` — see "Configuration" —
not a real DDEV key) declares arbitrary extra paths beyond
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

## Data protection

### Backups

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

### Health check

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

Set `NOTIFY_WEBHOOK` in `provisioner.conf` to a Slack incoming-webhook
or Discord webhook URL (or any endpoint that accepts JSON) and a
`[fail]` pages that URL. `[warn]` does not. See "Failure paging."

## Failure paging

Unattended work (backup cron, the git-push worker, `prune-previews`,
`doctor`) used to fail into a log file. Set `NOTIFY_WEBHOOK` to a Slack
incoming webhook, a Discord webhook, or any URL that accepts a JSON POST
with `text` and `content` (both are sent, so either product works). The
URL is a credential — do not commit it. Empty (the default) is off.

Only **failures** page. A successful deploy, backup, or doctor run is
silent. The same command+site will not page again until
`NOTIFY_COOLDOWN` seconds have passed (default 3600), so an hourly
backup that fails all night is one message, not twenty-four.

SSH `provision.sh deploy` does not page: you are already watching.
A git-push deploy that fails after GitHub/Bitbucket got 202 does page,
because the forge UI stays green.

## Server & operations

### Database server

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

### Database credentials

Set by `db_env_scheme` (from CMS detection, or an explicit `db_env_scheme:`
in `.ddeploy/config.yaml` or the sidecar):

| scheme     | written to                     | vars                                                                 |
| ---------- | ------------------------------ | -------------------------------------------------------------------- |
| `laravel`  | `.env`                         | `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`               |
| `craft`    | `.env`                         | `CRAFT_DB_*`                                                         |
| `charcoal` | `config/config.local.json`     | `databases.<default_database>.{hostname,database,username,password}` |
| `none`     | nowhere (e.g. plain WordPress) | saved to `generated/<name>.dbpass`, logged once                      |

`charcoal` creates `config/config.local.json` if it doesn't exist,
reuses the file's own `default_database` key if one is already set, and
leaves any other keys in the file untouched.

### Deploy hooks

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

### Isolation

Each site: its own Linux user (`www-<name>`), its own FPM pool and
socket, its own database and DB user. Release content is owned
`www-<name>:www-data`, dirs `2750`, files `640` — nginx (`www-data`) can
read them, no other site's user can.

The wrapper itself (`$SITES_ROOT/<name>`, containing `releases/` and
`current`) and `current` are `root:root`/`root:www-<name>` with a sticky
bit, not owned by the site's own user — a normal site's own compromised
code (a bad dependency executing during hook replay, say) can create
files under its own release, but cannot repoint `current` at a directory
of its choosing or delete another release out from under a rollback.
Only `provision`/`deploy`, which already run as root, can retarget it.

### Git access

All git operations (clone, pull) authenticate with one shared SSH key,
placed at `GIT_DEPLOY_KEY`. This should be a machine-user account (bot
GitHub/GitLab/Bitbucket user, not a personal one) added as a read-only
collaborator on each client repo or org — not a GitHub "deploy key",
which is limited to one repo and can't be reused across a fleet.

`init` seeds `/etc/ssh/ssh_known_hosts` with GitHub/GitLab/Bitbucket host
keys for the initial clone (runs as root). `provision` and `deploy` copy
the key into each site's `$dir/.ssh` (that site's `www-<name>` `$HOME`),
so pulls after the first one run as the site's own user, not root.

### Cloudflare

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

## Accepted tradeoffs

Places where ddeploy deliberately chose the option with a real downside
over one without, because the alternative was worse. Full reasoning is
in the linked section.

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

- **App-level cron/queue-worker management** — a project's `artisan
  schedule:run` or a supervised queue worker needs its own hand-rolled
  systemd unit today, entirely outside this tool. Likely a
  `.ddeploy/config.yaml` key generating a systemd unit + timer per site,
  the same per-site-generated-config pattern the FPM pool and vhost
  already use.
- **Secrets/credential rotation** — a site's DB password, once
  generated, lives in plaintext on disk indefinitely, protected only by
  Unix file permissions, with no command to rotate it. The shared
  basic-auth password already has a rotation path (delete the htpasswd
  file, re-run `init`); per-site DB credentials don't.

