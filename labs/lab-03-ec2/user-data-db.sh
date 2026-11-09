#!/bin/bash
# USMS data tier bootstrap. Runs as root via cloud-init. Idempotent: exits if already done.
MARKER=/var/log/usms-db-bootstrap.done
[ -f "$MARKER" ] && { echo "already bootstrapped"; exit 0; }
exec > /var/log/usms-db-bootstrap.log 2>&1
set -x

PKG=$(command -v dnf || command -v yum)
$PKG -y install postgresql-server

postgresql-setup --initdb || /usr/bin/postgresql-setup initdb
systemctl enable --now postgresql
sudo -u postgres createdb usms

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
echo "$IID $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
