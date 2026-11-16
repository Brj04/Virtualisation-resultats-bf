#!/usr/bin/env bash
set -euo pipefail

# Charger les fonctions communes
source /vagrant/scripts/common.sh

log "Debut du provisionnement de la base PostgreSQL"

# Verifier les variables indispensables
: "${DB_PASSWORD:?DB_PASSWORD est obligatoire}"
: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD est obligatoire}"
: "${DB_NAME:?DB_NAME est obligatoire}"
: "${DB_USER:?DB_USER est obligatoire}"

# Installer PostgreSQL
apt_install postgresql postgresql-contrib

# Configurer PostgreSQL pour la replication
configurer_postgres

# Demarrer PostgreSQL
systemctl enable --now postgresql

# Creer ou actualiser les comptes PostgreSQL
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -v app_user="$DB_USER" \
  -v app_password="$DB_PASSWORD" \
  -v replication_password="$REPLICATION_PASSWORD" <<'SQL'

SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L',
    :'app_user',
    :'app_password'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = :'app_user'
)
\gexec

ALTER ROLE :"app_user" LOGIN PASSWORD :'app_password';

SELECT format(
    'CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD %L',
    :'replication_password'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'replicator'
)
\gexec

ALTER ROLE replicator WITH REPLICATION PASSWORD :'replication_password';

SQL

# Creer la base si elle n'existe pas
BASE_EXISTANTE=$(sudo -u postgres psql -tAc \
  "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")

if [ "$BASE_EXISTANTE" != "1" ]; then
    sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
    log "Base $DB_NAME creee"
else
    log "Base $DB_NAME deja existante"
fi

# Verifier la presence du fichier SQL
if [ ! -f /vagrant/sql/init.sql ]; then
    log "ERREUR : /vagrant/sql/init.sql introuvable"
    exit 1
fi

# Charger le schema et les donnees
sudo -u postgres psql \
  -v ON_ERROR_STOP=1 \
  -d "$DB_NAME" < /vagrant/sql/init.sql

# Redemarrer PostgreSQL uniquement si sa configuration a change
if [ "${CHANGED:-0}" = "1" ]; then
    systemctl restart postgresql
    log "PostgreSQL redemarre apres modification de configuration"
else
    log "Aucune modification de configuration PostgreSQL"
fi

# Installer node_exporter si le noeud d'observation est active
installer_node_exporter

# Afficher le nombre final de resultats
NOMBRE=$(sudo -u postgres psql \
  -d "$DB_NAME" \
  -tAc "SELECT COUNT(*) FROM resultats")

log "Nombre total de resultats : $NOMBRE"
log "Provisionnement de la base PostgreSQL termine"