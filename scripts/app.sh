#!/usr/bin/env bash
# appN — serveur applicatif sans état
source /vagrant/scripts/common.sh
: "${DB_NAME:?}" "${DB_USER:?}" "${DB_PASSWORD:?}"

apt_install python3 python3-psycopg2

mkdir -p /opt/resultats
ecrire_fichier /opt/resultats/serveur.py < /vagrant/app/serveur.py

# DB_HOST pointe sur bdd1 ; scripts/bascule.sh le change vers bdd2 en cas de panne.
ecrire_fichier /etc/resultats.env <<ENV
DB_HOST=$(ip_de bdd1)
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
PORT=3000
ENV
chmod 600 /etc/resultats.env

ecrire_fichier /etc/systemd/system/resultats.service <<'UNIT'
[Unit]
Description=Service RESULTATS-BF
After=network-online.target

[Service]
EnvironmentFile=/etc/resultats.env
ExecStart=/usr/bin/python3 /opt/resultats/serveur.py
Restart=always
RestartSec=1
User=nobody

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable resultats
if [ "$CHANGED" = 1 ]; then systemctl restart resultats; else systemctl start resultats; fi
log "service resultats actif sur le port 3000"

installer_node_exporter
