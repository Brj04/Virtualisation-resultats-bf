
#!/usr/bin/env bash
# RÉSULTATS-BF : V3 - Test de charge HTTP.
# À exécuter depuis WSL lorsque les VM et services sont opérationnels.

set -uo pipefail

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
# 2. Lecture de la configuration
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

URL="http://127.0.0.1:${PORT_HOTE}/info"

# ----------------------------------------------------------
# 3. Paramètres du test
# ----------------------------------------------------------

NB_REQUETES="${NB_REQUETES:-100}"
DELAI_MAX="${DELAI_MAX:-10}"

if [[ ! "$NB_REQUETES" =~ ^[0-9]+$ ]] || (( NB_REQUETES < 1 || NB_REQUETES > 10000 )); then
    echo "ERREUR : NB_REQUETES doit être compris entre 1 et 10000." >&2
    exit 1
fi

if [[ ! "$DELAI_MAX" =~ ^[0-9]+$ ]] || (( DELAI_MAX < 1 || DELAI_MAX > 120 )); then
    echo "ERREUR : DELAI_MAX doit être compris entre 1 et 120 secondes." >&2
    exit 1
fi

# ----------------------------------------------------------
# 4. Initialisation des mesures
# ----------------------------------------------------------

SUCCES=0
ECHECS=0
SOMME=0
MIN=999999999
MAX=0

declare -A COMPTEURS_SERVEURS

echo "=========================================="
echo "TEST V3 - TEST DE CHARGE"
echo "=========================================="
echo "URL : $URL"
echo "Nombre de requêtes : $NB_REQUETES"
echo "Délai maximal : ${DELAI_MAX}s"
echo

# Vérification préalable : cette requête n'est pas comptabilisée.
if ! curl -fsS --max-time "$DELAI_MAX" "$URL" >/dev/null; then
    echo "ERREUR : le service n'est pas accessible." >&2
    exit 1
fi

DEBUT=$(date +%s%N)

# ----------------------------------------------------------
# 5. Exécution des requêtes
# ----------------------------------------------------------

for ((i = 1; i <= NB_REQUETES; i++)); do

    # Une seule requête récupère le corps JSON et les mesures curl.
    if REPONSE_ET_MESURE=$(curl -sS --max-time "$DELAI_MAX" \
        -w $'\n__CURL_METRICS__%{http_code} %{time_total}' \
        "$URL" 2>/dev/null); then

        MARQUEUR=$'\n__CURL_METRICS__'
        METRIQUES="${REPONSE_ET_MESURE##*"$MARQUEUR"}"
        REPONSE="${REPONSE_ET_MESURE%"$MARQUEUR"*}"

        CODE_HTTP="${METRIQUES%% *}"
        TEMPS="${METRIQUES#* }"

    else
        CODE_HTTP="000"
        TEMPS="0"
        REPONSE=""
    fi

    # Vérification du code HTTP.
    if [[ "$CODE_HTTP" != "200" ]]; then
        ((ECHECS+=1))
        echo "Requête $i : ÉCHEC (HTTP $CODE_HTTP)"
        continue
    fi

    # Extraction du nom du serveur depuis le JSON déjà reçu.
    SERVEUR=$(printf '%s' "$REPONSE" | python3 -c '
import json
import sys

try:
    donnees = json.load(sys.stdin)
    serveur = donnees["hote"]
    if not isinstance(serveur, str) or not serveur.strip():
        raise ValueError("Nom de serveur invalide")
    print(serveur)
except Exception:
    sys.exit(1)
' 2>/dev/null) || SERVEUR=""

    if [[ -z "$SERVEUR" ]]; then
        ((ECHECS+=1))
        echo "Requête $i : ÉCHEC (JSON invalide ou serveur absent)"
        continue
    fi

    # La requête est considérée comme réussie.
    ((SUCCES+=1))

    TEMPS_US=$(awk -v t="$TEMPS" 'BEGIN {printf "%.0f", t * 1000000}')
    ((SOMME+=TEMPS_US))

    if (( TEMPS_US < MIN )); then
        MIN=$TEMPS_US
    fi

    if (( TEMPS_US > MAX )); then
        MAX=$TEMPS_US
    fi

    COMPTEURS_SERVEURS["$SERVEUR"]=$(( ${COMPTEURS_SERVEURS["$SERVEUR"]:-0} + 1 ))

    echo "Requête $i : HTTP 200 - ${TEMPS}s - $SERVEUR"
done

FIN=$(date +%s%N)

# ----------------------------------------------------------
# 6. Calcul des statistiques
# ----------------------------------------------------------

DUREE_MS=$(( (FIN - DEBUT) / 1000000 ))

if (( SUCCES > 0 )); then
    MOYENNE_US=$(( SOMME / SUCCES ))
    MOYENNE=$(awk -v t="$MOYENNE_US" 'BEGIN {printf "%.3f", t / 1000000}')
    TEMPS_MIN=$(awk -v t="$MIN" 'BEGIN {printf "%.3f", t / 1000000}')
    TEMPS_MAX=$(awk -v t="$MAX" 'BEGIN {printf "%.3f", t / 1000000}')
else
    MOYENNE="N/A"
    TEMPS_MIN="N/A"
    TEMPS_MAX="N/A"
fi

# Débit des requêtes réussies par seconde.
if (( DUREE_MS > 0 )); then
    DEBIT=$(awk -v n="$SUCCES" -v d="$DUREE_MS" \
        'BEGIN {printf "%.2f", n * 1000 / d}')
else
    DEBIT="N/A"
fi

# ----------------------------------------------------------
# 7. Affichage des résultats
# ----------------------------------------------------------

echo
echo "=========================================="
echo "RÉSULTATS DU TEST V3"
echo "=========================================="
echo "Requêtes prévues        : $NB_REQUETES"
echo "Requêtes réussies       : $SUCCES"
echo "Requêtes échouées       : $ECHECS"
echo "Temps moyen (secondes)  : $MOYENNE"
echo "Temps minimum (secondes): $TEMPS_MIN"
echo "Temps maximum (secondes): $TEMPS_MAX"
echo "Durée totale (secondes) : $(awk -v d="$DUREE_MS" 'BEGIN {printf "%.3f", d/1000}')"
echo "Débit (requêtes/s)      : $DEBIT"

echo
echo "Répartition observée :"

for serveur in "${!COMPTEURS_SERVEURS[@]}"; do
    echo "$serveur : ${COMPTEURS_SERVEURS[$serveur]} réponse(s)"
done

# ----------------------------------------------------------
# 8. Conservation de la preuve
# ----------------------------------------------------------

mkdir -p "$DOSSIER_RESULTATS"

{
    echo "TEST V3 - TEST DE CHARGE"
    echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "URL : $URL"
    echo "Requêtes prévues : $NB_REQUETES"
    echo "Requêtes réussies : $SUCCES"
    echo "Requêtes échouées : $ECHECS"
    echo "Temps moyen (s) : $MOYENNE"
    echo "Temps minimum (s) : $TEMPS_MIN"
    echo "Temps maximum (s) : $TEMPS_MAX"
    echo "Durée totale (ms) : $DUREE_MS"
    echo "Débit des succès (req/s) : $DEBIT"
    echo
    echo "Répartition par serveur :"

    for serveur in "${!COMPTEURS_SERVEURS[@]}"; do
        echo "$serveur : ${COMPTEURS_SERVEURS[$serveur]} réponse(s)"
    done
} | tee "$DOSSIER_RESULTATS/v3_charge_$(date +%Y%m%d_%H%M%S).txt"

# ----------------------------------------------------------
# 9. Verdict
# ----------------------------------------------------------

if (( ECHECS > 0 )); then
    echo
    echo "RÉSULTAT : ÉCHEC - au moins une requête a échoué."
    exit 1
fi

echo
echo "RÉSULTAT : SUCCÈS - toutes les requêtes ont répondu HTTP 200."
