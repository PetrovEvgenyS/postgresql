#!/bin/bash
set -euo pipefail

# ===== Variables =====
PG_VERSION="16"
STANDBY_IP="10.10.10.2"
REPL_USER="replicator"
REPL_PASSWORD="Ee123456"
CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
PG_HBA="${CONF_DIR}/pg_hba.conf"
PG_CONF="${CONF_DIR}/postgresql.conf"

echo "[*] Updating postgresql.conf ..."
sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$PG_CONF" || true
sed -i "s/^#\?wal_level.*/wal_level = replica/" "$PG_CONF" || echo "wal_level = replica" | tee -a "$PG_CONF" >/dev/null
sed -i "s/^#\?max_wal_senders.*/max_wal_senders = 10/" "$PG_CONF" || echo "max_wal_senders = 10" | tee -a "$PG_CONF" >/dev/null
sed -i "s/^#\?max_replication_slots.*/max_replication_slots = 10/" "$PG_CONF" || echo "max_replication_slots = 10" | tee -a "$PG_CONF" >/dev/null

echo "[*] Updating pg_hba.conf ..."
ALLOW_REPL="host    replication    ${REPL_USER}    ${STANDBY_IP}/32    md5"
if ! grep -qF "$ALLOW_REPL" "$PG_HBA"; then
  echo "$ALLOW_REPL" | tee -a "$PG_HBA" >/dev/null
fi

echo "[*] Restarting PostgreSQL ..."
systemctl restart postgresql

echo "[*] Creating replication role ...]"
sudo -u postgres psql -c "CREATE ROLE \"${REPL_USER}\" WITH LOGIN REPLICATION ENCRYPTED PASSWORD '${REPL_PASSWORD}';"

  echo "[*] Ensuring physical replication slot exists (slot_standby) ..."
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='slot_standby') THEN 1 ELSE pg_create_physical_replication_slot('slot_standby') END;"
fi

echo "[*] Primary is configured. Check: SELECT client_addr, state FROM pg_stat_replication;"