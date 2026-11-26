#!/usr/bin/env bash
# RESULTATS-BF - V5 : verification de la reconstruction de l'infrastructure.
# A executer avec sudo sur bdd1 apres une reconstruction complete.

set -euo pipefail

RACINE="/vagrant"
FICHIER_NOEUDS="$RACINE/config/noeuds.yml"
DOSSIER_RESULTATS="$RACINE/tests/resultats"

if [[ ! -s "$FICHIER_NOEUDS" ]]; then
    echo "ERREUR : config/noeuds.yml absent ou vide." >&2
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : executer ce script avec sudo." >&2
    exit 1
fi

if [[ "$(hostname -s)" != "bdd1" ]]; then
    echo "ERREUR : ce test doit etre execute sur bdd1." >&2
    exit 1
fi

RESEAU=$(awk -F': *' '/^reseau:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$FICHIER_NOEUDS")

if [[ ! "$RESEAU" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERREUR : reseau invalide dans noeuds.yml." >&2
    exit 1
fi

IP_BDD1="${RESEAU}.31"
IP_BDD2="${RESEAU}.32"
VIP="${RESEAU}.5"
URL="http://${VIP}"
URL_SANTE="${URL}/sante"
URL_RESULTAT="${URL}/resultat?matricule=BF000001"

FICHIER_ENV="$RACINE/.env"
if [[ ! -s "$FICHIER_ENV" ]]; then
    echo "ERREUR : fichier .env absent ou vide." >&2
    exit 1
fi

APP_DB_PASSWORD=$(awk -F= '
    /^[[:space:]]*APP_DB_PASSWORD[[:space:]]*=/ {
        sub(/^[^=]*=/, "")
        sub(/[[:space:]]+#.*/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/^["\047]|["\047]$/, "")
        print
        exit
    }
' "$FICHIER_ENV")

if [[ -z "$APP_DB_PASSWORD" || "$APP_DB_PASSWORD" == "changez_moi" ]]; then
    echo "ERREUR : APP_DB_PASSWORD absent ou non configure." >&2
    exit 1
fi

for outil in awk date curl python3 psql pg_isready runuser; do
    command -v "$outil" >/dev/null 2>&1 || {
        echo "ERREUR : outil requis absent : $outil" >&2
        exit 1
    }
done

mkdir -p "$DOSSIER_RESULTATS"
FICHIER_PREUVE="$DOSSIER_RESULTATS/v5_reconstruction_$(date +%Y%m%d_%H%M%S).txt"

FICHIER_PGPASS="/tmp/v5_pgpass_$$"
APP_DB_PASSWORD_ESCAPED="${APP_DB_PASSWORD//\\/\\\\}"
APP_DB_PASSWORD_ESCAPED="${APP_DB_PASSWORD_ESCAPED//:/\\:}"

printf '%s:%s:%s:%s:%s\n' \
    "$IP_BDD2" "5432" "resultats" \
    "resultats_app" "$APP_DB_PASSWORD_ESCAPED" > "$FICHIER_PGPASS"

chmod 600 "$FICHIER_PGPASS"
unset APP_DB_PASSWORD APP_DB_PASSWORD_ESCAPED
trap 'rm -f "$FICHIER_PGPASS"' EXIT

exec > >(tee -a "$FICHIER_PREUVE") 2>&1

echec() {
    echo
    echo "RESULTAT : ECHEC"
    echo "Motif : $1"
    exit 1
}

echo "=========================================="
echo "TEST V5 - RECONSTRUCTION DE L'INFRASTRUCTURE"
echo "=========================================="
echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
echo "bdd1 attendu : principal ($IP_BDD1)"
echo "bdd2 attendu : replica ($IP_BDD2)"
echo "VIP : $VIP"

# 1. PostgreSQL sur bdd1
if ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
    echec "PostgreSQL ne repond pas sur bdd1."
fi

ETAT_BDD1=$(runuser -u postgres -- psql -X -A -t -d postgres \
    -v ON_ERROR_STOP=1 -c "SELECT pg_is_in_recovery();" |
    tr -d '[:space:]') || echec "Impossible de verifier bdd1."

if [[ "$ETAT_BDD1" != "f" ]]; then
    echec "bdd1 n'est pas le serveur principal."
fi

echo "OK : bdd1 est operationnelle et principale."

# 2. PostgreSQL sur bdd2
if ! pg_isready -h "$IP_BDD2" -p 5432 -U resultats_app -d resultats >/dev/null 2>&1; then
    echec "PostgreSQL ne repond pas sur bdd2."
fi

ETAT_BDD2=$(PGPASSFILE="$FICHIER_PGPASS" psql -X -A -t \
    -h "$IP_BDD2" -p 5432 -U resultats_app -d resultats \
    -v ON_ERROR_STOP=1 -c "SELECT pg_is_in_recovery();" |
    tr -d '[:space:]') || echec "Impossible de verifier bdd2."

if [[ "$ETAT_BDD2" != "t" ]]; then
    echec "bdd2 n'est pas en mode replica."
fi

echo "OK : bdd2 est operationnelle et en mode replica."

# 3. Replication entre bdd1 et bdd2
ETAT_STREAMING=$(runuser -u postgres -- psql -X -A -t -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "SELECT COALESCE((SELECT state FROM pg_stat_replication WHERE client_addr = '${IP_BDD2}'::inet LIMIT 1), '');" |
    tr -d '[:space:]') || echec "Impossible de verifier pg_stat_replication."

if [[ "$ETAT_STREAMING" != "streaming" ]]; then
    echec "La replication vers bdd2 n'est pas en streaming."
fi

echo "OK : replication active de bdd1 vers bdd2 (verification pg_stat_replication)." 

# 4. Services HTTP via l'adresse virtuelle
obtenir_code_http() {
    curl -sS -o /dev/null --connect-timeout 3 --max-time 8 \
        -w '%{http_code}' "$1" || echo "000"
}

CODE_SANTE=$(obtenir_code_http "$URL_SANTE")
CODE_RESULTAT=$(obtenir_code_http "$URL_RESULTAT")

echo "/sante : HTTP $CODE_SANTE"
echo "/resultat : HTTP $CODE_RESULTAT"

[[ "$CODE_SANTE" == "200" ]] || echec "Le endpoint /sante ne repond pas en HTTP 200."
[[ "$CODE_RESULTAT" == "200" ]] || echec "Le endpoint /resultat ne repond pas en HTTP 200."

CORPS=$(curl -fsS --connect-timeout 3 --max-time 8 "$URL_RESULTAT") ||
    echec "Impossible de recuperer le resultat JSON."

printf '%s' "$CORPS" | python3 -c '
import json
import sys

try:
    resultat = json.load(sys.stdin)
    attendu = {
        "matricule": "BF000001",
        "nom": "CANDIDAT_1",
        "serie": "C",
        "moyenne": 9.14,
        "admis": False
    }

    for cle, valeur in attendu.items():
        obtenu = resultat.get(cle)
        if type(obtenu) is not type(valeur) or obtenu != valeur:
            print(f"ERREUR : {cle} attendu={valeur}, obtenu={obtenu}")
            sys.exit(1)

    print("OK : donnees JSON conformes.")
except (json.JSONDecodeError, AttributeError) as erreur:
    print(f"ERREUR : JSON invalide : {erreur}")
    sys.exit(1)
' || echec "Le contenu JSON du candidat est incorrect."

echo
echo "===== BILAN V5 ====="
echo "bdd1 : principal confirme"
echo "bdd2 : replica confirme"
echo "Replication : streaming"
echo "Destination WAL : $IP_BDD2"
echo "/sante : HTTP $CODE_SANTE"
echo "/resultat : HTTP $CODE_RESULTAT"
echo "Donnees du candidat : conformes"
echo "RESULTAT : SUCCES"
echo "Preuve : $FICHIER_PREUVE"
