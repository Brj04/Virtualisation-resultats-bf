#!/usr/bin/env bash
set -euo pipefail

# Charger les fonctions communes
source /vagrant/scripts/common.sh

# Parametres PostgreSQL
PRIMARY_IP="$(ip_de bdd1)"
PG_VERSION="16"

DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
TEMP_DIR="/var/lib/postgresql/${PG_VERSION}/main.replique"
BACKUP_DIR="/var/lib/postgresql/${PG_VERSION}/main.initial"
PROMOTED_MARKER="/var/lib/postgresql/.resultats-bdd2-promoted"
PGPASS_FILE="/var/lib/postgresql/.pgpass"

log "Debut de la configuration de la replique bdd2"

# Verifier les variables indispensables
: "${PRIMARY_IP:?Adresse IP de bdd1 introuvable}"
: "${DB_NAME:?DB_NAME est obligatoire}"
: "${DB_USER:?DB_USER est obligatoire}"
: "${DB_PASSWORD:?DB_PASSWORD est obligatoire}"
: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD est obligatoire}"

# Ne jamais ecraser une replique deja promue
if [ -f "$PROMOTED_MARKER" ]; then
    log "ERREUR : bdd2 a deja ete promue. Aucune modification effectuee."
    exit 1
fi

# Installer PostgreSQL avant de verifier ses repertoires
apt_install postgresql-16 postgresql-client-16

# Verifier les repertoires avant toute operation
if [ ! -d "$DATA_DIR" ]; then
    log "ERREUR : le repertoire PostgreSQL $DATA_DIR est introuvable."
    exit 1
fi

if [ -e "$TEMP_DIR" ]; then
    log "ERREUR : le repertoire temporaire $TEMP_DIR existe deja."
    exit 1
fi

if [ -e "$BACKUP_DIR" ]; then
    log "ERREUR : une sauvegarde initiale existe deja : $BACKUP_DIR"
    exit 1
fi

# Verifier que bdd1 est accessible
if ! pg_isready -h "$PRIMARY_IP" -p 5432; then
    log "ERREUR : bdd1 est inaccessible."
    exit 1
fi

# Verifier que bdd1 est bien le serveur primaire
ETAT_PRIMAIRE=$(PGPASSWORD="$DB_PASSWORD" psql \
    -h "$PRIMARY_IP" \
    -p 5432 \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -Atc "SELECT pg_is_in_recovery();" | tr -d '\r')

if [ "$ETAT_PRIMAIRE" != "f" ]; then
    log "ERREUR : bdd1 n'est pas le serveur primaire."
    exit 1
fi

# Configurer PostgreSQL avec les fonctions communes
configurer_postgres

# Si une replique existe deja, verifier son etat
if [ -f "$DATA_DIR/standby.signal" ]; then
    log "Une replique existe deja. Verification de son demarrage."

    systemctl enable postgresql

    if ! systemctl is-active --quiet postgresql; then
        pg_ctlcluster "$PG_VERSION" main start
    fi

    ETAT=$(sudo -u postgres psql -Atc \
        "SELECT pg_is_in_recovery();" | tr -d '\r')

    if [ "$ETAT" != "t" ]; then
        log "ERREUR : le cluster existant n'est pas en mode replique."
        exit 1
    fi

    log "La replique bdd2 existe et fonctionne."
    installer_node_exporter
    exit 0
fi

# Refuser d'ecraser une base applicative deja presente
if systemctl is-active --quiet postgresql; then

    DB_EXISTANTE=$(sudo -u postgres psql -Atc \
        "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")

    if [ "$DB_EXISTANTE" = "1" ]; then
        log "ERREUR : la base $DB_NAME existe deja sur bdd2."
        log "Aucune donnee ne sera ecrasee."
        exit 1
    fi
fi

# Arreter le cluster local avant le clonage
log "Arret du cluster PostgreSQL local"

if systemctl is-active --quiet postgresql; then
    pg_ctlcluster "$PG_VERSION" main stop
fi

# Preparer le repertoire temporaire
install -d -o postgres -g postgres -m 700 "$TEMP_DIR"

# Creer le fichier d'authentification PostgreSQL
install -o postgres -g postgres -m 600 /dev/null "$PGPASS_FILE"

printf '%s:5432:replication:replicator:%s\n' \
    "$PRIMARY_IP" "$REPLICATION_PASSWORD" > "$PGPASS_FILE"

chown postgres:postgres "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

# Copier physiquement bdd1 vers bdd2
log "Copie physique de bdd1 vers bdd2"

if ! sudo -u postgres env \
    PGPASSFILE="$PGPASS_FILE" \
    PGPASSWORD="$REPLICATION_PASSWORD" \
    pg_basebackup \
        -h "$PRIMARY_IP" \
        -p 5432 \
        -U replicator \
        -D "$TEMP_DIR" \
        -Fp -Xs -P -R; then

    rm -rf "$TEMP_DIR"
    log "ERREUR : echec de pg_basebackup."
    log "Le cluster initial est conserve."
    exit 1
fi

# Conserver le cluster initial sans le supprimer
mv "$DATA_DIR" "$BACKUP_DIR"
mv "$TEMP_DIR" "$DATA_DIR"

chown -R postgres:postgres "$DATA_DIR"

# Demarrer PostgreSQL en mode replique
systemctl enable postgresql
pg_ctlcluster "$PG_VERSION" main start

# Verifier le mode de fonctionnement
ETAT=$(sudo -u postgres psql -Atc \
    "SELECT pg_is_in_recovery();" | tr -d '\r')

if [ "$ETAT" != "t" ]; then
    log "ERREUR : bdd2 n'est pas en mode replique."
    exit 1
fi

# Attendre la confirmation du streaming pendant 15 secondes
REPLICATION_ACTIVE=""

for i in $(seq 1 15); do
    REPLICATION_ACTIVE=$(sudo -u postgres psql -Atc "SELECT status FROM pg_stat_wal_receiver;" | tr -d '\r' || true)

    if [ "$REPLICATION_ACTIVE" = "streaming" ]; then
        break
    fi

    sleep 1
done

if [ "$REPLICATION_ACTIVE" != "streaming" ]; then
    log "ATTENTION : la replique est en recovery, mais le streaming n'est pas confirme apres 15 secondes."
    exit 1
fi
installer_node_exporter

log "Replication configuree avec succes sur bdd2"
log "Adresse du primaire : $PRIMARY_IP"