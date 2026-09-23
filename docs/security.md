# Security model

Why ddeploy's trust boundaries are drawn where they are. This is
rationale, not a how-to — for day-to-day usage see the main
[README](../README.md), which links here wherever one of these decisions
is relevant.

## The ddeploy checkout itself is root-owned

`$PROVISIONER_DIR` (this checkout, normally `/opt/ddeploy` — see the
README's "Layout") is `root:root`, traversable but not writable by
anyone else. Two things execute code straight out of it as root,
unconditionally: the backup-uploads/backup-database/prune-previews cron
entries `init` writes, and the webhook worker's systemd unit
(`ddeploy-hook-worker.service` — the listener itself is unprivileged and
runs a copy at `/usr/local/lib/ddeploy/listener.py`, not this checkout,
but the worker that actually runs `provision.sh deploy` on a queued job
is root).

If this tree were writable by `deploy` or by whatever SSHes in to
trigger a CI deploy, either one could rewrite `lib/*.sh` — or
`provisioner.conf`, which is `source`d, not parsed — and get root on the
next cron tick or webhook delivery, with no deploy of their own
required. `deploy` being in the `sudo` group already makes it
root-equivalent for itself, but the same checkout is also where a
webhook/CI path runs, and that's a meaningfully lower-trust actor that
should be able to trigger a deploy without being able to rewrite what
root executes.

`bootstrap.sh` clones to `/opt/ddeploy` this way from the start; `init`
also re-applies it (`chown -R root:root` + traversable, not writable) on
every run, so an existing install from before this was fixed self-heals
without a manual step. `deploy`/CI can still read and execute everything
here; updating ddeploy's own code needs `sudo git -C /opt/ddeploy pull`
— deliberately a root-only action, not a plain `git pull`.

## Per-site isolation

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

## Git access

All git operations (clone, pull) authenticate with one shared SSH key,
placed at `GIT_DEPLOY_KEY`. This should be a machine-user account (bot
GitHub/GitLab/Bitbucket user, not a personal one) added as a read-only
collaborator on each client repo or org — not a GitHub "deploy key",
which is limited to one repo and can't be reused across a fleet. `init`
`chown root:root`/`chmod 600`s it and seeds `/etc/ssh/ssh_known_hosts`
with GitHub/GitLab/Bitbucket host keys.

ddeploy's own git operations — the initial clone, every `deploy`/
rollback's fetch/pull/checkout/reset, a branch preview's refresh — all
run as **root**, straight off that one file via `GIT_SSH_COMMAND`. They
never run as the site's own `www-<name>` user: `provision`/`deploy`
already require root end to end, so routing the actual git call through
`sudo -u www-<name>` bought no real isolation (root was still the one
invoking sudo) — it only meant the key had to be copied somewhere that
user could read it.

That copy is exactly what an older version of this tool did: it placed
the key at `$dir/.ssh` (that site's own `$HOME`), readable by
`www-<name>` at any time. A compromise in *any one* site's web app (an
RCE in a bad dependency, say — that process runs as `www-<name>`) could
read that copy and get git-read access to *every other client's repo*
on the fleet. `provision`/`deploy`/`deploy-preview` now wipe any
leftover copy from an older run instead of writing a new one.

The one place a site's own user genuinely needs live key access is
opaque, project-declared code that runs as `www-<name>` — `composer
install` against a private VCS package, a `hooks.post-start` `exec`
step, `.provisioner/post-provision.sh`/`post-deploy.sh` — since ddeploy
can't know in advance whether any of that needs git/SSH. For just that
window, `provision`/`deploy`/`deploy-preview` start a per-deploy
`ssh-agent` running *as* `www-<name>`, and root loads `GIT_DEPLOY_KEY`
into it directly (`ssh-add`, over the agent's own socket) — the key
bytes cross into the agent but are never written to a file that user can
read. `SSH_AUTH_SOCK` is threaded into every hook subprocess; the agent
is killed the moment hook replay finishes (even if a hook fails). Net
effect: a private composer/VCS dependency still resolves with **zero
client-project changes**, but the key exists on that site's filesystem
for close to zero time instead of permanently — an attacker would need
to compromise the app *during that one deploy's hook-replay window* and
specifically reach for the agent socket, and even then could only use it
for that window, never extract the key itself for reuse elsewhere.

## The webhook listener never holds the HMAC secret

HMAC is symmetric — a process that can verify a signature can also forge
one. A version of this tool that had the listener check signatures
itself was only as safe as that one unprivileged Python process staying
uncompromised forever; a bug there would have meant an attacker could
write jobs straight into the spool, skipping verification entirely.

Instead the listener (`ddeploy-hook` user) does the least it can:
enforce a size limit, and spool the *raw* request (headers + body,
unverified) as `raw-<id>.json`. Real HMAC verification and forge-payload
parsing happen in `hook/verify_and_spool.py`, invoked by the root worker
(`hook-worker`) when it drains the spool — `$WEBHOOK_SECRET` itself is
`root:root` `600`, something the listener's own user cannot read no
matter what code ends up running in that process. A job only ever
reaches `hook_process_job` (the thing that actually calls
`deploy`/`provision-preview`/etc.) after that independent, root-context
check passes.

Consequence: the listener can no longer tell a good signature from a bad
one at request time, so every structurally-valid POST gets `202` now,
correctly signed or not — a bad/missing secret is rejected later,
asynchronously, in the worker's own logs, not with a synchronous `401`
GitHub/Bitbucket's delivery UI would show. A missing signature header
entirely still gets a `401` immediately (nothing to even queue), but a
present-and-wrong one — the case that actually matters, e.g. a typo'd
secret — will show as "delivered" in the forge's own UI. Check
`journalctl -u ddeploy-hook-worker` or this tool's own per-site logs to
catch that, not the forge's delivery log.

## Queue workers and scheduled tasks run project-declared commands safely

A `queue_workers`/`schedule` entry (README "Queue workers & scheduled
tasks") is a full shell command declared in the client's own
`.ddeploy/config.yaml` — trusted the same way a `hooks.post-start` step
already is, but still never handed to systemd or cron directly. Each one
is spliced into a small generated wrapper script
(`generated/<name>.worker-<i>.sh` / `.schedule-<i>.sh`) that `cd`s into
the site and sets up its PATH/PHP-version pinning, and *that script* is
what's actually referenced — sidestepping systemd's own unit-file
quoting and `%`-specifier-expansion rules entirely (a literal `%` or `$`
in a command is never at risk of being misread as unit-file syntax,
since the file systemd/cron invoke never contains the raw command text).

`schedule`'s cron.d line runs the wrapper via `root runuser -u
www-<name> -- <script>`, not `www-<name>` as the line's own user field
directly. `www-<name>` is created with `--shell /usr/sbin/nologin`
(never logs in interactively), and cron silently refuses to exec
*anything* for a user whose shell isn't a real one — no error, no log
line, it just never runs. `runuser` setuid()s straight to `www-<name>`
without going through cron's own shell lookup, so the job still actually
runs as the site's own user; root only ever appears in the cron.d file's
own user field.

## The database admin account is broader than any one site needs

`init-db`'s admin account has `GRANT ALL ON *.* WITH GRANT OPTION` — full
control of every database on that server, not just the ones this tool
manages — scoped only by source IP (`DB_ALLOWED_HOSTS`), and shared
across every web server that gets a copy of `DB_ADMIN_CREDENTIALS`.
Provisioning/deploying/backing up a site on demand needs an account that
can create databases and grant per-site users, and MySQL has no clean
"can `CREATE DATABASE` and `GRANT` on what it creates, but nothing else"
role.

The real options were a wildcard-prefix grant (forces every site's DB
name under one prefix, still one shared account, needs a naming
convention + migration) or a per-web-server admin account (limits blast
radius to one server's compromise instead of the whole fleet's, no
schema change, but doesn't shrink the account's own privileges). Neither
is a clean win over the other, so this stays as-is — keep
`DB_ADMIN_CREDENTIALS` file permissions tight (600, root-owned) and
`DB_ALLOWED_HOSTS` as narrow as possible.

Every site's own database import/restore (`load_sql_dump_into_db`) runs
as that site's own, scoped DB user instead — never this admin account —
specifically so a hostile or malformed dump (a client-provided
`--from-file` export, an object-storage backup) can't use its own
content to `DROP` an unrelated database, `CREATE USER`, or read
`mysql.*` directly.
