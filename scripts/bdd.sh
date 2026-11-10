
#!/usr/bin/env bash
set -euo pipefail

# Charger les fonctions communes
source /vagrant/scripts/common.sh

log "Début du provisionnement de bdd1"

# Vérifier les mots de passe transmis par Vagrant
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD est obligatoire}"
: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD est obligatoire}"

# Installer PostgreSQL
apt_install postgresql postgresql-contrib

# Activer et démarrer PostgreSQL
systemctl enable --now postgresql

# Configurer PostgreSQL pour la réplication
configurer_postgres

# Créer ou actualiser les comptes PostgreSQL
sudo -u postgres psql \
  -v app_password="$DB_PASSWORD" \
  -v replication_password="$REPLICATION_PASSWORD" <<'SQL'

SELECT format(
    'CREATE ROLE resultats_app LOGIN PASSWORD %L',
    :'app_password'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'resultats_app'
)
\gexec

ALTER ROLE resultats_app LOGIN PASSWORD :'app_password';

SELECT format(
    'CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD %L',
    :'replication_password'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'replicator'
)
\gexec

ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD :'replication_password';

SQL

# Créer la base si elle n'existe pas
if ! sudo -u postgres psql -tAc \
  "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
    sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
    log "Base $DB_NAME créée"
else
    log "Base $DB_NAME déjà existante"
fi

# Charger le schéma et les données
if [ ! -f /vagrant/sql/init.sql ]; then
    log "ERREUR : /vagrant/sql/init.sql introuvable"
    exit 1
fi

sudo -u postgres psql \
  -v ON_ERROR_STOP=1 \
  -d "$DB_NAME" \
  -f /vagrant/sql/init.sql

# Redémarrer PostgreSQL pour appliquer la configuration
systemctl restart postgresql

# Installer node_exporter si le nœud d'observation est activé
installer_node_exporter

log "Provisionnement de bdd1 terminé"
