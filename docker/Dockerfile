# Systemd-enabled Ubuntu 24.04, used for BOTH roles in the test harness
# (web server and dedicated DB server) — which role a container plays is
# decided at runtime by which provision.sh subcommand gets run against it
# (init vs init-db), not by anything baked in here. See docker/README.md.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# systemd as PID 1 (required for `systemctl` to work at all) plus the
# handful of tools the test harness itself needs beyond what the
# provisioner installs on its own (git/openssh for the local repo fixture,
# sudo for hook replay's `sudo -u www-<name>`).
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        openssh-server openssh-client \
        git curl ca-certificates openssl sudo python3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && systemctl mask systemd-udev-trigger systemd-udevd

# Real Go (mikefarah) yq, pre-installed — `init`'s own yq-install step
# needs `snap`, which isn't available in a container; pre-installing here
# means that step degrades to (and exercises) its detection/version-check
# logic instead of failing on a missing snap. Pinned + checksum-verified,
# same version/shas as install_pinned_yq in lib/cmd_init.sh (not
# releases/latest/download — a moving target with no integrity check) —
# keep both in sync by hand if YQ_VERSION there ever changes.
RUN set -e; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) sha=c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385 ;; \
        arm64) sha=88a1016bc1d657375a35864e4f44b6f333df8ff97b559f51bba0adcb2169df09 ;; \
        *) echo "no pinned yq checksum for architecture '$arch'" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/v4.53.6/yq_linux_${arch}"; \
    echo "${sha}  /usr/local/bin/yq" | sha256sum -c - ; \
    chmod +x /usr/local/bin/yq

# Mocks for the two things this harness can't exercise for real: certbot
# (needs a live public domain + real ACME account) and ufw (needs kernel
# netfilter access this harness doesn't grant). /usr/local/bin wins over
# apt's real /usr/bin installs of both via PATH order. See docker/README.md
# for exactly what that means is, and isn't, covered by this harness.
COPY docker/mocks/certbot /usr/local/bin/certbot
COPY docker/mocks/ufw /usr/local/bin/ufw
RUN chmod +x /usr/local/bin/certbot /usr/local/bin/ufw

COPY . /opt/ddeploy
WORKDIR /opt/ddeploy

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
