#!/usr/bin/env bash
set -euo pipefail

source /vagrant/scripts/common.sh

: "${DB_PASSWORD:?APP_DB_PASSWORD est absent}"

DB_HOST="$(ip_de lb1)"
[ -n "$DB_HOST" ] || { log "IP de lb1 introuvable"; exit 1; }

apt_install python3 python3-psycopg2

install -d -m 755 /opt/resultats-app

if ! cmp -s /vagrant/app/serveur.py /opt/resultats-app/serveur.py 2>/dev/null; then
    install -m 644 /vagrant/app/serveur.py /opt/resultats-app/serveur.py
    CHANGED=1
fi

# Migration de l'ancien service resultats-app vers resultats
if [ -f /etc/systemd/system/resultats-app.service ] || [ -f /etc/resultats-app.env ]; then
    systemctl stop resultats-app 2>/dev/null || true
    systemctl disable resultats-app 2>/dev/null || true
    rm -f /etc/systemd/system/resultats-app.service
    rm -f /etc/resultats-app.env
    systemctl daemon-reload
fi

DB_PASSWORD_B64="$(printf '%s' "$DB_PASSWORD" | base64 -w0)"

ecrire_fichier /etc/resultats.env <<EOF
DB_HOST=$DB_HOST
DB_PORT=5432
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD_B64=$DB_PASSWORD_B64
EOF

chmod 600 /etc/resultats.env

ecrire_fichier /etc/systemd/system/resultats.service <<'UNIT'
[Unit]
Description=Serveur applicatif RESULTATS-BF
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
EnvironmentFile=/etc/resultats.env
ExecStart=/usr/bin/python3 /opt/resultats-app/serveur.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

if [ "$CHANGED" -eq 1 ]; then
    systemctl daemon-reload
    systemctl enable resultats
    systemctl restart resultats
else
    systemctl enable --now resultats
fi

log "Serveur applicatif operationnel sur le port 3000."