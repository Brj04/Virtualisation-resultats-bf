#!/usr/bin/env bash
# RÉSULTATS-BF : V2 - Vérification de la tolérance à une panne applicative.
# À exécuter depuis WSL après l'arrêt manuel d'un serveur app.

set -euo pipefail

# ----------------------------------------------------------
# 1. Détection des fichiers
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
# 2. Serveur à considérer comme en panne
# ----------------------------------------------------------

SERVEUR_EN_PANNE="${1:-app1}"

# ----------------------------------------------------------
# 3. Lecture du port hôte
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
    echo "ERREUR : PORT_HOTE absent ou invalide." >&2
    exit 1
fi

HOTE_TEST="${HOTE_TEST:-127.0.0.1}"
PORT_TEST="${PORT_TEST:-$PORT_HOTE}"
URL="http://${HOTE_TEST}:${PORT_TEST}"
# ----------------------------------------------------------
# 4. Détection des serveurs applicatifs
# ----------------------------------------------------------

mapfile -t SERVEURS_ATTENDUS < <(
    grep -B 3 'role: app' "$FICHIER_NOEUDS" |
    grep 'nom:' |
    sed -E 's/.*nom:[[:space:]]*//; s/\r$//'
)
SERVEUR_PRESENT=0
SERVEURS_RESTANTS=()

for serveur in "${SERVEURS_ATTENDUS[@]}"; do
    if [[ "$serveur" == "$SERVEUR_EN_PANNE" ]]; then
        SERVEUR_PRESENT=1
    else
        SERVEURS_RESTANTS+=("$serveur")
    fi
done

if [[ "$SERVEUR_PRESENT" -ne 1 ]]; then
    echo "ERREUR : $SERVEUR_EN_PANNE n'est pas déclaré comme serveur app." >&2
    exit 1
fi

if [[ "${#SERVEURS_RESTANTS[@]}" -lt 1 ]]; then
    echo "ERREUR : aucun serveur applicatif restant." >&2
    exit 1
fi

# ----------------------------------------------------------
# 5. Initialisation
# ----------------------------------------------------------

declare -A COMPTEURS

for serveur in "${SERVEURS_RESTANTS[@]}"; do
    COMPTEURS["$serveur"]=0
done

NB_REQUETES=20

echo "=========================================="
echo "TEST V2 - PANNE D'UN SERVEUR APPLICATIF"
echo "=========================================="
echo "Serveur supposé en panne : $SERVEUR_EN_PANNE"
echo "Serveurs restants : ${SERVEURS_RESTANTS[*]}"
echo "URL testée : $URL"

echo
echo "Attente de 8 secondes pour la détection HAProxy..."
sleep 8

# Détection de Python sous Windows et Linux
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v py >/dev/null 2>&1; then
    PYTHON_CMD="py -3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    echo "ERREUR : Python est introuvable." >&2
    exit 1
fi

# ----------------------------------------------------------
# 6. Envoi des requêtes
# ----------------------------------------------------------

echo
echo "Envoi de $NB_REQUETES requêtes..."

for ((i = 1; i <= NB_REQUETES; i++)); do

    REPONSE_ET_CODE=$(curl -fsS --max-time 5 -w $'\n%{http_code}' "$URL/info") || {
    echo "ECHEC : le service ne répond plus à la requête $i." >&2
    exit 1
}

CODE_HTTP="${REPONSE_ET_CODE##*$'\n'}"
REPONSE="${REPONSE_ET_CODE%$'\n'*}"

if [[ "$CODE_HTTP" != "200" ]]; then
    echo "ECHEC : code HTTP inattendu : $CODE_HTTP" >&2
    exit 1
fi

    SERVEUR=$($PYTHON_CMD -c '
import json
import sys
try:
    print(json.load(sys.stdin)["hote"])
except (ValueError, KeyError, TypeError):
    sys.exit(1)
' <<< "$REPONSE") || {
        echo "ECHEC : réponse /info invalide." >&2
        exit 1
    }

    if [[ "$SERVEUR" == "$SERVEUR_EN_PANNE" ]]; then
        echo "ECHEC : HAProxy envoie encore des requêtes vers $SERVEUR." >&2
        exit 1
    fi

    if [[ -z "${COMPTEURS[$SERVEUR]+present}" ]]; then
        echo "ECHEC : serveur inattendu : $SERVEUR" >&2
        exit 1
    fi

    COMPTEURS["$SERVEUR"]=$((COMPTEURS["$SERVEUR"] + 1))
    echo "Requête $i : HTTP 200 depuis $SERVEUR"
done

# ----------------------------------------------------------
# 7. Vérification finale
# ----------------------------------------------------------

ECHEC=0

echo
echo "===== RÉSULTATS ====="

for serveur in "${SERVEURS_RESTANTS[@]}"; do
    nombre=${COMPTEURS[$serveur]}
    echo "$serveur : $nombre réponse(s)"

    if [[ "$nombre" -eq 0 ]]; then
        echo "ECHEC : aucun trafic reçu par $serveur."
        ECHEC=1
    fi
done

# ----------------------------------------------------------
# 8. Conservation de la preuve
# ----------------------------------------------------------

mkdir -p "$DOSSIER_RESULTATS"

{
    echo "TEST V2 - PANNE D'UN SERVEUR APPLICATIF"
    echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Serveur en panne : $SERVEUR_EN_PANNE"
    echo "URL : $URL"
    echo "Nombre de requêtes : $NB_REQUETES"
    echo

    for serveur in "${SERVEURS_RESTANTS[@]}"; do
        echo "$serveur : ${COMPTEURS[$serveur]} réponse(s)"
    done
} | tee "$DOSSIER_RESULTATS/v2_panne_app_$(date +%Y%m%d_%H%M%S).txt"

if [[ "$ECHEC" -ne 0 ]]; then
    echo
    echo "RÉSULTAT : ÉCHEC"
    exit 1
fi

echo
echo "RÉSULTAT : SUCCÈS"
echo "Le service reste accessible malgré la panne de $SERVEUR_EN_PANNE."
