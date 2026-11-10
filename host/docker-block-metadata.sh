# Blocks Docker containers and image builds from Oracle Cloud's link-local
# services (169.254.0.0/16: the instance metadata service at 169.254.169.254
# and others), except DNS to 169.254.169.254, which is Oracle's resolver and
# which containers and builds need. The host itself is not affected.
#
# Install (once, in your own SSH terminal; asks for the sudo password):
#   bash /home/ethan/docker/host/docker-block-metadata.sh
# Undo: see "Host firewall changes" in /home/ethan/docker/README.md, or the
# header of the installed helper (/usr/local/sbin/docker-block-metadata).
#
# What it installs:
#   /usr/local/sbin/docker-block-metadata            helper: `add` / `remove`
#   /etc/systemd/system/docker-block-metadata.service runs `add` whenever Docker
#                                                     starts, `remove` when it stops
# The rules live in their own chain, DOCKER-METADATA, reached by one jump from
# DOCKER-USER (the chain Docker leaves for admin rules and never flushes).
# Nothing is written to /etc/iptables/rules.v4: `netfilter-persistent save`
# would copy Docker's live chains into Oracle's rules file.

set -e

sudo tee /usr/local/sbin/docker-block-metadata >/dev/null <<'EOF'
#!/bin/sh
# Usage: docker-block-metadata add|remove
# Installed by /home/ethan/docker/host/docker-block-metadata.sh (homelab repo).
# Blocks containers from 169.254.0.0/16 except DNS to 169.254.169.254.
# UNDO:
#   sudo /usr/local/sbin/docker-block-metadata remove          # rules gone now
#   sudo systemctl disable --now docker-block-metadata.service # stop re-adding
#   sudo rm /etc/systemd/system/docker-block-metadata.service /usr/local/sbin/docker-block-metadata
#   sudo systemctl daemon-reload
#   sudo iptables -S DOCKER-USER     # check: no DOCKER-METADATA line left
# The rules live in their own chain, rebuilt in a fixed order on every `add`:
# DNS exceptions first, then the reject. A failure part-way leaves DNS working
# (and metadata reachable) rather than the other way round.
set -eu
IPT=/usr/sbin/iptables
SUB=DOCKER-METADATA
JUMP="-d 169.254.0.0/16 -j $SUB"
case "${1:-}" in
  add)
    $IPT -N $SUB 2>/dev/null || $IPT -F $SUB
    $IPT -A $SUB -d 169.254.169.254/32 -p udp --dport 53 -j RETURN
    $IPT -A $SUB -d 169.254.169.254/32 -p tcp --dport 53 -j RETURN
    $IPT -A $SUB -j REJECT
    # shellcheck disable=SC2086
    $IPT -C DOCKER-USER $JUMP 2>/dev/null || $IPT -I DOCKER-USER $JUMP
    ;;
  remove)
    # shellcheck disable=SC2086
    while $IPT -C DOCKER-USER $JUMP 2>/dev/null; do $IPT -D DOCKER-USER $JUMP; done
    if $IPT -n -L $SUB >/dev/null 2>&1; then $IPT -F $SUB; $IPT -X $SUB; fi
    ;;
  *) echo "usage: $0 add|remove" >&2; exit 2 ;;
esac
EOF
sudo chmod 755 /usr/local/sbin/docker-block-metadata

sudo tee /etc/systemd/system/docker-block-metadata.service >/dev/null <<'EOF'
[Unit]
Description=Block Docker containers from cloud link-local services (169.254.0.0/16, except DNS)
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/docker-block-metadata add
ExecStop=/usr/local/sbin/docker-block-metadata remove

[Install]
WantedBy=docker.service
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now docker-block-metadata.service
systemctl status docker-block-metadata --no-pager | head -3
sudo iptables -S DOCKER-USER
sudo iptables -S DOCKER-METADATA
