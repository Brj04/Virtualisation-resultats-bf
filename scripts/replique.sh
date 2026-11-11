#!/usr/bin/env bash
set -euo pipefail

source /vagrant/scripts/common.sh

PRIMARY_IP="192.168.63.31"
REPLICA_IP="192.168.63.32"
PG_VERSION="16"
DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
TEMP_DIR="/var/lib/postgresql/${PG_VERSION}/main.replique"
BACKUP_DIR="/var/lib/postgresql/${PG_VERSION}/main.initial"
PROMOTED_MARKER="/var/lib/postgresql/.resultats-bdd2-promoted"

log "Début de la configuration de bdd2"

: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD est obligatoire}"

# Ne jamais écraser une ancienne réplique qui a été promue.
if [ -f "$PROMOTED_MARKER" ]; then
    log "ERREUR : bdd2 a déjà été promue. Aucune modification effectuée."
    exit 1
fi

apt_install postgresql-16 postgresql-client-16

# Vérifier que le cluster PostgreSQL existe.
if [ ! -d "$DATA_DIR" ]; then
    log "ERREUR : le répertoire PostgreSQL $DATA_DIR est introuvable."
    exit 1
fi

# Configurer le serveur secondaire.
mkdir -p "/etc/postgresql/${PG_VERSION}/main/conf.d"

cat > "/etc/postgresql/${PG_VERSION}/main/conf.d/90-resultats.conf" <<'CONF'
listen_addresses = '*'
hot_standby = on
max_connections = 150
wal_level = replica
max_wal_senders = 5
wal_keep_size = '128MB'
CONF

# Autoriser les applications du réseau à consulter la réplique.
HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
sed -i '/# BEGIN RESULTATS/,/# END RESULTATS/d' "$HBA"
cat >> "$HBA" <<'HBA'
# BEGIN RESULTATS
host all resultats_app 192.168.63.0/24 scram-sha-256
# END RESULTATS
HBA

# Si la réplication est déjà configurée, ne pas refaire le clonage.
if [ -f "$DATA_DIR/standby.signal" ]; then
    log "Une réplique existe déjà. Vérification du démarrage."
    systemctl enable postgresql
    pg_ctlcluster "$PG_VERSION" main start || true
    exit 0
fi

# Refuser d'écraser une base qui contient déjà des données applicatives.
if systemctl is-active --quiet postgresql; then
    DB_LIST=$(sudo -u postgres psql -Atc "SELECT datname FROM pg_database WHERE datallowconn = true ORDER BY datname;" 2>/dev/null || true)
    if echo "$DB_LIST" | grep -qx "resultats"; then
        log "ERREUR : une base resultats existe déjà sur bdd2. Refus de l'écraser."
        exit 1
    fi
fi

log "Arrêt du cluster PostgreSQL local"
pg_ctlcluster "$PG_VERSION" main stop || true

# Préparer un répertoire temporaire vide pour recevoir la copie physique.
if [ -e "$TEMP_DIR" ]; then
    log "ERREUR : le répertoire temporaire $TEMP_DIR existe déjà."
    exit 1
fi

install -d -o postgres -g postgres -m 700 "$TEMP_DIR"

# Créer le fichier d'authentification utilisé par pg_basebackup et la réplique.
install -o postgres -g postgres -m 600 /dev/null /var/lib/postgresql/.pgpass
printf '%s:5432:replication:replicator:%s\n' "$PRIMARY_IP" "$REPLICATION_PASSWORD" > /var/lib/postgresql/.pgpass
chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

log "Copie physique de bdd1 vers bdd2"
if ! sudo -u postgres env PGPASSWORD="$REPLICATION_PASSWORD" pg_basebackup \
    -h "$PRIMARY_IP" \
    -p 5432 \
    -U replicator \
    -D "$TEMP_DIR" \
    -Fp -Xs -P -R; then
    rm -rf "$TEMP_DIR"
    log "ERREUR : échec de pg_basebackup. Le cluster existant est conservé."
    exit 1
fi

# Conserver le cluster initial au lieu de le supprimer.
if [ -e "$BACKUP_DIR" ]; then
    log "ERREUR : une sauvegarde initiale existe déjà : $BACKUP_DIR"
    exit 1
fi

mv "$DATA_DIR" "$BACKUP_DIR"
mv "$TEMP_DIR" "$DATA_DIR"
chown -R postgres:postgres "$DATA_DIR"

systemctl enable postgresql
pg_ctlcluster "$PG_VERSION" main start

# Vérifier que PostgreSQL fonctionne bien en mode secondaire.
IS_REPLICA=$(sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();")
if [ "$IS_REPLICA" != "t" ]; then
    log "ERREUR : bdd2 n'est pas en mode réplique."
    exit 1
fi

installer_node_exporter

log "Réplication configurée avec succès sur bdd2"
