#!/usr/bin/env bash
set -euo pipefail

DEBUT=$(date +%s)

BDD1="bdd1"
BDD2="bdd2"
LB1="lb1"
APP1="app1"
APP2="app2"

SERVICE_APP="resultats-app"
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
    "sudo -u postgres psql -X -Atqc 'SELECT pg_is_in_recovery();'" | tr -d '\r')

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

vagrant ssh "$APP1" -c "sudo systemctl stop '$SERVICE_APP'" || {
    echo "ERREUR : impossible d'arreter le service sur app1."
    exit 1
}

if ! vagrant ssh "$APP2" -c "sudo systemctl stop '$SERVICE_APP'"; then
    echo "ERREUR : impossible d'arreter le service sur app2."
    echo "Redemarrage du service sur app1..."
    vagrant ssh "$APP1" -c "sudo systemctl start '$SERVICE_APP'" || true
    exit 1
fi

echo "OK : les deux applications sont temporairement arretees."

echo "[4/7] Capture de la derniere position WAL..."

LSN_CIBLE=$(vagrant ssh "$BDD1" -c \
    "sudo -u postgres psql -X -Atqc 'SELECT pg_current_wal_flush_lsn();'" | tr -d '\r')

if [ -z "$LSN_CIBLE" ]; then
    echo "ERREUR : impossible de recuperer la position WAL."
    vagrant ssh "$APP1" -c "sudo systemctl start '$SERVICE_APP'" || true
    vagrant ssh "$APP2" -c "sudo systemctl start '$SERVICE_APP'" || true
    exit 1
fi

echo "Position WAL cible : $LSN_CIBLE"

echo "Arret du serveur primaire bdd1..."
vagrant ssh "$BDD1" -c "sudo pg_ctlcluster 16 main stop"

echo "Attente du rejeu de la derniere position WAL sur bdd2..."

SYNCHRONISE=false

for ((i=1; i<=DELAI_SYNCHRO; i++)); do
    LSN_OK=$(vagrant ssh "$BDD2" -c \
        "sudo -u postgres psql -X -Atqc \"SELECT COALESCE(pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '$LSN_CIBLE'::pg_lsn) >= 0, false);\"" | tr -d '\r')

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
    vagrant ssh "$APP1" -c "sudo systemctl start '$SERVICE_APP'" || true
    vagrant ssh "$APP2" -c "sudo systemctl start '$SERVICE_APP'" || true

    echo "Bascule annulee. Verifier l'etat des deux bases."
    exit 1
fi

echo "OK : les dernieres ecritures ont ete rejouees."

echo "[5/7] Promotion de bdd2..."

vagrant ssh "$BDD2" -c \
    "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c 'SELECT pg_promote(true, 60);'"

ETAT_BDD2=$(vagrant ssh "$BDD2" -c \
    "sudo -u postgres psql -X -Atqc 'SELECT pg_is_in_recovery();'" | tr -d '\r')

if [ "$ETAT_BDD2" != "f" ]; then
    echo "ERREUR : la promotion de bdd2 n'a pas abouti."
    echo "Ne pas redemarrer bdd1 automatiquement."
    exit 1
fi

vagrant ssh "$BDD2" -c \
    "sudo touch '$MARQUEUR' && sudo chmod 600 '$MARQUEUR'"

echo "OK : bdd2 est maintenant primaire."

echo "[6/7] Redemarrage des applications..."

vagrant ssh "$APP1" -c "sudo systemctl start '$SERVICE_APP'"
vagrant ssh "$APP2" -c "sudo systemctl start '$SERVICE_APP'"

echo "Attente de la disponibilite de HAProxy et des applications..."

FONCTIONNEMENT=false

for ((i=1; i<=DELAI_HAPROXY; i++)); do
    if vagrant ssh "$LB1" -c "sudo systemctl is-active --quiet haproxy" &&
       vagrant ssh "$APP1" -c "curl -fsS --max-time 5 http://127.0.0.1:3000/sante >/dev/null" &&
       vagrant ssh "$APP2" -c "curl -fsS --max-time 5 http://127.0.0.1:3000/sante >/dev/null"; then
        FONCTIONNEMENT=true
        break
    fi

    sleep 1
done

if [ "$FONCTIONNEMENT" != "true" ]; then
    echo "ATTENTION : bdd2 est primaire, mais les tests applicatifs ont echoue."
    echo "Ne pas redemarrer bdd1 ni effectuer une bascule retour automatique."
    exit 1
fi

echo "OK : HAProxy et les deux applications fonctionnent."

echo "[7/7] Bilan de la bascule..."

FIN=$(date +%s)
DUREE=$((FIN - DEBUT))

echo "========================================"
echo "          BASCULE TERMINEE"
echo "========================================"
echo "Ancien primaire : bdd1 (arrete)"
echo "Nouveau primaire : bdd2"
echo "HAProxy : operationnel"
echo "Application 1 : operationnelle"
echo "Application 2 : operationnelle"
echo "Duree : ${DUREE} secondes"
echo "========================================"
echo "ATTENTION : aucune bascule retour automatique."