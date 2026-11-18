
#!/usr/bin/env bash
# RÃ‰SULTATS-BF : V5 - VÃ©rification de la reconstruction de bdd1.
# La reconstruction de bdd1 doit Ãªtre rÃ©alisÃ©e manuellement au prÃ©alable.

set -euo pipefail

# ----------------------------------------------------------
# 1. VÃ©rification de l'environnement
# ----------------------------------------------------------

RACINE="/vagrant"
FICHIER_NOEUDS="$RACINE/config/noeuds.yml"
DOSSIER_RESULTATS="$RACINE/tests/resultats"

if [[ ! -s "$FICHIER_NOEUDS" ]]; then
    echo "ERREUR : fichier absent ou vide : $FICHIER_NOEUDS" >&2
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : exÃ©cuter ce script avec sudo." >&2
    exit 1
fi

if [[ "$(hostname -s)" != "bdd1" ]]; then
    echo "ERREUR : ce test doit Ãªtre exÃ©cutÃ© sur bdd1." >&2
    exit 1
fi

# ----------------------------------------------------------
# 2. Lecture de la configuration rÃ©seau
# ----------------------------------------------------------

RESEAU=$(awk -F': *' '
    /^reseau:/ {
        gsub(/[[:space:]]/, "", $2)
        print $2
        exit
    }
' "$FICHIER_NOEUDS")

if [[ ! "$RESEAU" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERREUR : rÃ©seau absent ou invalide dans noeuds.yml." >&2
    exit 1
fi

IP_BDD2="${RESEAU}.32"
IP_LB1="${RESEAU}.11"

URL="http://${IP_LB1}"
URL_SANTE="${URL}/sante"
URL_RESULTAT="${URL}/resultat?matricule=BF2026-000001"


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
    echo "ERREUR : APP_DB_PASSWORD absent ou non configurÃ© dans .env." >&2
    exit 1
fi

FICHIER_PGPASS_TEST="/tmp/v5_pgpass_$$"

NETTOYER_PGPASS() {
    rm -f "$FICHIER_PGPASS_TEST"
}

trap NETTOYER_PGPASS EXIT

APP_DB_PASSWORD_ESCAPED="${APP_DB_PASSWORD//\\/\\\\}"
APP_DB_PASSWORD_ESCAPED="${APP_DB_PASSWORD_ESCAPED//:/\\:}"

printf '%s:%s:%s:%s:%s\n' \
    "$IP_BDD2" "5432" "resultats" \
    "resultats_app" "$APP_DB_PASSWORD_ESCAPED" > "$FICHIER_PGPASS_TEST"

chmod 600 "$FICHIER_PGPASS_TEST"
unset APP_DB_PASSWORD APP_DB_PASSWORD_ESCAPED


# ----------------------------------------------------------
# 3. VÃ©rification des outils
# ----------------------------------------------------------

for outil in awk date curl python3 psql pg_isready pg_lsclusters runuser; do
    if ! command -v "$outil" >/dev/null 2>&1; then
        echo "ERREUR : outil requis absent : $outil" >&2
        exit 1
    fi
done


# ----------------------------------------------------------
# 4. Initialisation des preuves
# ----------------------------------------------------------

mkdir -p "$DOSSIER_RESULTATS"

FICHIER_PREUVE="$DOSSIER_RESULTATS/v5_reconstruction_$(date +%Y%m%d_%H%M%S).txt"

echo "=========================================="
echo "TEST V5 - RECONSTRUCTION DE BDD1"
echo "=========================================="
echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
echo "bdd1 : rÃ©plica attendu"
echo "bdd2 : principal attendu"

enregistrer_echec() {
    local message="$1"

    echo
    echo "RÃ‰SULTAT : Ã‰CHEC"
    echo "$message"

    {
        echo
        echo "===== Ã‰CHEC V5 ====="
        echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "$message"
    } | tee -a "$FICHIER_PREUVE"

    exit 1
}

# ----------------------------------------------------------
# 5. VÃ©rification de PostgreSQL sur bdd1
# ----------------------------------------------------------

VERSION=$(pg_lsclusters --no-header |
    awk '$2 == "main" { print $1; exit }')

if [[ -z "$VERSION" ]]; then
    enregistrer_echec "Aucun cluster PostgreSQL main dÃ©tectÃ© sur bdd1."
fi

if ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
    enregistrer_echec "PostgreSQL ne rÃ©pond pas sur bdd1."
fi

if ! ETAT_LOCAL=$(runuser -u postgres -- \
    psql -X -A -t -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "SELECT pg_is_in_recovery();" |
    tr -d '[:space:]'); then
    enregistrer_echec "Impossible de vÃ©rifier l'Ã©tat PostgreSQL de bdd1."
fi

if [[ "$ETAT_LOCAL" != "t" ]]; then
    enregistrer_echec "bdd1 n'est pas en mode rÃ©plica (pg_is_in_recovery() diffÃ©rent de true)."
fi

echo
echo "PostgreSQL bdd1 : opÃ©rationnel"
echo "Mode rÃ©plica : confirmÃ©"

# ----------------------------------------------------------
# 6. VÃ©rification de bdd2 comme serveur principal
# ----------------------------------------------------------


if ! ETAT_BDD2=$(PGPASSFILE="$FICHIER_PGPASS_TEST" \
    psql -X -A -t \
    -h "$IP_BDD2" \
    -p 5432 \
    -U resultats_app \
    -d resultats \
    -v ON_ERROR_STOP=1 \
    -c "SELECT pg_is_in_recovery();" |
    tr -d '[:space:]'); then
    enregistrer_echec "Impossible de vÃ©rifier l'Ã©tat PostgreSQL de bdd2."
fi


if [[ "$ETAT_BDD2" != "f" ]]; then
    enregistrer_echec "bdd2 n'est pas confirmÃ© comme serveur principal."
fi

echo "PostgreSQL bdd2 : serveur principal confirmÃ©"

# ----------------------------------------------------------
# 7. VÃ©rification de la rÃ©plication inverse
# ----------------------------------------------------------

if ! ETAT_RECEPTEUR=$(runuser -u postgres -- \
    psql -X -A -t -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "
        SELECT status || '|' || COALESCE(sender_host, '')
        FROM pg_stat_wal_receiver
        LIMIT 1;
    " |
    tr -d '\r'); then
    enregistrer_echec "Impossible de vÃ©rifier le rÃ©cepteur WAL sur bdd1."
fi

if [[ -z "$ETAT_RECEPTEUR" ]]; then
    enregistrer_echec "Aucun rÃ©cepteur WAL actif sur bdd1."
fi

STATUT_RECEPTEUR="${ETAT_RECEPTEUR%%|*}"
IP_EMETTEUR="${ETAT_RECEPTEUR#*|}"

echo "Ã‰tat du rÃ©cepteur WAL : $STATUT_RECEPTEUR"
echo "Serveur source WAL : $IP_EMETTEUR"

if [[ "$STATUT_RECEPTEUR" != "streaming" ]]; then
    enregistrer_echec "La rÃ©plication WAL n'est pas en Ã©tat streaming."
fi

if [[ "$IP_EMETTEUR" != "$IP_BDD2" ]]; then
    enregistrer_echec "Le rÃ©cepteur WAL ne reÃ§oit pas depuis bdd2 ($IP_BDD2)."
fi

# ----------------------------------------------------------
# 8. Fonctions de vÃ©rification HTTP et JSON
# ----------------------------------------------------------

obtenir_code_http() {
    local adresse="$1"
    local code

    if code=$(curl -sS -o /dev/null \
        --connect-timeout 3 \
        --max-time 8 \
        -w '%{http_code}' \
        "$adresse"); then
        printf '%s' "$code"
    else
        printf '000'
    fi
}

obtenir_corps_resultat() {
    curl -fsS \
        --connect-timeout 3 \
        --max-time 8 \
        "$URL_RESULTAT"
}

verifier_resultat() {
    local contenu="$1"

    printf '%s' "$contenu" | python3 -c '
import json
import sys

try:
    resultat = json.load(sys.stdin)

    attendu = {
        "matricule": "BF2026-000001",
        "nom": "Candidat 00001",
        "serie": "C",
        "moyenne": 0.37,
        "admis": False
    }

    for cle, valeur in attendu.items():
        obtenu = resultat.get(cle)

        if type(obtenu) is not type(valeur) or obtenu != valeur:
            print(
                f"ERREUR : {cle} attendu={valeur}, "
                f"obtenu={obtenu}"
            )
            sys.exit(1)

    print("Contenu JSON : candidat et rÃ©sultat conformes.")
    sys.exit(0)

except (json.JSONDecodeError, AttributeError) as erreur:
    print(f"ERREUR : rÃ©ponse JSON invalide : {erreur}")
    sys.exit(1)
'
}

# ----------------------------------------------------------
# 9. VÃ©rification du service applicatif
# ----------------------------------------------------------

CODE_SANTE=$(obtenir_code_http "$URL_SANTE")
CODE_RESULTAT=$(obtenir_code_http "$URL_RESULTAT")

echo
echo "/sante : HTTP $CODE_SANTE"
echo "/resultat : HTTP $CODE_RESULTAT"

if [[ "$CODE_SANTE" != "200" ]]; then
    enregistrer_echec "Le service applicatif n'est pas opÃ©rationnel."
fi

if [[ "$CODE_RESULTAT" != "200" ]]; then
    enregistrer_echec "La recherche de rÃ©sultat Ã©choue."
fi

if ! CORPS_RESULTAT=$(obtenir_corps_resultat); then
    enregistrer_echec "Impossible de rÃ©cupÃ©rer le rÃ©sultat JSON."
fi

if ! verifier_resultat "$CORPS_RESULTAT"; then
    enregistrer_echec "Le contenu JSON du candidat est incorrect."
fi

# ----------------------------------------------------------
# 10. Enregistrement des preuves
# ----------------------------------------------------------

{
    echo
    echo "===== TEST V5 - RECONSTRUCTION ====="
    echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Situation : bdd1 reconstruite depuis bdd2"
    echo "bdd1 : rÃ©plica confirmÃ©"
    echo "bdd2 : principal confirmÃ©"
    echo "RÃ©cepteur WAL : $STATUT_RECEPTEUR"
    echo "Source WAL : $IP_EMETTEUR"
    echo "/sante : HTTP $CODE_SANTE"
    echo "/resultat : HTTP $CODE_RESULTAT"
    echo "VÃ©rification JSON : conforme"
    echo "RÃ‰SULTAT : SUCCÃˆS"
} | tee -a "$FICHIER_PREUVE"

echo
echo "RÃ‰SULTAT : SUCCÃˆS"
echo "bdd1 est de nouveau un rÃ©plica de bdd2."
