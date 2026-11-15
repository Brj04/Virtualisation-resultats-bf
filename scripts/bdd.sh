
#!/usr/bin/env bash
# RÉSULTATS-BF : installation et configuration du serveur PostgreSQL principal.
# Machine concernée : bdd1.
# Le script est conçu pour pouvoir être exécuté plusieurs fois.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------
# 1. Vérification des paramètres et des secrets
# ----------------------------------------------------------

: "${RESEAU:?RESEAU doit être fourni par le Vagrantfile}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD doit être défini}"
: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD doit être défini}"

if [[ "$APP_DB_PASSWORD" == "changez_moi" ||
      "$REPLICATION_PASSWORD" == "changez_moi" ]]; then
    echo "ERREUR : remplacez les mots de passe exemples dans .env." >&2
    exit 1
fi

DB_NAME="resultatsbf"
APP_USER="resultats_app"
REPL_USER="replicateur"
CIDR="${RESEAU}.0/24"

echo "=== Configuration PostgreSQL sur bdd1 ==="

# ----------------------------------------------------------
# 2. Installation de PostgreSQL
# ----------------------------------------------------------

if ! command -v psql >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq postgresql
fi

# Recherche du cluster PostgreSQL principal.
CLUSTER_DIR=$(find /etc/postgresql \
    -mindepth 2 -maxdepth 2 \
    -type d -name main | sort -V | tail -n 1)

if [[ -z "$CLUSTER_DIR" ]]; then
    echo "ERREUR : aucun cluster PostgreSQL main trouvé." >&2
    exit 1
fi

PG_VERSION=$(basename "$(dirname "$CLUSTER_DIR")")
PG_CONF="$CLUSTER_DIR/postgresql.conf"
PG_HBA="$CLUSTER_DIR/pg_hba.conf"

echo "Version PostgreSQL détectée : $PG_VERSION"

# ----------------------------------------------------------
# 3. Configuration réseau et réplication
# ----------------------------------------------------------

install -d -m 755 "$CLUSTER_DIR/conf.d"

cat > "$CLUSTER_DIR/conf.d/resultats-bf.conf" <<EOF
# Configuration RÉSULTATS-BF
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
password_encryption = 'scram-sha-256'
EOF

# Ajout des règles d'accès sans les dupliquer.
MARKER="# REGLES RESULTATS-BF"

if ! grep -qF "$MARKER" "$PG_HBA"; then
    cat >> "$PG_HBA" <<EOF

$MARKER
host    $DB_NAME    $APP_USER    $CIDR    scram-sha-256
host    replication $REPL_USER   ${RESEAU}.32/32    scram-sha-256
EOF
fi

# Vérification de la présence de l'inclusion conf.d.
if ! grep -qE '^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'\''conf.d'\''' "$PG_CONF"; then
    echo "include_dir = 'conf.d'" >> "$PG_CONF"
fi

systemctl enable postgresql >/dev/null
systemctl restart postgresql

if ! pg_isready -q; then
    echo "ERREUR : PostgreSQL ne répond pas." >&2
    exit 1
fi

echo "PostgreSQL est opérationnel."

# ----------------------------------------------------------
# 4. Création des utilisateurs et de la base
# ----------------------------------------------------------

# Les secrets sont lus depuis l'environnement par psql.
# Ils ne sont pas écrits en clair dans un fichier SQL.

sudo -u postgres --preserve-env=APP_DB_PASSWORD,REPLICATION_PASSWORD \
    psql -v ON_ERROR_STOP=1 <<'SQL'

\getenv app_password APP_DB_PASSWORD
\getenv repl_password REPLICATION_PASSWORD

-- Création de l'utilisateur de l'application.
SELECT format(
    'CREATE ROLE resultats_app LOGIN PASSWORD %L',
    :'app_password'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'resultats_app'
)
\gexec

SELECT format(
    'ALTER ROLE resultats_app WITH LOGIN PASSWORD %L',
    :'app_password'
)
\gexec

-- Création de l'utilisateur de réplication.
SELECT format(
    'CREATE ROLE replicateur LOGIN REPLICATION PASSWORD %L',
    :'repl_password'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'replicateur'
)
\gexec

SELECT format(
    'ALTER ROLE replicateur WITH LOGIN REPLICATION PASSWORD %L',
    :'repl_password'
)
\gexec

-- Création de la base si elle n'existe pas.
SELECT 'CREATE DATABASE resultatsbf OWNER postgres'
WHERE NOT EXISTS (
    SELECT 1 FROM pg_database WHERE datname = 'resultatsbf'
)
\gexec

SQL

# ----------------------------------------------------------
# 5. Création et alimentation de la table
# ----------------------------------------------------------

if [[ ! -f /vagrant/sql/init.sql ]]; then
    echo "ERREUR : /vagrant/sql/init.sql est introuvable." >&2
    exit 1
fi

sudo -u postgres psql \
    -v ON_ERROR_STOP=1 \
    -d "$DB_NAME" \
    -f /vagrant/sql/init.sql

# L'application doit pouvoir consulter les résultats.
sudo -u postgres psql \
    -v ON_ERROR_STOP=1 \
    -d "$DB_NAME" <<SQL
GRANT CONNECT ON DATABASE $DB_NAME TO $APP_USER;
GRANT USAGE ON SCHEMA public TO $APP_USER;
GRANT SELECT ON TABLE resultats TO $APP_USER;
SQL

# ----------------------------------------------------------
# 6. Vérification finale
# ----------------------------------------------------------


echo "Nombre de résultats dans la base :"

sudo -u postgres psql \
    -v ON_ERROR_STOP=1 \
    -d "$DB_NAME" \
    -c "SELECT COUNT(*) AS nombre_resultats FROM resultats;"

echo "=== Configuration de bdd1 terminée ==="
