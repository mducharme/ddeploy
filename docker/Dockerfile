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
# logic instead of failing on a missing snap.
RUN curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" \
    && chmod +x /usr/local/bin/yq

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
