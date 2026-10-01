# Fleet-wide ops hooks

Put them in `/etc/ddeploy/hooks/post-provision.d/` and
`/etc/ddeploy/hooks/post-deploy.d/` on the server (`init` creates both).
This directory only holds this README and the `.example` files.

Scripts there run for **every** site on this server, as **root**, at the
end of `provision` / `deploy` respectively — for operator concerns
(reverse-proxy lists, optional success pings), not site-specific
setup. **Failure** paging is `NOTIFY_WEBHOOK` in `provisioner.conf`, not
a hook here — these scripts only run after a successful provision/deploy.
For site-specific steps, use `hooks.post-deploy` / `hooks.post-provision`
in the client repo's `.ddeploy/config.yaml` (or the `.ddeploy/post-*.sh`
scripts) instead — see the main README, "Deploy hooks".

- `post-provision.d/*.sh` — run once, after a site's first deploy finishes.
- `post-deploy.d/*.sh` — run after every `deploy`.

Rules:
- Must be executable (`chmod +x`) or they're skipped with a warning.
- Run in sorted filename order — prefix with `NN-` to control ordering.
- Only `*.sh` files are picked up; anything else (including the
  `.sh.example` files in each directory) is ignored.
- Environment provided: `NAME`, `SITE_DIR`, `PHP_VERSION`, `BASE_DOMAIN`.
- These run as root for every site on the server — treat them as
  trusted, ops-authored code, not something client repos can influence.
