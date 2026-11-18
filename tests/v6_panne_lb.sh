#!/usr/bin/env bash
# RÉSULTATS-BF - V6 : disponibilité après panne du load balancer.
# Le test doit être exécuté depuis app1, sur le réseau privé.
# Phases : initial | panne | retour

set -Eeuo pipefail

PHASE="${1:-}"

if [[ ! "$PHASE" =~ ^(initial|panne|retour)$ ]]; then
    echo "Usage : $0 initial|panne|retour"
    exit 1
fi

RACINE="/vagrant"
FICHIER_ENV="${RACINE}/.env"
FICHIER_NOEUDS="${RACINE}/config/noeuds.yml"
DOSSIER_RESULTATS="${RACINE}/tests/resultats"
FICHIER_SESSION="${DOSSIER_RESULTATS}/.v6_session_courante"

# Vérifier les fichiers nécessaires.
for fichier in "$FICHIER_ENV" "$FICHIER_NOEUDS"; do
    if [[ ! -f "$fichier" ]]; then
        echo "ERREUR : fichier introuvable : $fichier"
        exit 1
    fi
done

# Vérifier que l'extension E1 est activée dans .env.
WITH_LB2=$(awk -F= '
    /^WITH_LB2=/ {
        valeur = $2
        sub(/[[:space:]]+#.*/, "", valeur)
        gsub(/[[:space:]]/, "", valeur)
        print valeur
        exit
    }
' "$FICHIER_ENV")

if [[ "$WITH_LB2" != "1" ]]; then
    echo "ERREUR : WITH_LB2 doit être égal à 1 dans .env."
    exit 1
fi

# Vérifier que la configuration générée contient bien lb2.
AVEC_LB2=$(awk -F': ' '/^avec_lb2:/ {print $2; exit}' "$FICHIER_NOEUDS")

if [[ "$AVEC_LB2" != "true" ]]; then
    echo "ERREUR : avec_lb2 doit être true dans config/noeuds.yml."
    exit 1
fi

# Récupérer la VIP depuis la configuration générée.
VIP=$(awk -F': ' '/^vip:/ {print $2; exit}' "$FICHIER_NOEUDS")

if [[ -z "$VIP" ]]; then
    echo "ERREUR : VIP introuvable dans config/noeuds.yml."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERREUR : Python 3 est nécessaire pour tester la VIP."
    exit 1
fi

mkdir -p "$DOSSIER_RESULTATS"

# La phase initiale crée un nouveau fichier de preuve horodaté.
if [[ "$PHASE" == "initial" ]]; then
    NOM_FICHIER="v6_panne_lb_$(date +%Y%m%d_%H%M%S).txt"
    FICHIER_RESULTAT="${DOSSIER_RESULTATS}/${NOM_FICHIER}"
    : > "$FICHIER_RESULTAT"
    printf '%s\n' "$NOM_FICHIER" > "$FICHIER_SESSION"
else
    # Les phases panne et retour reprennent la campagne en cours.
    if [[ ! -s "$FICHIER_SESSION" ]]; then
        echo "ERREUR : aucune campagne V6 en cours. Lance d'abord la phase initial."
        exit 1
    fi

    NOM_FICHIER=$(cat "$FICHIER_SESSION")

    if [[ ! "$NOM_FICHIER" =~ ^v6_panne_lb_[0-9]{8}_[0-9]{6}\.txt$ ]]; then
        echo "ERREUR : nom du fichier de preuve invalide."
        exit 1
    fi

    FICHIER_RESULTAT="${DOSSIER_RESULTATS}/${NOM_FICHIER}"

    if [[ ! -f "$FICHIER_RESULTAT" ]]; then
        echo "ERREUR : fichier de preuve de la campagne introuvable."
        exit 1
    fi
fi

# Ajouter une ligne horodatée à la preuve.
journaliser() {
    local message="$1"
    echo "[$(date -Is)] $message" | tee -a "$FICHIER_RESULTAT"
}

# Obtenir le code HTTP sans dépendre de curl.
obtenir_code_http() {
    python3 - "$1" <<'PY'
import sys
import urllib.request
import urllib.error

url = sys.argv[1]

try:
    with urllib.request.urlopen(url, timeout=5) as response:
        print(response.status)
except urllib.error.HTTPError as error:
    print(error.code)
except Exception:
    print("000")
PY
}

URL_SANTE="http://${VIP}/sante"

journaliser "----------------------------------------"
journaliser "TEST V6 - Phase : ${PHASE}"
journaliser "Machine de test : $(hostname)"
journaliser "Adresse virtuelle testée : ${VIP}"
journaliser "URL testée : ${URL_SANTE}"

# Vérifier la disponibilité réelle de l'application et de la BDD.
CODE_HTTP=$(obtenir_code_http "$URL_SANTE")

journaliser "Code HTTP obtenu sur /sante : ${CODE_HTTP}"

if [[ "$CODE_HTTP" == "200" ]]; then
    journaliser "RESULTAT : SUCCES - service accessible."
else
    journaliser "RESULTAT : ECHEC - service indisponible."
    exit 1
fi

journaliser "Fin de la phase ${PHASE}."
journaliser ""

# Clore la campagne après le retour réussi du load balancer.
if [[ "$PHASE" == "retour" ]]; then
    journaliser "Campagne V6 terminée. Preuve conservée dans : ${FICHIER_RESULTAT}"
    rm -f -- "$FICHIER_SESSION"
fi
