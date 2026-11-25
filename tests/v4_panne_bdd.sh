
#!/usr/bin/env bash
# RÉSULTATS-BF : V4 - Vérification de la tolérance à une panne BDD.
# Les opérations d'arrêt et de promotion sont réalisées manuellement.

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
# 2. Sélection de la phase
# ----------------------------------------------------------

PHASE="${1:-}"

case "$PHASE" in
    initial|panne|apres-bascule)
        ;;
    *)
        echo "Utilisation :"
        echo "  bash tests/v4_panne_bdd.sh initial"
        echo "  bash tests/v4_panne_bdd.sh panne"
        echo "  bash tests/v4_panne_bdd.sh apres-bascule"
        exit 1
        ;;
esac

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

if [[ ! "$PORT_HOTE" =~ ^[0-9]+$ ]] ||
   (( PORT_HOTE < 1 || PORT_HOTE > 65535 )); then
    echo "ERREUR : PORT_HOTE absent ou invalide (1 à 65535)." >&2
    exit 1
fi

HOTE_TEST="${HOTE_TEST:-127.0.0.1}"
PORT_TEST="${PORT_TEST:-$PORT_HOTE}"

if [[ ! "$PORT_TEST" =~ ^[0-9]+$ ]] ||
   (( PORT_TEST < 1 || PORT_TEST > 65535 )); then
    echo "ERREUR : PORT_TEST absent ou invalide." >&2
    exit 1
fi

URL="http://${HOTE_TEST}:${PORT_TEST}"
URL_SANTE="${URL}/sante"
URL_RESULTAT="${URL}/resultat?matricule=BF000001"

# ----------------------------------------------------------
# 4. Vérification des outils
# ----------------------------------------------------------
for outil in curl awk date py; do
    if ! command -v "$outil" >/dev/null 2>&1; then
        echo "ERREUR : outil requis absent : $outil" >&2
        exit 1
    fi
done

# ----------------------------------------------------------
# 5. Fonction de récupération du code HTTP
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

# Récupère le contenu JSON du résultat du candidat.
obtenir_corps_resultat() {
    curl -fsS \
        --connect-timeout 3 \
        --max-time 8 \
        "$URL_RESULTAT"
}

# Vérifie que le JSON contient le résultat attendu.
verifier_resultat() {
    local contenu="$1"

    printf '%s' "$contenu" | py -3 -c '
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
            print(
                f"ERREUR : {cle} attendu={valeur}, "
                f"obtenu={resultat.get(cle)}"
            )
            sys.exit(1)

    print("Contenu JSON : candidat et résultat conformes.")
    sys.exit(0)

except (json.JSONDecodeError, AttributeError) as erreur:
    print(f"ERREUR : réponse JSON invalide : {erreur}")
    sys.exit(1)
'
}
# ----------------------------------------------------------
# 6. Initialisation des preuves
# ----------------------------------------------------------

mkdir -p "$DOSSIER_RESULTATS"

FICHIER_PREUVE="$DOSSIER_RESULTATS/v4_panne_bdd_$(date +%Y%m%d_%H%M%S).txt"

echo "=========================================="
echo "TEST V4 - PANNE DU SERVEUR PRINCIPAL BDD"
echo "=========================================="
echo "Phase : $PHASE"
echo "URL : $URL"


# ----------------------------------------------------------
# 7. Phase initiale : vérifier le fonctionnement normal
# ----------------------------------------------------------

if [[ "$PHASE" == "initial" ]]; then

    echo
    echo "Vérification de l'état initial..."

    CODE_SANTE=$(obtenir_code_http "$URL_SANTE")
    CODE_RESULTAT=$(obtenir_code_http "$URL_RESULTAT")

    echo "/sante : HTTP $CODE_SANTE"
    echo "/resultat : HTTP $CODE_RESULTAT"

    if [[ "$CODE_SANTE" != "200" || "$CODE_RESULTAT" != "200" ]]; then
        echo "RÉSULTAT : ÉCHEC"
        echo "Le service doit fonctionner avant le test de panne."
        exit 1
    fi

            CORPS_RESULTAT=$(obtenir_corps_resultat)

    if ! verifier_resultat "$CORPS_RESULTAT"; then
        echo "RÉSULTAT : ÉCHEC"
        echo "Le contenu du résultat initial est incorrect."
        exit 1
    fi

       {
        echo
        echo "===== PHASE INITIALE ====="
        echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "État : fonctionnement normal"
        echo "/sante : HTTP $CODE_SANTE"
        echo "/resultat : HTTP $CODE_RESULTAT"
        echo "Vérification du contenu JSON : conforme"
    } | tee -a "$FICHIER_PREUVE"

    echo
    echo "RÉSULTAT : SUCCÈS"
    echo "Le service fonctionne avant la panne."
    exit 0
fi

# ----------------------------------------------------------
# 8. Phase panne : bdd1 est arrêtée, bdd2 non promue
# ----------------------------------------------------------

if [[ "$PHASE" == "panne" ]]; then

    echo
    echo "Vérification après arrêt manuel de bdd1..."
    echo "Attente de la détection de l'indisponibilité..."

    sleep 4

    CODE_SANTE=$(obtenir_code_http "$URL_SANTE")

    echo "/sante : HTTP $CODE_SANTE"

    {
        echo
        echo "===== PHASE PANNE BDD1 ====="
        echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Situation : bdd1 arrêtée, bdd2 non promue"
        echo "/sante : HTTP $CODE_SANTE"
    } | tee -a "$FICHIER_PREUVE"

    if [[ "$CODE_SANTE" != "503" ]]; then
        echo "RÉSULTAT : ÉCHEC"
        echo "Le service devait être indisponible avant la promotion."
        exit 1
    fi

    echo
    echo "RÉSULTAT : SUCCÈS"
    echo "L'indisponibilité de la BDD est détectée."
    exit 0
fi

# ----------------------------------------------------------
# 9. Phase après bascule : vérifier le retour du service
# ----------------------------------------------------------

if [[ "$PHASE" == "apres-bascule" ]]; then

    echo
    echo "Vérification après promotion manuelle de bdd2..."
    echo "Attente du rétablissement de HAProxy..."

    CODE_SANTE="000"
    TENTATIVE=0
    MAX_TENTATIVES=30

    while [[ "$TENTATIVE" -lt "$MAX_TENTATIVES" ]]; do

        CODE_SANTE=$(obtenir_code_http "$URL_SANTE")

        if [[ "$CODE_SANTE" == "200" ]]; then
            break
        fi

        TENTATIVE=$((TENTATIVE + 1))
        echo "Tentative $TENTATIVE/$MAX_TENTATIVES : HTTP $CODE_SANTE"
        sleep 2
    done

    if [[ "$CODE_SANTE" != "200" ]]; then
        echo "RÉSULTAT : ÉCHEC"
        echo "Le service n'est pas redevenu disponible."
        exit 1
    fi

    CODE_RESULTAT=$(obtenir_code_http "$URL_RESULTAT")

    echo "/sante : HTTP $CODE_SANTE"
    echo "/resultat : HTTP $CODE_RESULTAT"

    if [[ "$CODE_RESULTAT" != "200" ]]; then
        echo "RÉSULTAT : ÉCHEC"
        echo "La santé est rétablie, mais la recherche de résultat échoue."
        exit 1
    fi

    CORPS_RESULTAT=$(obtenir_corps_resultat)

    if ! verifier_resultat "$CORPS_RESULTAT"; then
        echo "RÉSULTAT : ÉCHEC"
        echo "Le contenu du résultat après bascule est incorrect."
        exit 1
    fi

    {
        echo
        echo "===== PHASE APRÈS BASCULE ====="
        echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Situation : bdd2 promue comme principale"
        echo "/sante : HTTP $CODE_SANTE"
        echo "/resultat : HTTP $CODE_RESULTAT"
        echo "Vérification du contenu JSON : conforme"
        echo "Tentatives de rétablissement : $TENTATIVE"
    } | tee -a "$FICHIER_PREUVE"

    echo
    echo "RÉSULTAT : SUCCÈS"
    echo "Le service fonctionne après la promotion de bdd2."
    exit 0
fi