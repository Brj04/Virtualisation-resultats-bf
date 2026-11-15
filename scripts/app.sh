
#!/usr/bin/env bash
# RÉSULTATS-BF : installation et configuration du serveur applicatif.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Installation du serveur applicatif : ${NOM:-inconnu} ==="

# Vérification des paramètres transmis par Vagrant.
: "${NOM:?NOM doit être fourni par Vagrant}"
: "${RESEAU:?RESEAU doit être fourni par Vagrant}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD doit être défini}"

if [[ "$APP_DB_PASSWORD" == "changez_moi" ]]; then
    echo "ERREUR : remplacez APP_DB_PASSWORD dans .env." >&2
    exit 1
fi

if [[ ! "$APP_DB_PASSWORD" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "ERREUR : APP_DB_PASSWORD doit contenir uniquement des lettres et chiffres." >&2
    exit 1
fi

# Paramètres de connexion à PostgreSQL.
# La liste des serveurs est configurable depuis le Vagrantfile.
DB_HOSTS="${DB_HOSTS:-${RESEAU}.31,${RESEAU}.32}"
DB_PORT="5432"
DB_NAME="resultatsbf"
DB_USER="resultats_app"

APP_DIR="/opt/resultats-bf"
ENV_DIR="/etc/resultats-bf"
ENV_FILE="$ENV_DIR/app.env"
SERVICE_FILE="/etc/systemd/system/resultats-bf.service"
SOURCE="/vagrant/app/serveur.py"

# Vérifier la présence du code source.
if [[ ! -s "$SOURCE" ]]; then
    echo "ERREUR : fichier applicatif absent ou vide : $SOURCE" >&2
    exit 1
fi


# Installer uniquement les dépendances système manquantes.
PAQUETS=(python3 python3-flask python3-psycopg2 gunicorn)
PAQUETS_MANQUANTS=()

for paquet in "${PAQUETS[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$paquet" 2>/dev/null |
        grep -q '^install ok installed$'; then
        PAQUETS_MANQUANTS+=("$paquet")
    fi
done

if [[ "${#PAQUETS_MANQUANTS[@]}" -gt 0 ]]; then
    echo "Installation des paquets manquants : ${PAQUETS_MANQUANTS[*]}"
    apt-get update -qq
    apt-get install -y -qq "${PAQUETS_MANQUANTS[@]}"
else
    echo "Toutes les dépendances Python sont déjà installées."
fi


# Préparer le répertoire applicatif.
install -d -o root -g root -m 755 "$APP_DIR"
install -d -o root -g root -m 755 "$ENV_DIR"

# Copier le code uniquement s'il a changé.
CODE_CHANGE=0

if ! cmp -s "$SOURCE" "$APP_DIR/serveur.py"; then
    install -o root -g root -m 644 "$SOURCE" "$APP_DIR/serveur.py"
    CODE_CHANGE=1
    echo "Code applicatif mis à jour."
else
    echo "Code applicatif déjà à jour."
fi

# Créer le fichier de configuration sans exposer le secret.
TEMP_ENV=$(mktemp)
trap 'rm -f "$TEMP_ENV"' EXIT

cat > "$TEMP_ENV" <<EOF
DB_HOSTS=$DB_HOSTS
DB_PORT=$DB_PORT
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$APP_DB_PASSWORD
EOF
chmod 600 "$TEMP_ENV"

ENV_CHANGE=0

if ! cmp -s "$TEMP_ENV" "$ENV_FILE"; then
    install -o root -g root -m 600 "$TEMP_ENV" "$ENV_FILE"
    ENV_CHANGE=1
    echo "Configuration de connexion PostgreSQL mise à jour."
else
    echo "Configuration PostgreSQL déjà à jour."
fi

# Définition du service systemd.
TEMP_SERVICE=$(mktemp)
cat > "$TEMP_SERVICE" <<'EOF'
[Unit]
Description=RÉSULTATS-BF - Serveur applicatif
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/opt/resultats-bf
EnvironmentFile=/etc/resultats-bf/app.env
ExecStart=/usr/bin/gunicorn --workers 2 --bind 0.0.0.0:3000 --access-logfile - --error-logfile - serveur:app
Restart=on-failure
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

SERVICE_CHANGE=0

if ! cmp -s "$TEMP_SERVICE" "$SERVICE_FILE"; then
    install -o root -g root -m 644 "$TEMP_SERVICE" "$SERVICE_FILE"
    SERVICE_CHANGE=1
    echo "Définition systemd mise à jour."
else
    echo "Définition systemd déjà à jour."
fi

rm -f "$TEMP_SERVICE"

# Recharger systemd et démarrer ou redémarrer le service.
if [[ "$SERVICE_CHANGE" -eq 1 ]]; then
    systemctl daemon-reload
fi

systemctl enable resultats-bf >/dev/null

if [[ "$CODE_CHANGE" -eq 1 ||
      "$ENV_CHANGE" -eq 1 ||
      "$SERVICE_CHANGE" -eq 1 ]]; then
    systemctl restart resultats-bf
else
    systemctl start resultats-bf
fi

# Vérifier que le service est actif.
if ! systemctl is-active --quiet resultats-bf; then
    echo "ERREUR : le service applicatif ne démarre pas correctement." >&2
    systemctl status resultats-bf --no-pager || true
    journalctl -u resultats-bf -n 30 --no-pager || true
    exit 1
fi

echo "Service applicatif actif sur ${NOM}:3000."
echo "Bases de données configurées : ${DB_HOSTS}:${DB_PORT}/${DB_NAME}"
echo "=== Configuration de ${NOM} terminée ==="
