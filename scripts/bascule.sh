#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEBUT=$(date +%s)

BDD1="bdd1"
BDD2="bdd2"
LB1="lb1"
IP_BDD2=$(awk -v n="$BDD2" '/^- nom:/ {nom=$3} /^  ip:/ {if (nom == n) {print $2; exit}}' config/noeuds.yml)
APPS=$(awk '/^- nom:/ {nom=$3} /^  role:/ {if ($2=="app") print nom}' config/noeuds.yml)

if [ -z "$IP_BDD2" ]; then
    echo "ERREUR : adresse IP de bdd2 introuvable dans config/noeuds.yml."
    exit 1
fi

if [ -z "$APPS" ]; then
    echo "ERREUR : aucun serveur applicatif detecte dans config/noeuds.yml."
    exit 1
fi

SERVICE_APP="resultats"
MARQUEUR="/var/lib/postgresql/.resultats-bdd2-promoted"

DELAI_SYNCHRO=30
DELAI_HAPROXY=30

echo "========================================"
echo "       BASCULE MANUELLE DE LA BASE"
echo "========================================"

echo "[1/7] Verification de l'etat des serveurs..."

ETAT_BDD1=$(vagrant ssh "$BDD1" -c \
    "sudo -u postgres psql -X -Atqc 'SELECT pg_is_in_recovery();'" | tr -d '\r')

ETAT_BDD2=$(vagrant ssh "$BDD2" -c \
    "sudo -u postgres psql -X -Atqc 'SELECT pg_is_in_recovery();'" | tr -d '\r' || true)

if [ "$ETAT_BDD1" != "f" ]; then
    echo "ERREUR : bdd1 n'est pas le serveur primaire."
    exit 1
fi

if [ "$ETAT_BDD2" != "t" ]; then
    echo "ERREUR : bdd2 n'est pas une replique."
    exit 1
fi

if vagrant ssh "$BDD2" -c "sudo test -e '$MARQUEUR'"; then
    echo "ERREUR : le marqueur de promotion existe deja sur bdd2."
    exit 1
fi

echo "OK : bdd1 est primaire et bdd2 est replique."

echo "[2/7] Verification de la replication..."

ETAT_REPLICATION=$(vagrant ssh "$BDD1" -c \
    "sudo -u postgres psql -X -Atqc \"SELECT count(*) FROM pg_stat_replication WHERE state='streaming';\"" | tr -d '\r')

if [ "$ETAT_REPLICATION" -lt 1 ]; then
    echo "ERREUR : aucune replication active sur bdd1."
    exit 1
fi

ETAT_RECEIVER=$(vagrant ssh "$BDD2" -c \
    "sudo -u postgres psql -X -Atqc 'SELECT status FROM pg_stat_wal_receiver;'" | tr -d '\r')

if [ "$ETAT_RECEIVER" != "streaming" ]; then
    echo "ERREUR : le recepteur WAL de bdd2 n'est pas en streaming."
    exit 1
fi

echo "OK : replication active."

echo "[3/7] Arret temporaire des applications..."

APPS_ARRETEES=()

for APP in $APPS; do
    echo "Arret du service sur $APP..."

    if vagrant ssh "$APP" -c "sudo systemctl stop '$SERVICE_APP'"; then
        APPS_ARRETEES+=("$APP")
    else
        echo "ERREUR : impossible de confirmer l'arret du service sur $APP."
        echo "Tentative de redemarrage des applications concernees..."

        vagrant ssh "$APP" -c "sudo systemctl start '$SERVICE_APP'" || true

        for APP_REPRISE in "${APPS_ARRETEES[@]}"; do
            vagrant ssh "$APP_REPRISE" -c "sudo systemctl start '$SERVICE_APP'" || true
        done

        exit 1
    fi
done

echo "OK : toutes les applications sont temporairement arretees."

echo "[4/7] Capture de la derniere position WAL..."

LSN_CIBLE=$(vagrant ssh "$BDD1" -c \
    "sudo -u postgres psql -X -Atqc 'SELECT pg_current_wal_flush_lsn();'" | tr -d '\r' || true)

if [ -z "$LSN_CIBLE" ]; then
    echo "ERREUR : impossible de recuperer la position WAL."
    echo "Redemarrage des applications..."

    for APP in $APPS; do
        vagrant ssh "$APP" -c "sudo systemctl start '$SERVICE_APP'" || true
    done

    exit 1
fi

echo "Position WAL cible : $LSN_CIBLE"

echo "Arret du serveur primaire bdd1..."

if ! vagrant ssh "$BDD1" -c "sudo pg_ctlcluster 16 main stop"; then
    echo "ERREUR : l'arret de bdd1 n'a pas pu etre confirme."
    echo "Tentative de reprise de bdd1 et des applications..."

    vagrant ssh "$BDD1" -c "sudo pg_ctlcluster 16 main start" || true

    for APP in $APPS; do
        vagrant ssh "$APP" -c "sudo systemctl start '$SERVICE_APP'" || true
    done

    exit 1
fi

echo "Attente du rejeu de la derniere position WAL sur bdd2..."

SYNCHRONISE=false

for ((i=1; i<=DELAI_SYNCHRO; i++)); do
    LSN_OK=$(vagrant ssh "$BDD2" -c \
        "sudo -u postgres psql -X -Atqc \"SELECT COALESCE(pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '$LSN_CIBLE'::pg_lsn) >= 0, false);\"" | tr -d '\r' || true)

    if [ "$LSN_OK" = "t" ]; then
        SYNCHRONISE=true
        break
    fi

    sleep 1
done

if [ "$SYNCHRONISE" != "true" ]; then
    echo "ERREUR : bdd2 n'a pas atteint la position WAL attendue."
    echo "Tentative de redemarrage de bdd1..."

    vagrant ssh "$BDD1" -c "sudo pg_ctlcluster 16 main start" || true

    for APP in $APPS; do
        vagrant ssh "$APP" -c "sudo systemctl start '$SERVICE_APP'" || true
    done

    echo "Bascule annulee. Verifier l'etat des deux bases."
    exit 1
fi

echo "OK : les dernieres ecritures ont ete rejouees."

echo "[5/7] Promotion de bdd2..."

if ! vagrant ssh "$BDD2" -c \
    "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c 'SELECT pg_promote(true, 60);'"; then
    echo "ERREUR : la commande de promotion a echoue."
    echo "L'etat de bdd2 est potentiellement ambigu."
    echo "Ne pas redemarrer bdd1 automatiquement."
    echo "Intervention manuelle necessaire avant de relancer les applications."
    exit 1
fi

ETAT_BDD2=$(vagrant ssh "$BDD2" -c \
    "sudo -u postgres psql -X -Atqc 'SELECT pg_is_in_recovery();'" | tr -d '\r' || true)

if [ "$ETAT_BDD2" != "f" ]; then
    echo "ERREUR : la promotion de bdd2 n'a pas abouti."
    echo "Ne pas redemarrer bdd1 automatiquement."
    exit 1
fi

if ! vagrant ssh "$BDD2" -c \
    "sudo touch '$MARQUEUR' && sudo chmod 600 '$MARQUEUR'"; then
    echo "ERREUR : bdd2 est promu, mais le marqueur n'a pas pu etre cree."
    echo "Ne pas redemarrer bdd1 automatiquement."
    echo "Intervention manuelle necessaire avant de relancer les applications."
    exit 1
fi

echo "OK : bdd2 est maintenant primaire."

echo "[6/7] Redemarrage des applications..."

DEMARRAGE_OK=true

for APP in $APPS; do
    echo "Mise a jour de DB_HOST et redemarrage sur $APP..."

    if ! vagrant ssh "$APP" -c "sudo grep -q '^DB_HOST=' /etc/resultats.env && sudo sed -i 's/^DB_HOST=.*/DB_HOST=$IP_BDD2/' /etc/resultats.env && sudo systemctl restart '$SERVICE_APP'"; then
        echo "ERREUR : impossible de rediriger ou redemarrer le service sur $APP."
        DEMARRAGE_OK=false
    fi
done

if [ "$DEMARRAGE_OK" != "true" ]; then
    echo "ATTENTION : bdd2 est primaire, mais certains services n'ont pas demarre."
    echo "Ne pas redemarrer bdd1 ni effectuer une bascule retour automatique."
    exit 1
fi

echo "Attente de la disponibilite de HAProxy et des applications..."

FONCTIONNEMENT=false

for ((i=1; i<=DELAI_HAPROXY; i++)); do
    if vagrant ssh "$LB1" -c "sudo systemctl is-active --quiet haproxy"; then
        FONCTIONNEMENT=true

        for APP in $APPS; do
            if ! vagrant ssh "$APP" -c "curl -fsS --max-time 5 http://127.0.0.1:3000/sante >/dev/null"; then
                FONCTIONNEMENT=false
                break
            fi
        done

        if [ "$FONCTIONNEMENT" = "true" ]; then
            break
        fi
    fi

    sleep 1
done

if [ "$FONCTIONNEMENT" != "true" ]; then
    echo "ATTENTION : bdd2 est primaire, mais les tests applicatifs ont echoue."
    echo "Ne pas redemarrer bdd1 ni effectuer une bascule retour automatique."
    exit 1
fi

echo "OK : HAProxy et toutes les applications fonctionnent."
echo "[7/7] Bilan de la bascule..."

FIN=$(date +%s)
DUREE=$((FIN - DEBUT))

echo "========================================"
echo "          BASCULE TERMINEE"
echo "========================================"
echo "Ancien primaire : bdd1 (arrete)"
echo "Nouveau primaire : bdd2"
echo "HAProxy : operationnel"
echo "Applications : operationnelles sur tous les noeuds detectes"

echo "Duree : ${DUREE} secondes"
echo "========================================"
echo "ATTENTION : aucune bascule retour automatique."
