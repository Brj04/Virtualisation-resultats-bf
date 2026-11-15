#!/usr/bin/env bash
# obs — supervision : Prometheus (collecte) + Grafana (tableau de bord)
source /vagrant/scripts/common.sh
: "${GRAFANA_PASSWORD:?}"

apt_install prometheus prometheus-node-exporter ca-certificates gnupg curl

# --- Dépôt officiel Grafana (Grafana n'est plus dans les dépôts Ubuntu) -----
if [ ! -f /etc/apt/keyrings/grafana.gpg ]; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
fi
CHANGED=0
ecrire_fichier /etc/apt/sources.list.d/grafana.list \
  <<< "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main"
[ "$CHANGED" = 1 ] && apt-get update -qq
apt_install grafana
systemctl enable --now prometheus-node-exporter

# --- Prometheus : cibles ENGENDRÉES depuis noeuds.yml -----------------------
CHANGED=0
CIBLES_NODE=""
while read -r nom ip; do
  CIBLES_NODE+="      - targets: ['${ip}:9100']"$'\n'"        labels: { nom: '${nom}' }"$'\n'
done < <(tous_noeuds)
CIBLES_LB=""
while read -r nom ip; do
  CIBLES_LB+="      - targets: ['${ip}:8405']"$'\n'"        labels: { nom: '${nom}' }"$'\n'
done < <(noeuds_par_role lb)

ecrire_fichier /etc/prometheus/prometheus.yml <<PROM
global:
  scrape_interval: 5s
  evaluation_interval: 15s

scrape_configs:
  - job_name: node
    static_configs:
${CIBLES_NODE}
  - job_name: haproxy
    static_configs:
${CIBLES_LB}
PROM
promtool check config /etc/prometheus/prometheus.yml >/dev/null
systemctl enable prometheus
if [ "$CHANGED" = 1 ]; then systemctl restart prometheus; else systemctl start prometheus; fi

# --- Grafana : source de données + tableau de bord (provisionnés) -----------
CHANGED=0
ecrire_fichier /etc/grafana/provisioning/datasources/prometheus.yml <<'DS'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prom
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
DS
ecrire_fichier /etc/grafana/provisioning/dashboards/resultats.yml <<'DB'
apiVersion: 1
providers:
  - name: resultats-bf
    type: file
    options:
      path: /var/lib/grafana/dashboards
DB
mkdir -p /var/lib/grafana/dashboards
ecrire_fichier /var/lib/grafana/dashboards/resultats.json < /vagrant/config/grafana-dashboard.json

# Mot de passe administrateur transmis par variable d'environnement systemd
mkdir -p /etc/systemd/system/grafana-server.service.d
ecrire_fichier /etc/grafana/secrets.env <<< "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}"
chmod 600 /etc/grafana/secrets.env
ecrire_fichier /etc/systemd/system/grafana-server.service.d/secrets.conf <<'OVR'
[Service]
EnvironmentFile=/etc/grafana/secrets.env
OVR
systemctl daemon-reload
systemctl enable grafana-server
if [ "$CHANGED" = 1 ]; then systemctl restart grafana-server; else systemctl start grafana-server; fi

log "Prometheus : http://$(ip_de obs):9090   Grafana : http://$(ip_de obs):3000 (admin)"