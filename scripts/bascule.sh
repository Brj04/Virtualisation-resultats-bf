#!/usr/bin/env bash
set -euo pipefail

DEBUT=$(date +%s)

BDD1="bdd1"
BDD2="bdd2"
MARQUEUR="/var/lib/postgresql/.resultats-bdd2-promoted"

echo "========================================"
echo "     BASCULE MANUELLE DE LA BASE"
echo "========================================"

echo "[1/4] Vérification de la réplique bdd2..."

ETAT=$(vagrant ssh "$BDD2" -c "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();'" | tr -d '\r')

if [ "$ETAT" != "t" ]; then
    echo "ERREUR : bdd2 n'est pas en mode réplique."
    exit 1
fi

echo "OK : bdd2 est une réplique."

echo "[2/4] Arrêt du serveur primaire bdd1..."
vagrant ssh "$BDD1" -c "sudo pg_ctlcluster 16 main stop"

echo "[3/4] Promotion de bdd2..."
vagrant ssh "$BDD2" -c "sudo -u postgres psql -v ON_ERROR_STOP=1 -c 'SELECT pg_promote(true, 60);'"

ETAT=$(vagrant ssh "$BDD2" -c "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();'" | tr -d '\r')

if [ "$ETAT" != "f" ]; then
    echo "ERREUR : la promotion de bdd2 n'a pas abouti."
    exit 1
fi

vagrant ssh "$BDD2" -c "sudo touch $MARQUEUR && sudo chmod 600 $MARQUEUR"

echo "[4/4] Bascule terminée."

FIN=$(date +%s)
DUREE=$((FIN - DEBUT))

echo "========================================"
echo "Ancien primaire : 192.168.63.31"
echo "Nouveau primaire : 192.168.63.32"
echo "Temps de bascule : ${DUREE} secondes"
echo "========================================"
echo "ATTENTION : aucune bascule retour automatique."
