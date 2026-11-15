
#!/usr/bin/env bash
# RÉSULTATS-BF : reconstruction de bdd1 comme réplica de bdd2.
# À exécuter sur bdd1 après la promotion de bdd2.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------
# 1. Confirmation et contrôles initiaux
# ----------------------------------------------------------

if [[ "${1:-}" != "--confirm-bdd1-fenced" ]]; then
    echo "ERREUR : confirmation obligatoire." >&2
    echo "Utilisation : $0 --confirm-bdd1-fenced" >&2
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : exécuter ce script en tant que root." >&2
    exit 1
fi

if [[ "$(hostname -s)" != "bdd1" ]]; then
    echo "ERREUR : ce script doit être exécuté sur bdd1." >&2
    exit 1
fi


# Charger le secret depuis /vagrant/.env si Vagrant ne l'a pas transmis.
# On lit uniquement la variable attendue : on n'exécute pas le fichier .env.
if [[ -z "${REPLICATION_PASSWORD:-}" ]]; then
    ENV_FILE="/vagrant/.env"

    if [[ ! -f "$ENV_FILE" ]]; then
        echo "ERREUR : variable absente et fichier $ENV_FILE introuvable." >&2
        exit 1
    fi

    REPLICATION_PASSWORD=$(awk -F= '
        /^[[:space:]]*REPLICATION_PASSWORD[[:space:]]*=/ {
            sub(/^[^=]*=/, "")
            sub(/[[:space:]]+#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (substr($0, 1, 1) == "\"" &&
                substr($0, length($0), 1) == "\"") {
                $0 = substr($0, 2, length($0) - 2)
            }
            print
            exit
        }
    ' "$ENV_FILE")
fi

if [[ -z "$REPLICATION_PASSWORD" ]]; then
    echo "ERREUR : REPLICATION_PASSWORD est absent ou vide." >&2
    exit 1
fi

if [[ "$REPLICATION_PASSWORD" == "changez_moi" ]]; then
    echo "ERREUR : mot de passe de réplication non configuré." >&2
    exit 1
fi

export REPLICATION_PASSWORD


CONFIG="/vagrant/config/noeuds.yml"

if [[ ! -f "$CONFIG" ]]; then
    echo "ERREUR : fichier $CONFIG introuvable." >&2
    exit 1
fi

RESEAU=$(awk -F: '/^reseau:/ {
    gsub(/[[:space:]]/, "", $2)
    print $2
    exit
}' "$CONFIG")

if [[ ! "$RESEAU" =~ ^192\.168\.[0-9]{1,3}$ ]]; then
    echo "ERREUR : réseau invalide dans $CONFIG." >&2
    exit 1
fi

PRIMARY_IP="${RESEAU}.32"
REPLICA_IP="${RESEAU}.31"
REPL_USER="replicateur"
PGPASSFILE="/var/lib/postgresql/.pgpass"

MARKER_FILE="/var/lib/postgresql/.resultats-bf-bdd1-reconstruit"
IN_PROGRESS_FILE="/var/lib/postgresql/.resultats-bf-bdd1-reconstruction-en-cours"

echo "=== Reconstruction de bdd1 ==="
echo "Nouveau serveur principal : $PRIMARY_IP"
echo "Serveur secondaire : $REPLICA_IP"

# ----------------------------------------------------------
# 2. Détection du cluster PostgreSQL
# ----------------------------------------------------------

if ! command -v pg_basebackup >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq postgresql
fi

CLUSTER_DIR=$(find /etc/postgresql \
    -mindepth 2 -maxdepth 2 \
    -type d -name main | sort -V | tail -n 1)

if [[ -z "$CLUSTER_DIR" ]]; then
    echo "ERREUR : cluster PostgreSQL introuvable." >&2
    exit 1
fi

PG_VERSION=$(basename "$(dirname "$CLUSTER_DIR")")
PG_CONF="$CLUSTER_DIR/postgresql.conf"
PGDATA="/var/lib/postgresql/$PG_VERSION/main"

echo "Version PostgreSQL : $PG_VERSION"

# ----------------------------------------------------------
# 3. Vérification du nouveau serveur principal
# ----------------------------------------------------------

escape_pgpass() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//:/\\:}"
    printf '%s' "$value"
}

PASSWORD_ESCAPED=$(escape_pgpass "$REPLICATION_PASSWORD")

install -d -o postgres -g postgres -m 700 /var/lib/postgresql

# Deux entrées : connexion SQL de contrôle et copie physique.
printf '%s:%s:%s:%s:%s\n' \
    "$PRIMARY_IP" "5432" "postgres" \
    "$REPL_USER" "$PASSWORD_ESCAPED" > "$PGPASSFILE"

printf '%s:%s:%s:%s:%s\n' \
    "$PRIMARY_IP" "5432" "replication" \
    "$REPL_USER" "$PASSWORD_ESCAPED" >> "$PGPASSFILE"
chown postgres:postgres "$PGPASSFILE"
chmod 600 "$PGPASSFILE"

echo "Vérification de bdd2..."

if ! pg_isready -h "$PRIMARY_IP" -p 5432 -q; then
    echo "ERREUR : bdd2 ne répond pas." >&2
    exit 1
fi

ETAT=$(runuser -u postgres -- env PGPASSFILE="$PGPASSFILE" \
    psql -X -v ON_ERROR_STOP=1 -h "$PRIMARY_IP" \
    -U "$REPL_USER" -d postgres -tA \
    -c "SELECT pg_is_in_recovery();")

if [[ "$ETAT" != "f" ]]; then
    echo "ERREUR : bdd2 n'est pas confirmé comme serveur principal." >&2
    echo "État obtenu : $ETAT" >&2
    exit 1
fi

echo "bdd2 est confirmé comme serveur principal."

# ----------------------------------------------------------
# 4. Arrêt et sauvegarde de l'ancien cluster bdd1

# Désactiver temporairement le démarrage automatique de PostgreSQL.
# L'ancien cluster ne doit jamais démarrer avant sa reconstruction.
echo "Désactivation du démarrage automatique de PostgreSQL..."
systemctl disable postgresql >/dev/null 2>&1 || true
systemctl mask postgresql
# ----------------------------------------------------------

BACKUP_PGDATA="${PGDATA}.pre-reconstruction-bdd2"

# Si la reconstruction a déjà réussi, vérifier l'état réel du réplica.
if [[ -f "$MARKER_FILE" ]]; then
    if [[ ! -s "$PGDATA/PG_VERSION" || ! -f "$PGDATA/standby.signal" ]]; then
        echo "ERREUR : marqueur présent mais réplica invalide." >&2
        exit 1
    fi

    if ! pg_ctlcluster "$PG_VERSION" main status >/dev/null 2>&1; then
        echo "ERREUR : le cluster PostgreSQL local est arrêté." >&2
        exit 1
    fi

    ETAT_LOCAL=$(runuser -u postgres -- psql -X -tA \
        -d postgres \
        -c "SELECT pg_is_in_recovery();" 2>/dev/null || true)

    if [[ "$ETAT_LOCAL" != "t" ]]; then
        echo "ERREUR : bdd1 n'est plus en mode secondaire." >&2
        exit 1
    fi

    REPLICATION_STATUS=$(runuser -u postgres -- psql -X -tA \
        -d postgres \
        -c "SELECT status || '|' || sender_host FROM pg_stat_wal_receiver LIMIT 1;" \
        2>/dev/null || true)

    if [[ "$REPLICATION_STATUS" != "streaming|$PRIMARY_IP" ]]; then
        echo "ERREUR : la réplication depuis bdd2 n'est pas active." >&2
        echo "État obtenu : ${REPLICATION_STATUS:-aucune connexion}" >&2
        exit 1
    fi

    echo "bdd1 est déjà reconstruit et sa réplication est active."
    exit 0
fi

# Arrêter le cluster local avant de remplacer ses données.
if pg_ctlcluster "$PG_VERSION" main status >/dev/null 2>&1; then
    echo "Arrêt du PostgreSQL local..."
    pg_ctlcluster "$PG_VERSION" main stop
fi

if [[ -f "$IN_PROGRESS_FILE" ]]; then
    if [[ ! -d "$BACKUP_PGDATA" ]]; then
        echo "ERREUR : reconstruction interrompue sans sauvegarde." >&2
        exit 1
    fi

    echo "Nettoyage d'une copie précédente interrompue."
    rm -rf -- "$PGDATA"
else
    if [[ -e "$BACKUP_PGDATA" ]]; then
        echo "ERREUR : une sauvegarde existe déjà :" >&2
        echo "$BACKUP_PGDATA" >&2
        echo "Vérification manuelle nécessaire." >&2
        exit 1
    fi

    if [[ -e "$PGDATA" ]]; then
        echo "Sauvegarde des anciennes données de bdd1..."
        mv -- "$PGDATA" "$BACKUP_PGDATA"
    fi
fi

# ----------------------------------------------------------
# 5. Copie physique depuis bdd2
# ----------------------------------------------------------

install -d -o postgres -g postgres -m 700 "$PGDATA"
touch "$IN_PROGRESS_FILE"
chmod 600 "$IN_PROGRESS_FILE"

echo "Copie physique depuis bdd2..."

runuser -u postgres -- env PGPASSFILE="$PGPASSFILE" \
    pg_basebackup \
    -h "$PRIMARY_IP" \
    -p 5432 \
    -U "$REPL_USER" \
    -D "$PGDATA" \
    -Fp \
    -Xs \
    -P \
    -R

# Définir explicitement le serveur principal suivi.
sed -i '/^[[:space:]]*primary_conninfo[[:space:]]*=/d' \
    "$PGDATA/postgresql.auto.conf"

cat >> "$PGDATA/postgresql.auto.conf" <<EOF

# RÉSULTATS-BF : bdd1 suit désormais bdd2
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=$REPL_USER passfile=$PGPASSFILE application_name=bdd1'
EOF

chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

# ----------------------------------------------------------
# 6. Configuration PostgreSQL du réplica
# ----------------------------------------------------------

install -d -m 755 "$CLUSTER_DIR/conf.d"

cat > "$CLUSTER_DIR/conf.d/resultats-bf.conf" <<EOF
# Configuration RÉSULTATS-BF : bdd1 en réplica
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
password_encryption = 'scram-sha-256'
EOF

if ! grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "$PG_CONF"; then
    echo "include_dir = 'conf.d'" >> "$PG_CONF"
fi

chown postgres:postgres "$PG_CONF"


# ----------------------------------------------------------
# 7. Démarrage et vérification
# ----------------------------------------------------------

systemctl unmask postgresql
systemctl enable postgresql >/dev/null
pg_ctlcluster "$PG_VERSION" main start

if ! pg_isready -q; then
    echo "ERREUR : PostgreSQL ne répond pas après reconstruction." >&2
    exit 1
fi

ETAT=$(runuser -u postgres -- psql -X -tA \
    -d postgres -c "SELECT pg_is_in_recovery();")

if [[ "$ETAT" != "t" ]]; then
    echo "ERREUR : bdd1 n'est pas en mode secondaire." >&2
    exit 1
fi

# Vérifier que bdd1 reçoit effectivement les WAL depuis bdd2.
echo "Vérification de la connexion de réplication..."

REPLICATION_STATUS=""

for tentative in {1..30}; do
    if REPLICATION_STATUS=$(runuser -u postgres -- psql -X -tA \
        -d postgres \
        -c "SELECT status || '|' || sender_host FROM pg_stat_wal_receiver LIMIT 1;" 2>/dev/null); then

        if [[ "$REPLICATION_STATUS" == "streaming|$PRIMARY_IP" ]]; then
            break
        fi
    fi

    sleep 1
done

if [[ "$REPLICATION_STATUS" != "streaming|$PRIMARY_IP" ]]; then
    echo "ERREUR : réplication non active depuis bdd2." >&2
    echo "Résultat obtenu : ${REPLICATION_STATUS:-aucune connexion}" >&2
    exit 1
fi

echo "Réplication active depuis $PRIMARY_IP."

# La reconstruction est validée uniquement après les contrôles.
touch "$MARKER_FILE"
chmod 600 "$MARKER_FILE"
rm -f "$IN_PROGRESS_FILE"

echo "=========================================="
echo "RECONSTRUCTION DE BDD1 REUSSIE"
echo "bdd2 : principal"
echo "bdd1 : secondaire"
echo "=========================================="
