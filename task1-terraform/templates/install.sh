#!/usr/bin/env bash
# =====================================================================
# Runs once on first boot via cloud-init runcmd.
# Idempotent — safe to re-run via `sudo /opt/metabase/install.sh`.
# =====================================================================
set -euo pipefail
exec > >(tee -a /var/log/metabase-install.log) 2>&1
echo "[metabase-install] start: $(date -u)"

DATA_DEV=/dev/vdb              # second EVS attached by Terraform
DATA_MOUNT=/var/lib/docker
COMPOSE_DIR=/opt/metabase

# ---------------------------------------------------------------------
# 1. Format + mount EVS volume to /var/lib/docker (BEFORE installing Docker)
# ---------------------------------------------------------------------
if [ -b "$DATA_DEV" ]; then
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    echo "[metabase-install] formatting $DATA_DEV"
    mkfs.ext4 -F -L metabase-data "$DATA_DEV"
  fi
  mkdir -p "$DATA_MOUNT"
  UUID=$(blkid -s UUID -o value "$DATA_DEV")
  if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID  $DATA_MOUNT  ext4  defaults,nofail  0  2" >> /etc/fstab
  fi
  mountpoint -q "$DATA_MOUNT" || mount "$DATA_MOUNT"
else
  echo "[metabase-install] WARNING: $DATA_DEV not present — using root disk"
fi

# ---------------------------------------------------------------------
# 2. Install Docker CE + Compose plugin (Ubuntu 22.04)
# ---------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq

install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# ---------------------------------------------------------------------
# 3. Bring up the stack
# ---------------------------------------------------------------------
cd "$COMPOSE_DIR"
chmod 700 .secrets
chmod 600 .secrets/db_password
docker compose pull
docker compose up -d

echo "[metabase-install] done: $(date -u)"
echo "[metabase-install] tail logs: docker compose -f $COMPOSE_DIR/docker-compose.yml logs -f"
