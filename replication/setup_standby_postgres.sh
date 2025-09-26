#!/bin/bash
set -euo pipefail

# ===== Variables =====
PG_VERSION="16"
PRIMARY_IP="10.10.10.1"
REPL_USER="replicator"
REPL_PASSWORD="your_password"
DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"

echo "[*] Stopping PostgreSQL on Standby ..."
systemctl stop postgresql || true

echo "[*] Cleaning data dir ${DATA_DIR} ..."
rm -rf "${DATA_DIR:?}/"*

echo "[*] Running pg_basebackup from Primary ..."
export PGPASSWORD="${REPL_PASSWORD}"
sudo -u postgres pg_basebackup -h "$PRIMARY_IP" -U "$REPL_USER" -D "$DATA_DIR" -X stream -R -P
unset PGPASSWORD

echo "[*] Fixing ownership ..."
chown -R postgres:postgres "$DATA_DIR"

echo "[*] Starting PostgreSQL on Standby ..."
systemctl start postgresql

echo "[*] Standby initialized. Check: SELECT pg_is_in_recovery();"
