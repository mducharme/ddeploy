# Onboarding a project

How to put one project on a ddeploy server and get it working, then turn
on whatever optional features it needs.

- **Part 1** is the path every project takes: provision it, set its
  environment, load its content, check it works, and know where to look
  when it doesn't.
- **Part 2** covers the optional features (custom domain, auto-deploy on
  push, branch previews, backups, Slack...), each on its own.

The [README](../README.md) explains what each feature does and why. This
page is about what to type and what you should see. Each step is labeled
**Per project** (do it for every project) or **Server-wide, once** (one
person sets it up for the whole server, then every project has it).

## Before you start

**Server access.** SSH to the server as the `deploy` user, who has sudo.
Every command below is `ddeploy <command>` and works from any directory.
It asks for sudo by itself, so don't prefix it. `ddeploy -h` lists the
commands, and `ddeploy <command> -h` explains one. (No `ddeploy` command
on the server? It was set up before the command existed: run
`sudo ./provision.sh install-cli` once from the ddeploy checkout.)

**Repo access.** The server clones over SSH with one shared machine-user
key (README "Git access"). That bot account needs **read access to the
project's repo**, as a collaborator or through its org, or the first
provision fails at `git clone`.

**Pick the site name.** It becomes the URL (`<name>.$BASE_DOMAIN`), the
Linux user (`www-<name>`) and the database name: lowercase letters,
digits and hyphens, 28 characters max. **If the repo has a
`.ddev/config.yaml`, the site name must equal its `name:` field**, or
`provision` stops with `'name: x' ... does not match directory name`.

**DNS.** Nothing to do for `<name>.$BASE_DOMAIN`, which the server's
wildcard record and certificate already cover. Only a project's own
domain needs DNS work (step 8).

---

# Part 1 — Get the project live

## 1. Provision the site

*Per project.*

```
ddeploy provision <name> <repo-url>
```

What it reads from the repo:

- `.ddev/config.yaml`, if there is one: PHP version, docroot, upload
  directories, deploy steps (`hooks.post-start`). DDEV itself is never
  run on the server.
- No `.ddev/config.yaml`: it detects Craft, WordPress (plain or Bedrock)
  or Charcoal from the repo and fills in sensible defaults, or asks you.
  For a scripted run, pass `--non-interactive --php <ver>` (see
  `ddeploy provision -h`).

What you get: a Linux user and PHP-FPM pool of its own, an empty
database, an nginx vhost with HTTPS, and a first deploy (composer
install, frontend build if there is one, the deploy steps). It ends with
`provisioned: https://<name>.$BASE_DOMAIN`.

Track a branch other than the repo's default? Add `--branch develop`
(step 9).

## 2. Set the environment (`.env`)

*Per project.*

Provision writes the database credentials into the site's `.env` itself
(`CRAFT_DB_*` for Craft, `DB_*` for Laravel-style apps; see README
"Database credentials"). For Craft it also adds the keys Craft won't boot
without, but only when they're missing: `CRAFT_APP_ID`,
`CRAFT_SECURITY_KEY` (random), `CRAFT_ENVIRONMENT=staging`,
`PRIMARY_SITE_URL`.

**Everything else is yours to add** (mail settings, API keys, and so on)
with `ddeploy env`:

```
ddeploy env <name>                            # show it (secrets masked; --reveal shows all)
ddeploy env <name> MAILER_DSN=smtp://... OTHER=value
ddeploy env <name> --unset OTHER
ddeploy env <name> --edit                     # open the real file in an editor
```

Changes are live on the next request. Don't edit
`<site>/current/.env` by hand: it's a symlink into the persistent store
(`ddeploy env <name> --path` shows where), `sudoedit` refuses to touch
it, and editors that save by replacing the file break the link, so the
next deploy throws your edit away.

**Importing a database from another environment (step 3)?** Set that
environment's `CRAFT_SECURITY_KEY` too, or anything Craft encrypted
there won't decrypt here:

```
ddeploy env <name> CRAFT_SECURITY_KEY=<the key from the other environment's .env>
```

## 3. Load the content: database and uploads

*Per project.*

A new site starts with an **empty database and no uploads**. For a CMS
like Craft that usually means a 500 error until real content is in.

**Database.** Export it locally, copy it up, and load it. It's loaded as
the site's own database user, so you never need the credentials:

```
# on your machine
ddev export-db --file=dump.sql.gz
scp dump.sql.gz deploy@<server>:/tmp/

# on the server
ddeploy restore-database <name> --from-file /tmp/dump.sql.gz --yes
rm /tmp/dump.sql.gz
ddeploy deploy <name>        # re-runs the deploy steps (e.g. Craft migrations + project config) against the imported data
```

This **overwrites** the site's database. `.sql` and `.sql.gz` both work.

**Uploads.** Each upload directory is a symlink into the persistent
store. Copy into the real directory, then hand it to the site's user:

```
# on your machine (web/uploads as an example: use your project's upload_dirs)
rsync -az web/uploads/ deploy@<server>:/tmp/<name>-uploads/

# on the server
real="$(readlink -f /home/deploy/sites/<name>/current/web/uploads)"
sudo rsync -a /tmp/<name>-uploads/ "$real/"
sudo chown -R www-<name>:www-data "$real"
rm -rf /tmp/<name>-uploads
```

(`/home/deploy/sites` is the default `SITES_ROOT`; check
`provisioner.conf` if yours differs.)

## 4. Check it works

*Per project.*

- [ ] `curl -I https://<name>.$BASE_DOMAIN/` returns 200, or 401 if
      basic auth is on.
- [ ] The site loads in a browser with real content, and the CMS admin
      (e.g. `/admin` for Craft) lets you log in.
- [ ] Frontend: the deploy output shows
      `node build (<name>, node <version>, npm, ...)` with the Node
      version you expect, and a built asset loads. No `node build` line
      at all? There's no lockfile; nothing is built automatically
      without one.
- [ ] `ddeploy doctor <name>` shows every line as `[ok]`.
- [ ] `ddeploy list` shows the site with the PHP and Node versions,
      database and deployed commit you expect.

## 5. When something's wrong

| Symptom | Where to look |
| --- | --- |
| Craft says "An internal server error occurred" | Craft's own log: `sudo tail -n 100 /home/deploy/sites/<name>/current/storage/logs/web-$(date +%F).log`. For the full error in the browser, briefly run `ddeploy env <name> CRAFT_DEV_MODE=true`, reload, then `ddeploy env <name> --unset CRAFT_DEV_MODE`. |
| `provision` or `deploy` failed | `ddeploy logs <name> -n 200` (composer, build and deploy-step output). A failed deploy never goes live; the previous release keeps serving. |
| 502, blank page, "Permission denied" | `sudo tail -n 50 /var/log/nginx/error.log` and `sudo tail -n 50 /var/log/php*-fpm.log`. |
| Pushed, but the site didn't update | `ddeploy logs webhook` shows every delivery and what happened to it (deployed, skipped because it's not the tracked branch, rejected for a wrong secret...). |
| Database connection errors | `ddeploy env <name>` to see what the app is using. Lost or broken credentials: re-run `ddeploy provision <name>` (no repo URL needed), which re-syncs the DB password. |
| Not sure | `ddeploy doctor <name>` checks nginx, PHP-FPM, the database, disk and certificates. |

Note for Craft: `storage/` lives in each release, so logs from before
the latest deploy are in `/home/deploy/sites/<name>/releases/*/storage/logs/`,
and they're deleted when old releases are pruned.

---

# Part 2 — Optional features

## 6. `.ddeploy/config.yaml`: per-project settings in the repo

*Per project.*

Most per-project features are switched on by keys in one file,
committed in the client repo next to `.ddev/config.yaml`. The file is
optional and so is every key: an absent key means "server default" or
"off". A project with everything on looks like this (keep only what you
need):

```yaml
db_env_scheme: craft              # laravel | craft | charcoal | none — usually auto-detected
additional_hostnames:
  - alt-name                      # extra <x>.$BASE_DOMAIN names, same vhost/cert
additional_fqdns:
  - www.client.com                # the project's OWN domain — see step 8
persistent_files:
  - storage/app/                  # kept across deploys/removal — README "Persistent files"
  - .env.local
basic_auth: true                  # password-protect the site (previews have it on regardless)
client_max_body_size: 256m        # nginx upload ceiling (default 64m)
fpm_max_children: 20              # PHP-FPM pool concurrency (default 5)
auth_exempt_paths:
  - /health                       # reachable without basic auth — see step 13
backup_exclude:
  - cache/**                      # rclone --exclude glob, uploads backup only
db_backup_retention_days: 30      # overrides the server's DB_BACKUP_RETENTION_DAYS
php_ini:
  memory_limit: 256M
  upload_max_filesize: 64M
security_headers: true            # X-Content-Type-Options / Referrer-Policy / X-Frame-Options
static_cache: 30d                 # expires header on css/js/images/fonts (1-9999 + s/m/h/d)
deny_php_in_uploads: true         # 404 for any PHP file under an upload directory
redirects:
  - from: /old-page
    to: /new-page
    code: 301
nodejs_version: "22"              # or .nvmrc / .ddev nodejs_version — README "Frontend builds"
build:                            # automatic anyway when package.json has a build script + a lockfile
  path: .                         # directory with package.json
  script: build
  outputs:
    - web/dist                    # the deploy fails if this is missing/empty after the build
```

Every key is explained in README "Configuration" → `.ddeploy/config.yaml`
(and "Frontend builds" for `build:`). Commit, then `ddeploy deploy
<name>`: all of it is re-read on every deploy.

## 7. Change a setting without touching the repo

*Per project, server-side.*

For when a setting from step 6 has to change now, and a repo commit
would take too long or you don't have access (a bigger upload limit, basic
auth on immediately, an extra hostname):

```
ddeploy override <name> basic_auth=true "additional_hostnames=alt1 alt2"
ddeploy deploy <name>
```

It's stored on the server only (`generated/<name>.override.yaml`) and
wins over both `.ddeploy/config.yaml` and `.ddev/config.yaml`. `--show`
prints what's set, `--unset <key>` removes one key, and `--clear`
removes everything. It covers most of step 6's keys, but not
`redirects`, `php_ini`, `queue_workers` or `schedule`, which have to go
in the repo. See README "Overriding a project's config without touching
the repo" for the list.

## 8. Custom domain

*Per project.*

1. Add the domain under `additional_fqdns:` (step 6), or with
   `ddeploy override <name> additional_fqdns=www.client.com`.
2. Point the domain's DNS at this server. Behind Cloudflare, the domain
   needs its own DNS record there; it doesn't inherit
   `$BASE_DOMAIN`'s setup.
3. `ddeploy deploy <name>` requests a certificate for it. If DNS isn't
   live yet, it warns and leaves the domain on plain HTTP: deploy again
   once DNS works.

See README "Custom domains".

## 9. Track a different branch

*Per project, server-side.*

Only needed when the branch to deploy isn't the repo's default. It's
server-side state, never committed to the repo:

```
ddeploy provision <name> --branch develop      # existing site: the next deploy switches over
ddeploy provision <name> --clear-branch        # back to the default
```

On a brand-new site, pass `--branch` at the first provision to clone
that branch directly. With `provision-all`, the manifest's optional
third column does the same (`<name> <repo-url> <branch>`). See README
"Default branch".

## 10. Auto-deploy on git push

**Server-wide, once:** `ddeploy configure webhook` turns the
webhook on, generates its secret, and offers to register it on your
GitHub org or Bitbucket workspace through their API (the token is used
once, never saved). One registration covers every repo in that
org/workspace. Then run `ddeploy init` to start the listener. See README
"Deploy on git push" to register it by hand instead.

**Per project:** nothing, as long as the repo is in that org/workspace.
A push to the branch the site tracks (step 9) deploys it. Pull requests
drive branch previews (step 11).

**Checking it works:** push a commit and run `ddeploy logs webhook`.
You should see the delivery `accepted`, then `deploy <name>: OK @ <sha>`.
Don't rely on GitHub's delivery screen: it shows "delivered" even when
the secret is wrong, because the server only checks the signature after
answering. A wrong secret shows up in `ddeploy logs webhook` as
`REJECTED: HMAC verification failed`.

Repo in another org, or the client's own CI? Run `ddeploy deploy` over
SSH from that pipeline instead:
[examples/ci/github-action](../examples/ci/github-action/action.yml) /
[examples/ci/bitbucket-pipelines.yml](../examples/ci/bitbucket-pipelines.yml).

## 11. Branch previews

*Automatic once step 10 is set up.*

Opening a pull request (from a branch in the same repo, never a fork)
creates a preview at `https://<project>-<branch>.$BASE_DOMAIN`. New pushes
to the PR update it, and closing or merging the PR removes it.

What a new developer needs to know:

- **Password.** Previews have basic auth on. The username is `preview`,
  and the password is `sudo cat /etc/ddeploy/basic-auth-password` (unless
  the site has its own htpasswd at `/etc/nginx/htpasswd/<name>`).
- **Shared database by default.** A preview uses its parent's database
  and uploads, not a copy (`PREVIEW_DB_MODE=shared`, see README "Branch
  previews" for why). Content entered on a preview is live on the
  parent, and a migration on the branch runs against the parent's data.
  For a separate, disposable copy, create the preview by hand:
  `ddeploy provision-preview <project> <branch> --isolated`.
- **Its own config.** At creation, a preview gets a copy of its parent's
  `.env` (DB and URLs adjusted for the preview) and of the parent's
  operator overrides. Change either for that preview alone with
  `ddeploy env <preview> ...` / `ddeploy override <preview> ...`.
- **Its name.** `<project>-<branch>`, lowercased, with anything other
  than letters, digits and hyphens turned into hyphens, and shortened if
  it's long. `ddeploy list` shows it, and `ddeploy preview-url <project>
  <branch>` prints its URL whether or not it exists yet.

Optional, **server-wide, once**:

- **PR comments:** point `PREVIEW_COMMENT_CREDENTIALS` (in
  `provisioner.conf`) at a chmod-600 file with `GITHUB_TOKEN` and/or
  `BITBUCKET_USER` + `BITBUCKET_APP_PASSWORD` (`configure webhook` offers
  this too). Each preview then gets a `Preview: https://...` comment on
  its PR, updated on later pushes.
- **Stale preview cleanup:** `PREVIEW_PRUNE_ENABLED=true` adds a nightly
  cron that removes previews whose branch no longer exists. It's the
  safety net for a PR close the webhook never saw.

## 12. Backups: uploads and database

**Server-wide, once:** `ddeploy configure backups` asks for
the provider (DigitalOcean Spaces, AWS S3, or any S3-compatible
storage), bucket and keys, writes the credentials file, and turns both
backups on. Then run `ddeploy init` to install the cron jobs. By hand,
in `provisioner.conf`:

```
BACKUP_CREDENTIALS="/etc/ddeploy/backup-credentials.env"   # BACKUP_ENDPOINT/ACCESS_KEY/SECRET_KEY, chmod 600
BACKUP_BUCKET="your-bucket"
BACKUP_ENABLED="true"        # uploads
DB_BACKUP_ENABLED="true"     # database
```

`BACKUP_ENDPOINT` depends on the provider: DigitalOcean Spaces is
`https://<region>.digitaloceanspaces.com`, AWS S3 is
`https://s3.<region>.amazonaws.com`. One bucket covers every project,
with a `<name>/` prefix per site. See README "Backups" for creating keys.

**Per project:** databases are backed up automatically. Uploads are only
backed up for directories declared in `upload_dirs:` (in
`.ddev/config.yaml`, or `--upload-dirs "a b"` at provision). Tune with
`backup_exclude:` and `db_backup_retention_days:` (step 6). Shared-mode
previews are skipped, since their data is the parent's.

**Checking it works:** `ddeploy backup-uploads <name>` and
`ddeploy backup-database <name>` run one now; then look for
`<bucket>/<name>/` in the bucket. `ddeploy doctor <name>` reports how
many database dumps exist and how old the newest is.

**Restoring:** `ddeploy restore-uploads <name> --yes` /
`ddeploy restore-database <name> --yes` (without `--yes`, they show
what would happen). See README "Restoring".

## 13. Health checks

**Per project:** if the site has basic auth on but something needs to
reach a URL without it (an uptime monitor, an incoming webhook), list
that path under `auth_exempt_paths:` (step 6), e.g. `/health`.

**Server-wide:** `ddeploy doctor` (all sites) or `ddeploy doctor <name>`
checks nginx, PHP-FPM, disk, certificate expiry, each site's database
connection, and the webhook/backup/pruning setup. It exits non-zero on
any `[fail]`, so it can run from cron or monitoring. With
notifications on (step 14), a failure is also posted to chat.

## 14. Slack (or Discord) notifications

**Server-wide, once.** Create a webhook URL for a channel:

1. https://api.slack.com/apps → **Create New App** → **From scratch**,
   name it, pick the workspace.
2. **Incoming Webhooks** → turn it on → **Add New Webhook to
   Workspace** → pick the channel → **Allow**. (Some workspaces need an
   admin to approve this.)
3. Copy the `https://hooks.slack.com/services/...` URL. Anyone with it
   can post to the channel, so treat it like a password.

Put it in `provisioner.conf` (`sudoedit /path/to/checkout/provisioner.conf`):

```
NOTIFY_WEBHOOK="https://hooks.slack.com/services/..."
```

Then `ddeploy notify --test` should post a test message. From then on
the channel gets a message for each deploy (green with the URL, commit,
duration and who triggered it; red with the error when it fails), for
previews created and removed, and for webhook deliveries rejected over a
wrong secret. `NOTIFY_EVENTS` in `provisioner.conf` picks which of
these are sent. The same URL also gets failure alerts from the backup
cron, `prune-previews` and `doctor`. Discord webhook URLs work the same
way.

**Per project (optional):** send one project's messages to a channel of
its own (a client's, say) as well:

```
ddeploy notify <name> --set-url      # asks for the URL; typing is hidden
ddeploy notify <name> --test
```

Its previews use the same channel. See README "Notifications".

## Checklist for the optional features

Tick the ones you turned on:

- [ ] Custom domain: `curl -I https://<your-domain>/` returns 200/401,
      and the certificate is for that domain, not the wildcard.
- [ ] Auth exemption: `curl https://<name>.$BASE_DOMAIN/health` returns
      200 with no credentials.
- [ ] Auto-deploy: push a commit to the tracked branch → `ddeploy logs
      webhook` shows `deploy <name>: OK @ <sha>`, and the site has the
      change.
- [ ] Previews: open a test PR → `https://<project>-<branch>.$BASE_DOMAIN`
      appears within a minute (user `preview`), plus a PR comment if
      configured. Close the PR → it's gone.
- [ ] Backups: `ddeploy backup-uploads <name>` and `ddeploy
      backup-database <name>` succeed, and `<bucket>/<name>/` has files.
- [ ] Override: `ddeploy override <name> basic_auth=true && ddeploy
      deploy <name>` → the site now asks for a password. Then
      `ddeploy override <name> --clear && ddeploy deploy <name>`.
- [ ] Notifications: `ddeploy notify <name> --test` posts to the
      channel, and the next deploy posts a green message.
