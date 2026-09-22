# Onboarding a project with everything turned on

A task-oriented walkthrough for standing up one project and enabling
every optional feature: custom domain, a non-default tracked branch,
auto-deploy on push, branch previews with PR comments, uploads/database
backups, and health-check paging. The main [README.md](../README.md) is
the reference for what each feature actually does and why — this is the
checklist for turning all of them on for one real project.

Assumes the server itself is already set up (`./bootstrap.sh` +
`./install.sh`, or `provision.sh configure` + `sudo provision.sh init` —
see README "Quickstart"). A few features here are **server-wide,
one-time settings** (enable once in `provisioner.conf`, then every
project on the box gets them, usually via a `provision.sh configure
<area>` wizard); others are **per-project config**, set either in the
client repo itself or, without touching the repo at all, via `provision.sh
override` (step 3). Each step below says which.

## 1. Provision the site

```
sudo ./provision.sh provision <name> <repo-url>
```

`<name>` becomes `<name>.$BASE_DOMAIN`, the Linux username suffix
(`www-<name>`), and the database name — lowercase, digits, hyphens, 28
chars max. If the repo has a `.ddev/config.yaml`, PHP version/docroot/
upload dirs/deploy hooks are read from it automatically; otherwise you're
prompted (or pass `--non-interactive --php <ver>` for a scripted
first-time setup). See README "Resolving a new site" for the full
precedence order.

This alone gets you: an isolated Linux user, FPM pool, database, and
nginx vhost, plus a first deploy. Everything below is additive.

## 2. `.ddeploy/config.yaml` — the project-side feature switchboard

Most of what follows is turned on by adding keys to one file, committed
in the client repo next to `.ddev/config.yaml`. It doesn't have to exist
at all — every key here is optional and additive. A project with
everything on looks like this (trim to what you actually need):

```yaml
db_env_scheme: charcoal          # laravel | craft | charcoal | none — usually auto-detected
additional_hostnames:
  - alt-name                     # extra <x>.$BASE_DOMAIN names, same vhost/cert
additional_fqdns:
  - www.client.com                # this project's OWN domain — see step 3
persistent_files:
  - storage/app/                  # survives `remove --purge-files` — see README "Persistent files"
  - .env.local
basic_auth: true                  # crawlability gate; previews default to this on regardless
client_max_body_size: 256m        # nginx upload ceiling (default 64m)
fpm_max_children: 20              # PHP-FPM pool concurrency (default 5)
auth_exempt_paths:
  - /health                       # bypass basic_auth for a health/webhook endpoint — see step 9
backup_exclude:
  - cache/**                      # rclone --exclude glob, backup-uploads only
db_backup_retention_days: 30      # per-project override of DB_BACKUP_RETENTION_DAYS
php_ini:
  memory_limit: 256M
  upload_max_filesize: 64M
security_headers: true            # X-Content-Type-Options / Referrer-Policy / X-Frame-Options
static_cache: 30d                 # expires on css/js/images/fonts (1-9999 + s/m/h/d)
deny_php_in_uploads: true         # deny all + 404 for PHP under any upload_dirs path under docroot
redirects:
  - from: /old-page
    to: /new-page
    code: 301
```

Full explanation of every key: README "Configuration" →
`.ddeploy/config.yaml`. Redeclare nothing you don't need — an absent key
just means "server default" or "off."

Re-apply any change here with a plain `deploy <name>` — all of it,
`persistent_files` included, is re-read and re-applied on every deploy,
not just provision.

## 3. Overriding any of the above without touching the repo (optional)

For when you need to flip one of step 2's settings and don't have (or
don't want to wait for) repo write access — a client's uploads need a
bigger `client_max_body_size` right now, basic auth needs to go on
immediately, an extra hostname needs adding before the dev team gets to
it:

```
sudo ./provision.sh override <name> basic_auth=true "additional_hostnames=alt1 alt2"
```

Server-side only (`generated/<name>.override.yaml`), never written into
the client's checkout, and it's the highest-precedence config source —
wins over both `.ddeploy/config.yaml` and `.ddev/config.yaml`. Takes
effect on the next `deploy`. `--show` prints what's currently set,
`--unset <key>` removes one, `--clear` removes all of them (falling back
to whatever the repo itself declares). Covers most of step 2's scalar and
list keys — not `redirects`/`php_ini`, which need the repo's own
`.ddeploy/config.yaml`. See README "Overriding a project's config
without touching the repo" for the exact supported key list.

## 4. Custom domain (optional, per-project)

Already covered above by `additional_fqdns:`. Before provisioning (or
before the next deploy):

1. Point the domain's DNS at this server.
2. If the server is behind Cloudflare, give the custom domain its own
   DNS record there too — it does **not** inherit `$BASE_DOMAIN`'s
   proxy setup.
3. `deploy <name>` (or `provision`, first time) issues an HTTP-01
   certificate for it. If DNS isn't live yet, this logs a warning and
   leaves an HTTP-only vhost — re-run once it is.

See README "Custom domains".

## 5. Default branch (optional, per-project, operator-side)

Only needed if this project's real branch isn't whatever `git clone`
picked by default (`main`/`master`). This is **never** set in the
client's repo — it's server-side state, so there's nothing to commit and
no risk of a stale value fighting a later `git pull` on the ddeploy
checkout itself:

```
sudo ./provision.sh provision <name> --branch develop
```

The next deploy switches onto it. `--clear-branch` removes the override.
For a brand-new site, pass `--branch` at first-provision time to clone
that branch directly instead of the remote's default. Onboarding several
projects at once via `provision-all`? The manifest's optional 3rd column
does the same thing (`<name> <repo-url> <branch>`). See README "Default
branch".

## 6. Auto-deploy on git push

**Server-wide, one-time:** `sudo ./provision.sh configure webhook` turns
on `WEBHOOK_ENABLED`, generates the HMAC secret, and offers to register
the webhook itself via the GitHub/Bitbucket API (prompting for a
token/app-password used once, never saved) — this covers Bitbucket
either way, since it has no workspace-level webhook screen in its own UI
at all, only per-repo. One registration covers every client repo on the
box, nothing to repeat per project. See README "Deploy on git push" for
the exact API calls if you'd rather do it by hand.

**Per-project:** nothing, as long as the repo is under that same
org/workspace. A push to the branch this site tracks (its current HEAD,
or its `deploy_branch` override from step 5) deploys automatically. A PR
opened/synced/closed drives branch previews (step 7) the same way.

Can't use an org-wide webhook for this particular repo (different org,
client-controlled CI, etc.)? Use the SSH escape hatch instead —
`provision.sh deploy` over SSH is always valid, and
[examples/ci/github-action](../examples/ci/github-action/action.yml) /
[examples/ci/bitbucket-pipelines.yml](../examples/ci/bitbucket-pipelines.yml)
wrap it for a repo's own CI pipeline.

## 7. Branch previews (optional, mostly automatic)

Once the webhook (step 6) is live, opening a PR on a provisioned project
automatically stands up `<project>-<branch-slug>.$BASE_DOMAIN` — no
per-project setup needed, and every webhook-triggered preview uses the
server-wide `PREVIEW_DB_MODE` (`shared` by default: database and uploads
are shared with the parent project, not copied — deliberate, not a
shortcut; see README "Branch previews" for why). A preview created
manually instead (`provision-preview <project> <branch> --isolated`) can
opt that one preview out into a fully separate, disposable copy — there's
no per-PR way to request that through the webhook itself.

Nothing to configure to get previews at all; two optional add-ons:

- **PR comments** — **server-wide, one-time:** `configure webhook`
  (step 6) offers to set this up as part of the same wizard, or do it
  separately: point `PREVIEW_COMMENT_CREDENTIALS` (in `provisioner.conf`)
  at a chmod-600 file with `GITHUB_TOKEN` and/or
  `BITBUCKET_USER`+`BITBUCKET_APP_PASSWORD`. Every project's previews
  then get a PR comment (`Preview: https://...`), updated in place on
  later pushes, for free.
- **Stale preview cleanup** — **server-wide, one-time:** set
  `PREVIEW_PRUNE_ENABLED=true` (+ optionally `PREVIEW_PRUNE_SCHEDULE`) so
  a cron catches any preview whose branch got deleted without a PR-closed
  event reaching the webhook (network blip, PR closed by admin API, etc.)
  — the normal cleanup path (`remove-preview` on PR close) already
  handles the common case; this is the safety net.

CI-triggered instead of the webhook? `provision.sh preview-url <project>
<branch>` prints the same URL the PR comment would, so your own pipeline
can post it itself.

## 8. Backups — uploads and database (optional)

**Server-wide, one-time:** `sudo ./provision.sh configure backups` walks
through it interactively — pick DigitalOcean Spaces, AWS S3, or any
other S3-compatible endpoint, enter the bucket and keys, and it writes
the credentials file plus turns `BACKUP_ENABLED`/`DB_BACKUP_ENABLED` on.
By hand, both point at the same object storage in `provisioner.conf`:

```
BACKUP_CREDENTIALS="/etc/ddeploy/backup-credentials.env"   # BACKUP_ENDPOINT/ACCESS_KEY/SECRET_KEY, chmod 600
BACKUP_BUCKET="your-bucket"
BACKUP_ENABLED="true"        # uploads
DB_BACKUP_ENABLED="true"     # database
```

`BACKUP_ENDPOINT` is provider-specific — DigitalOcean Spaces:
`https://<region>.digitaloceanspaces.com`; AWS S3:
`https://s3.<region>.amazonaws.com`; anything else uses whatever
endpoint URL that provider gives you. See README "Backups" for where to
generate each provider's access/secret key pair. One set of credentials
and one bucket (with a `<name>/` prefix per site) covers every project.

Either way, re-run `init` — it installs `rclone` and the cron entries.

**Per-project, for uploads only:** declare `upload_dirs:` in
`.ddev/config.yaml` (or `--upload-dirs "a b"` at provision time) — a
project with none declared is skipped for uploads backup entirely
(nothing to sync). Database backup needs no per-project config; every
provisioned site's database gets dumped automatically once
`DB_BACKUP_ENABLED` is on.

`backup_exclude:` and `db_backup_retention_days:` (step 2's
`.ddeploy/config.yaml`) are the only per-project tuning available. Run
`backup-uploads <name>` / `backup-database <name>` directly to check a
project's backup works without waiting for the cron schedule. Both are
preview-aware — shared-mode previews are skipped (would just duplicate
the parent's own backup).

Restoring: `restore-uploads <name> --yes` / `restore-database <name>
--yes` — see README "Restoring", including `--from-file` for loading a
client-provided `.sql`/`.sql.gz` dump with no object storage involved.

## 9. Health checks and failure paging (optional)

**Per-project, if the site has `basic_auth: true` and you want an
unauthenticated health/webhook endpoint:** add its path to
`auth_exempt_paths:` in step 2's `.ddeploy/config.yaml` (`/health`, say).

**Server-wide, one-time:** `doctor [name]` (no args = every site) checks
nginx, PHP-FPM, disk, cert expiry, and each site's own DB connection —
run it by hand any time, or wire it into cron/monitoring since it exits
nonzero on any `[fail]`. Point `NOTIFY_WEBHOOK` (in `provisioner.conf`)
at a Slack/Discord incoming webhook URL and a failure from `doctor`, the
backup cron, `prune-previews`, or the git-push worker pages it — success
stays silent,
and the same command+site won't repage until `NOTIFY_COOLDOWN` seconds
pass (default 3600). See README "Health check" / "Failure paging".

## Checklist: verify each feature actually works

- [ ] `curl -I https://<name>.$BASE_DOMAIN/` — 200 (or 401, if
      `basic_auth: true`)
- [ ] Custom domain, if set: `curl -I https://<your-domain>/` — check the
      cert is for the right domain, not the wildcard
- [ ] `curl https://<name>.$BASE_DOMAIN/health` — 200 with no
      credentials, if `auth_exempt_paths` is set
- [ ] Push a commit to the tracked branch → site updates (`logs <name>
      -f` while it happens, or `list` afterward to confirm the deployed
      sha)
- [ ] Open a test PR → a preview appears at
      `https://<project>-<branch-slug>.$BASE_DOMAIN` within a few
      seconds, and (if configured) a comment lands on the PR
- [ ] `sudo ./provision.sh backup-uploads <name>` /
      `backup-database <name>` — check the bucket for
      `<bucket>/<name>/...`
- [ ] `sudo ./provision.sh override <name> basic_auth=true && sudo
      ./provision.sh deploy <name>` then confirm the site now requires
      auth, without touching the repo — `--clear` it afterward
- [ ] `sudo ./provision.sh doctor <name>` — every line `[ok]`
- [ ] `sudo ./provision.sh list` — confirms mode, DB, and (for previews)
      parent resolution all look right
