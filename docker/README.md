# Docker test harness

Runs the actual provisioner — `init`, `init-db`, `provision`, `deploy`,
branch previews, backup/restore, `remove` — against real systemd, nginx,
PHP-FPM, MariaDB, sshd, and object storage in disposable containers. This
is what closes the biggest gap in this project: until now, everything had
only ever been syntax-checked, shellchecked, and run against mocked
system calls on macOS — never actually executed as root on a real (or
real-enough) Linux box.

## Run it

```
docker/test/run.sh          # build, run, tear down
docker/test/run.sh --keep   # leave containers up afterward for poking around
```

Needs Docker with `--privileged` containers allowed (systemd needs this)
and internet egress (apt packages, the ondrej/php PPA, Cloudflare's public
IP-ranges endpoint, and GitHub for the yq binary are all fetched for
real).

## What's real

- **systemd, nginx, PHP-FPM, MariaDB, sshd, ufw's rule-tracking logic** —
  actual Ubuntu 24.04 packages, actual services, actual config files
  `nginx -t`/`php-fpm -t` actually validate.
- **A remote (`init-db`) database server** — a second container, wired up
  exactly like a real dedicated DB host: `DB_ALLOWED_HOSTS` scoped to the
  web container's real IP, `DB_ADMIN_CREDENTIALS` generated on one
  container and copied to the other, MySQL grants and connections over a
  real Docker network.
- **Git over SSH** — a local sshd + bare repo + a generated ed25519
  keypair used as `GIT_DEPLOY_KEY`, so `git_ssh_command`/`sync_site_ssh`
  (lib/git_access.sh) run against a real SSH server, not a shortcut.
- **Backup/restore against real object storage** — a MinIO container
  standing in for S3/Spaces/B2, so `rclone sync`/`copy` (and the exact
  connection-string quoting this project had a real bug in once already)
  run against a real S3-compatible endpoint.
- **Cloudflare's real-IP config** — `fetch_cloudflare_ranges` hits
  Cloudflare's actual public `ips-v4`/`ips-v6` endpoints; no mocking
  needed since they're public and unauthenticated.
- **The full site lifecycle** — provision, deploy, additional hostnames,
  a custom domain (two-phase HTTP-01 vhost swap), a shared-mode branch
  preview (including its no-Linux-user-of-its-own and basic-auth-on
  invariants), deploy-preview, prune-previews (the real
  `git ls-remote --exit-code` path), backup/restore round-trips with
  actual data-loss-then-recovery checks, and removal — all asserted
  against actual command output and actual file/database state, not just
  "the script exited 0".

## What's mocked, and why

- **`certbot`** (`docker/mocks/certbot`) — real ACME issuance needs a
  live public domain under DNS control this harness doesn't have. The
  mock parses the same `-d` flags the real invocations use and drops a
  self-signed cert at the exact `/etc/letsencrypt/live/<name>` path the
  real thing would, so everything downstream (nginx config, "does a cert
  already exist" checks) still runs for real.
- **`ufw`** (`docker/mocks/ufw`) — real enforcement needs reliable
  `NET_ADMIN`/nf_tables access in the container, which is fragile to
  depend on for a repeatable test; firewall *enforcement* also isn't what
  this harness is trying to prove. The mock keeps just enough state to
  exercise the actual rule-management logic (add, list numbered, delete
  by number) faithfully, including the exact `[ N]`-padded output format
  real `ufw status numbered` uses — that padding is what an earlier bug
  in the "delete previously-added rules" cleanup (lib/cloudflare.sh,
  lib/cmd_init_db.sh) missed; it was confirmed and fixed against a real,
  one-off `--privileged` ufw container, not through this mock.

**Not covered at all**, still open: real ACME/DNS-01 issuance (needs a
live domain — verify manually against a real Cloudflare zone before
relying on it), and ufw's actual packet-filtering behavior (verify on a
real VM/droplet).

`init` no longer installs yq via `snap` at all (it downloads a pinned Go
yq binary directly instead — see the comment in `lib/cmd_init.sh`) after
a real deployment hit snap's strict AppArmor confinement blocking every
`yq` call from reading anything under `SITES_ROOT`, since root doesn't
bypass that the way it bypasses ordinary file permissions. This harness
never caught it because the image pre-installs yq the same (now-correct)
way `init` does, so the container never exercised the broken path either
— confirmed and fixed against the real failure, not through this
harness.

## Layout

```
docker/
  Dockerfile              one image, plays both roles (web / dbhost)
  docker-compose.yml       dbhost + web + objectstore(MinIO), on one network
  mocks/                   certbot, ufw — see above
  fixtures/testsite/       a minimal site: .ddev/config.yaml, one PHP file
                           that proves DB connectivity, additional
                           hostname + custom domain declared
  test/
    run.sh                 host-side orchestrator — start here
    lib.sh                 assert helpers, sourced by the step scripts
    steps/                 run INSIDE the containers, in order:
      00-fixtures.sh        web: local sshd + bare git repo + deploy key
      01-init-db.sh          dbhost: init-db + checks
      02-init.sh              web: init + checks
      03-lifecycle.sh          web: provision/deploy/preview/backup/remove
    generated/              provisioner.conf + credentials run.sh writes
                            per-run (gitignored)
```
