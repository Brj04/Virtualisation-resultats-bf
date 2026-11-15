
#!/usr/bin/env bash
# RÉSULTATS-BF : promotion contrôlée de bdd2 en serveur principal.
# À exécuter uniquement après arrêt ou isolation de bdd1.

set -euo pipefail

echo "=== PROCÉDURE DE BASCULE POSTGRESQL ==="

# ----------------------------------------------------------
# 1. Vérification de l'opérateur
# ----------------------------------------------------------

if [[ "${1:-}" != "--confirm-bdd1-fenced" ]]; then
    echo "ERREUR : confirmation obligatoire." >&2
    echo "Après avoir arrêté ou isolé bdd1, exécutez :" >&2
    echo "sudo bash /vagrant/scripts/bascule.sh --confirm-bdd1-fenced" >&2
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : ce script doit être exécuté avec sudo." >&2
    exit 1
fi

# ----------------------------------------------------------
# 2. Vérification de l'identité de la machine
# ----------------------------------------------------------

HOTE=$(hostname -s)

if [[ "$HOTE" != "bdd2" ]]; then
    echo "ERREUR : ce script doit être exécuté sur bdd2." >&2
    echo "Machine actuelle : $HOTE" >&2
    exit 1
fi

echo "Machine confirmée : $HOTE"

# ----------------------------------------------------------
# 3. Lecture de la configuration réseau
# ----------------------------------------------------------

NOEUDS="/vagrant/config/noeuds.yml"

if [[ ! -s "$NOEUDS" ]]; then
    echo "ERREUR : fichier $NOEUDS absent ou vide." >&2
    exit 1
fi

RESEAU=$(awk '/^reseau:/ {print $2; exit}' "$NOEUDS")

if [[ -z "$RESEAU" ]]; then
    echo "ERREUR : réseau introuvable dans noeuds.yml." >&2
    exit 1
fi

PRIMARY_IP="${RESEAU}.31"
REPLICA_IP="${RESEAU}.32"

echo "Ancien principal : $PRIMARY_IP"
echo "Serveur à promouvoir : $REPLICA_IP"

# ----------------------------------------------------------
# 4. Vérification de l'isolation de bdd1
# ----------------------------------------------------------

echo "Vérification de l'ancien serveur principal..."

if pg_isready -q -h "$PRIMARY_IP" -p 5432 -t 2; then
    echo "ERREUR : bdd1 répond encore sur PostgreSQL." >&2
    echo "Arrêtez ou isolez bdd1 avant toute promotion." >&2
    exit 1
fi

echo "bdd1 ne répond pas sur le port PostgreSQL."

# ----------------------------------------------------------
# 5. Vérification de l'initialisation de bdd2
# ----------------------------------------------------------

MARKER_FILE="/var/lib/postgresql/.resultats-bf-replica-initialized"

if [[ ! -f "$MARKER_FILE" ]]; then
    echo "ERREUR : bdd2 ne possède pas le marqueur d'initialisation." >&2
    exit 1
fi

CLUSTER_DIR=$(find /etc/postgresql \
    -mindepth 2 -maxdepth 2 \
    -type d -name main | sort -V | tail -n 1)

if [[ -z "$CLUSTER_DIR" ]]; then
    echo "ERREUR : cluster PostgreSQL introuvable." >&2
    exit 1
fi

PG_VERSION=$(basename "$(dirname "$CLUSTER_DIR")")
PGDATA="/var/lib/postgresql/$PG_VERSION/main"

if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
    echo "ERREUR : répertoire de données PostgreSQL invalide." >&2
    exit 1
fi

# ----------------------------------------------------------
# 6. Vérification de PostgreSQL sur bdd2
# ----------------------------------------------------------

if ! pg_isready -q; then
    echo "ERREUR : PostgreSQL ne répond pas sur bdd2." >&2
    exit 1
fi

ETAT=$(runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -tA \
    -d postgres -c "SELECT pg_is_in_recovery();")

if [[ "$ETAT" == "f" ]]; then
    echo "bdd2 est déjà un serveur principal."
    echo "Aucune nouvelle promotion nécessaire."
    exit 0
fi

if [[ "$ETAT" != "t" ]]; then
    echo "ERREUR : état PostgreSQL inattendu : $ETAT" >&2
    exit 1
fi

if [[ ! -f "$PGDATA/standby.signal" ]]; then
    echo "ERREUR : standby.signal absent alors que le serveur est en recovery." >&2
    exit 1
fi

echo "bdd2 est bien un serveur secondaire."

# ----------------------------------------------------------
# 7. Vérification du rejeu des journaux WAL
# ----------------------------------------------------------

echo "Vérification de la synchronisation des journaux WAL..."

WAL_SYNCHRO=$(runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -tA \
    -d postgres \
    -c "SELECT CASE
            WHEN pg_last_wal_receive_lsn() IS NULL
              OR pg_last_wal_replay_lsn() IS NULL
            THEN 'unknown'
            WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn()
            THEN 'synced'
            ELSE 'pending'
         END;")

if [[ "$WAL_SYNCHRO" != "synced" ]]; then
    echo "ERREUR : les journaux WAL ne sont pas confirmés comme rejoués." >&2
    echo "État obtenu : $WAL_SYNCHRO" >&2
    echo "Promotion annulée par sécurité." >&2
    exit 1
fi

echo "Les journaux WAL reçus ont été rejoués."

# ----------------------------------------------------------
# 8. Promotion de bdd2
# ----------------------------------------------------------

echo "Promotion de bdd2 en serveur principal..."

pg_ctlcluster "$PG_VERSION" main promote

PROMU=0

for tentative in $(seq 1 30); do
    ETAT=$(runuser -u postgres -- psql -X -tA \
        -d postgres -c "SELECT pg_is_in_recovery();" 2>/dev/null || true)

    if [[ "$ETAT" == "f" ]]; then
        PROMU=1
        break
    fi

    sleep 1
done

if [[ "$PROMU" -ne 1 ]]; then
    echo "ERREUR : la promotion n'a pas été confirmée." >&2
    exit 1
fi

# ----------------------------------------------------------
# 9. Vérification finale
# ----------------------------------------------------------

if ! pg_isready -q; then
    echo "ERREUR : PostgreSQL ne répond plus après la promotion." >&2
    exit 1
fi

echo "=========================================="
echo "BASCULE REUSSIE"
echo "=========================================="
echo "bdd2 ($REPLICA_IP) est maintenant principal."
echo "Les nouvelles connexions applicatives peuvent utiliser bdd2."
echo "Vérifiez ensuite /sante et /resultat."
echo "=========================================="
