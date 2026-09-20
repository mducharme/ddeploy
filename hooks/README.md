# Fleet-wide ops hooks

Scripts here run for **every** site on this server, as **root**, at the
end of `provision` / `deploy` respectively — for operator concerns
(reverse-proxy lists, optional success pings), not site-specific
setup. **Failure** paging is `NOTIFY_WEBHOOK` in `provisioner.conf`, not
a hook here — these scripts only run after a successful provision/deploy.
For site-specific one-offs, use `.provisioner/post-provision.sh` /
`.provisioner/post-deploy.sh` in the client repo instead (see main README).

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
