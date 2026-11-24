#!/usr/bin/env bash
# RÉSULTATS-BF : V1 - Vérification de la répartition HAProxy.
# À exécuter depuis WSL, dans le dépôt du projet.

set -euo pipefail

# ----------------------------------------------------------
# 1. Détection des fichiers de configuration
# ----------------------------------------------------------

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FICHIER_ENV="$RACINE/.env"
FICHIER_NOEUDS="$RACINE/config/noeuds.yml"
DOSSIER_RESULTATS="$RACINE/tests/resultats"

for fichier in "$FICHIER_ENV" "$FICHIER_NOEUDS"; do
    if [[ ! -s "$fichier" ]]; then
        echo "ERREUR : fichier absent ou vide : $fichier" >&2
        exit 1
    fi
done

# ----------------------------------------------------------
# 2. Lecture du port exposé par Vagrant
# ----------------------------------------------------------

PORT_HOTE=$(awk -F= '
    /^PORT_HOTE=/ {
        sub(/[[:space:]]*#.*/, "", $2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
    }
' "$FICHIER_ENV")

if [[ ! "$PORT_HOTE" =~ ^[0-9]+$ ]]; then
    echo "ERREUR : PORT_HOTE absent ou invalide dans .env." >&2
    exit 1
fi
HOTE_TEST="${HOTE_TEST:-127.0.0.1}"
PORT_TEST="${PORT_TEST:-$PORT_HOTE}"
URL="http://${HOTE_TEST}:${PORT_TEST}"

# ----------------------------------------------------------
# 3. Détection des serveurs applicatifs
# ----------------------------------------------------------

mapfile -t SERVEURS_ATTENDUS < <(
    grep -B 3 'role: app' "$FICHIER_NOEUDS" |
    grep 'nom:' |
    sed -E 's/.*nom:[[:space:]]*//; s/\r$//'
)

if [[ "${#SERVEURS_ATTENDUS[@]}" -lt 2 ]]; then
    echo "ERREUR : au moins deux serveurs app sont nécessaires." >&2
    exit 1
fi

echo "=========================================="
echo "TEST V1 - REPARTITION HAProxy"
echo "=========================================="
echo "URL testée : $URL"
echo "Serveurs attendus : ${SERVEURS_ATTENDUS[*]}"

# ----------------------------------------------------------
# 4. Préparation des compteurs
# ----------------------------------------------------------

declare -A COMPTEURS

for serveur in "${SERVEURS_ATTENDUS[@]}"; do
    COMPTEURS["$serveur"]=0
done

NB_REQUETES=20
FICHIER_PREUVE=$(mktemp)
trap 'rm -f "$FICHIER_PREUVE"' EXIT

# ----------------------------------------------------------
# 5. Envoi des requêtes
# ----------------------------------------------------------

echo
echo "Envoi de $NB_REQUETES requêtes..."

for ((i = 1; i <= NB_REQUETES; i++)); do
    REPONSE=$(curl -fsS --max-time 5 "$URL/info") || {
        echo "ECHEC : requête $i impossible." >&2
        exit 1
    }

    SERVEUR=$(python3 -c '
import json
import sys
try:
    print(json.load(sys.stdin)["serveur"])
except (ValueError, KeyError, TypeError):
    sys.exit(1)
' <<< "$REPONSE") || {
        echo "ECHEC : réponse /info invalide : $REPONSE" >&2
        exit 1
    }

    if [[ -z "${COMPTEURS[$SERVEUR]+present}" ]]; then
        echo "ECHEC : serveur inattendu : $SERVEUR" >&2
        exit 1
    fi

    COMPTEURS["$SERVEUR"]=$((COMPTEURS["$SERVEUR"] + 1))
    echo "Requête $i : $SERVEUR"
done

# ----------------------------------------------------------
# 6. Vérification de la répartition
# ----------------------------------------------------------

echo
echo "===== RESULTATS ====="

ECHEC=0

for serveur in "${SERVEURS_ATTENDUS[@]}"; do
    nombre=${COMPTEURS[$serveur]}
    echo "$serveur : $nombre réponse(s)"

    if [[ "$nombre" -eq 0 ]]; then
        echo "ECHEC : $serveur n'a reçu aucune requête."
        ECHEC=1
    fi
done

# ----------------------------------------------------------
# 7. Conservation de la preuve
# ----------------------------------------------------------

mkdir -p "$DOSSIER_RESULTATS"

{
    echo "TEST V1 - REPARTITION HAProxy"
    echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "URL : $URL"
    echo "Nombre de requêtes : $NB_REQUETES"
    echo

    for serveur in "${SERVEURS_ATTENDUS[@]}"; do
        echo "$serveur : ${COMPTEURS[$serveur]} réponse(s)"
    done
} | tee "$DOSSIER_RESULTATS/v1_repartition_$(date +%Y%m%d_%H%M%S).txt"

if [[ "$ECHEC" -ne 0 ]]; then
    echo
    echo "RESULTAT : ECHEC"
    exit 1
fi

echo
echo "RESULTAT : SUCCES"
echo "La répartition entre les serveurs applicatifs est vérifiée."
