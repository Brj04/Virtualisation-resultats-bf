
#!/usr/bin/env bash
# RÉSULTATS-BF : configuration de bdd2 comme réplica PostgreSQL.
# Copie initiale avec pg_basebackup, puis réplication en continu.
# Le script protège les données d'un réplica déjà initialisé.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------
# 1. Paramètres et vérification des secrets
# ----------------------------------------------------------

: "${RESEAU:?RESEAU doit être fourni par Vagrant}"
: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD doit être défini}"

if [[ "$REPLICATION_PASSWORD" == "changez_moi" ]]; then
    echo "ERREUR : remplacez REPLICATION_PASSWORD dans .env." >&2
    exit 1
fi

PRIMARY_IP="${RESEAU}.31"
REPLICA_IP="${RESEAU}.32"
REPL_USER="replicateur"
PGPASSFILE="/var/lib/postgresql/.pgpass"
MARKER_FILE="/var/lib/postgresql/.resultats-bf-replica-initialized"

echo "=== Configuration du réplica bdd2 ==="
echo "Serveur principal : $PRIMARY_IP"
echo "Serveur secondaire : $REPLICA_IP"

# ----------------------------------------------------------
# 2. Installation de PostgreSQL
# ----------------------------------------------------------

if ! command -v pg_basebackup >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq postgresql
fi

# Détection du cluster PostgreSQL.
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
PGDATA="/var/lib/postgresql/$PG_VERSION/main"

echo "Version PostgreSQL détectée : $PG_VERSION"

# ----------------------------------------------------------
# 3. Préparation de l'authentification
# ----------------------------------------------------------

# Échappement des caractères spéciaux du format .pgpass.
escape_pgpass() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//:/\\:}"
    printf '%s' "$value"
}

PASSWORD_ESCAPED=$(escape_pgpass "$REPLICATION_PASSWORD")

install -d -o postgres -g postgres -m 700 /var/lib/postgresql

printf '%s:%s:%s:%s:%s\n' \
    "$PRIMARY_IP" "5432" "replication" \
    "$REPL_USER" "$PASSWORD_ESCAPED" > "$PGPASSFILE"

chown postgres:postgres "$PGPASSFILE"
chmod 600 "$PGPASSFILE"

# ----------------------------------------------------------
# 4. Configuration réseau du serveur secondaire
# ----------------------------------------------------------

install -d -m 755 "$CLUSTER_DIR/conf.d"

cat > "$CLUSTER_DIR/conf.d/resultats-bf.conf" <<EOF
# Configuration RÉSULTATS-BF pour bdd2
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
password_encryption = 'scram-sha-256'
EOF

# Autoriser l'application et préparer une éventuelle réplication
# inverse si bdd2 devient principal après une bascule.
MARKER_HBA="# REGLES RESULTATS-BF"

if ! grep -qF "$MARKER_HBA" "$PG_HBA"; then
    cat >> "$PG_HBA" <<EOF

$MARKER_HBA
host    resultatsbf    resultats_app    ${RESEAU}.0/24    scram-sha-256
host    replication   replicateur       ${PRIMARY_IP}/32  scram-sha-256
EOF
fi

if ! grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "$PG_CONF"; then
    echo "include_dir = 'conf.d'" >> "$PG_CONF"
fi

# ----------------------------------------------------------
# 5. Initialisation de la copie physique
# ----------------------------------------------------------


# Répertoires et marqueurs de sécurité.
BACKUP_PGDATA="${PGDATA}.pre-replication"
IN_PROGRESS_FILE="/var/lib/postgresql/.resultats-bf-replica-in-progress"

if [[ -f "$MARKER_FILE" ]]; then

    # Un réplica déjà initialisé ne doit jamais être écrasé.
    if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
        echo "ERREUR : marqueur présent mais données PostgreSQL absentes." >&2
        exit 1
    fi

    echo "Réplica déjà initialisé : conservation des données existantes."

else
    echo "Première initialisation : préparation de la copie physique."

    # Attendre que bdd1 accepte les connexions.
    PRET=0

    for tentative in $(seq 1 60); do
        if pg_isready -h "$PRIMARY_IP" -p 5432 -q; then
            PRET=1
            break
        fi

        echo "Attente de bdd1 ($tentative/60)..."
        sleep 2
    done

    if [[ "$PRET" -ne 1 ]]; then
        echo "ERREUR : bdd1 ne répond pas après 120 secondes." >&2
        exit 1
    fi

    # Arrêter le cluster local avant de préparer les données.
    pg_ctlcluster "$PG_VERSION" main stop || true

    if [[ -f "$IN_PROGRESS_FILE" ]]; then

        # Une copie interrompue peut être reprise uniquement
        # si l'ancien répertoire a bien été sauvegardé.
        if [[ ! -d "$BACKUP_PGDATA" ]]; then
            echo "ERREUR : copie interrompue, sauvegarde locale absente." >&2
            echo "Intervention manuelle nécessaire." >&2
            exit 1
        fi

        echo "Copie précédente interrompue : nettoyage du répertoire partiel."
        rm -rf -- "$PGDATA"

    else

        # Ne jamais écraser une sauvegarde précédente.
        if [[ -e "$BACKUP_PGDATA" ]]; then
            echo "ERREUR : une sauvegarde locale existe déjà :" >&2
            echo "$BACKUP_PGDATA" >&2
            echo "Vérification manuelle nécessaire avant de continuer." >&2
            exit 1
        fi

        # Préserver le cluster créé par défaut par le paquet PostgreSQL,
        # ou toute donnée préexistante, au lieu de la supprimer.
        if [[ -e "$PGDATA" ]]; then
            echo "Sauvegarde du répertoire PostgreSQL local."
            mv -- "$PGDATA" "$BACKUP_PGDATA"
        fi
    fi

    # Signaler qu'une copie est en cours.
    install -d -o postgres -g postgres -m 700 "$PGDATA"
    touch "$IN_PROGRESS_FILE"
    chmod 600 "$IN_PROGRESS_FILE"

    # Copie physique depuis bdd1.
    sudo -u postgres env PGPASSFILE="$PGPASSFILE" \
        pg_basebackup \
        -h "$PRIMARY_IP" \
        -p 5432 \
        -U "$REPL_USER" \
        -D "$PGDATA" \
        -Fp \
        -Xs \
        -P \
        -R

    # Définir explicitement le fichier d'authentification
    # utilisé lors des reconnexions au serveur principal.
    sed -i '/^[[:space:]]*primary_conninfo[[:space:]]*=/d' \
        "$PGDATA/postgresql.auto.conf"

    cat >> "$PGDATA/postgresql.auto.conf" <<EOF

# RÉSULTATS-BF : connexion au serveur principal
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=$REPL_USER passfile=$PGPASSFILE application_name=bdd2'
EOF

    chown -R postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"

    # Marquer la copie comme terminée, puis retirer le marqueur temporaire.
    touch "$MARKER_FILE"
    chmod 600 "$MARKER_FILE"
    rm -f "$IN_PROGRESS_FILE"

    echo "Copie physique terminée."
fi


# ----------------------------------------------------------
# 6. Démarrage et vérification
# ----------------------------------------------------------

systemctl enable postgresql >/dev/null

pg_ctlcluster "$PG_VERSION" main start

if ! pg_isready -q; then
    echo "ERREUR : PostgreSQL secondaire ne répond pas." >&2
    exit 1
fi

ETAT=$(sudo -u postgres psql -tA -c "SELECT pg_is_in_recovery();")

if [[ "$ETAT" == "t" ]]; then
    echo "État PostgreSQL : secondaire en mode recovery."
else
    echo "ATTENTION : le serveur n'est pas en mode standby."
    echo "Il a peut-être été promu principal lors d'une bascule."
fi

echo "=== Configuration de bdd2 terminée ==="
