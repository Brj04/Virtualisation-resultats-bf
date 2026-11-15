#!/usr/bin/env bash
# R?SULTATS-BF : installation de Prometheus et Grafana sur obs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${NOM:?Variable NOM absente}"
: "${IP:?Variable IP absente}"
: "${GRAFANA_PASSWORD:?Variable GRAFANA_PASSWORD absente}"

NOEUDS=/vagrant/config/noeuds.yml
TPL=/vagrant/config/prometheus.yml.tpl
PROM_CONFIG=/etc/prometheus/prometheus.yml
DATASOURCE=/etc/grafana/provisioning/datasources/prometheus.yml

echo "=== Installation de la supervision sur ${NOM} (${IP}) ==="

# V?rifier les fichiers n?cessaires.
for fichier in "$NOEUDS" "$TPL"; do
  if [ ! -f "$fichier" ]; then
    echo "ERREUR : fichier introuvable : $fichier" >&2
    exit 1
  fi
done

# Pr?parer les fichiers temporaires.
NODE_TARGETS=$(mktemp)
HAPROXY_TARGETS=$(mktemp)
PROM_TMP=$(mktemp)
trap 'rm -f "$NODE_TARGETS" "$HAPROXY_TARGETS" "$PROM_TMP"' EXIT

# G?n?rer les cibles node_exporter de toutes les machines.
# Générer les cibles node_exporter de toutes les machines.
awk '
{
  gsub(/\r/, "")
  if ($1 == "-") nom=$3
  if ($1 == "ip:") ip=$2
  if ($1 == "role:") {
    if (nom=="" || ip=="") exit 1
    printf "      - targets: [\047%s:9100\047]\n", ip
    printf "        labels:\n          instance: %s\n", nom
  }
}
' "$NOEUDS" > "$NODE_TARGETS"
# Générer les cibles HAProxy uniquement pour les répartiteurs.
awk '
{
  gsub(/\r/, "")
  if ($1 == "-") nom=$3
  if ($1 == "ip:") ip=$2
  if ($1 == "role:") {
    if ($2=="lb") {
      printf "      - targets: [\047%s:8405\047]\n", ip
      printf "        labels:\n          instance: %s\n", nom
    }
  }
}
' "$NOEUDS" > "$HAPROXY_TARGETS"
if [ ! -s "$NODE_TARGETS" ] || [ ! -s "$HAPROXY_TARGETS" ]; then
  echo "ERREUR : g?n?ration des cibles incompl?te." >&2
  exit 1
fi

# Remplacer les marqueurs du mod?le Prometheus.
awk -v prom_ip="$IP" \
    -v node_file="$NODE_TARGETS" \
    -v hap_file="$HAPROXY_TARGETS" '
/__PROMETHEUS_IP__/ {
  gsub(/__PROMETHEUS_IP__/, prom_ip)
}
/__NODE_EXPORTER_TARGETS__/ {
  while ((getline ligne < node_file) > 0) print ligne
  close(node_file)
  next
}
/__HAPROXY_TARGETS__/ {
  while ((getline ligne < hap_file) > 0) print ligne
  close(hap_file)
  next
}
{ print }
' "$TPL" > "$PROM_TMP"

# Installer Prometheus.
apt-get update -qq
apt-get install -y -qq prometheus curl

# V?rifier la configuration avant de remplacer celle du paquet.
promtool check config "$PROM_TMP"

systemctl stop prometheus || true
install -m 644 "$PROM_TMP" "$PROM_CONFIG"

# Configurer l'?coute sur l'adresse priv?e et une r?tention de 7 jours.
cat > /etc/default/prometheus <<EOF
ARGS="--web.listen-address=${IP}:9090 --storage.tsdb.retention.time=7d"
EOF

systemctl daemon-reload
systemctl enable prometheus >/dev/null
systemctl restart prometheus
systemctl is-active --quiet prometheus

if ! curl -fsS --max-time 10 "http://${IP}:9090/-/ready" >/dev/null; then
  echo "ERREUR : Prometheus ne r?pond pas." >&2
  exit 1
fi

echo "OK : Prometheus actif sur ${IP}:9090"

# Installer Grafana OSS depuis son d?p?t officiel.
apt-get install -y -qq apt-transport-https wget gnupg

install -d -m 755 /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.asc \
  https://apt.grafana.com/gpg-full.key
chmod 644 /etc/apt/keyrings/grafana.asc

cat > /etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main
EOF

apt-get update -qq
apt-get install -y -qq grafana

# D?clarer Prometheus comme source de donn?es Grafana.
install -d -m 755 /etc/grafana/provisioning/datasources

cat > "$DATASOURCE" <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
EOF

chmod 644 "$DATASOURCE"

# D?marrer Grafana.
systemctl enable grafana-server >/dev/null
systemctl restart grafana-server
systemctl is-active --quiet grafana-server

# Attendre que l'interface HTTP soit disponible.
PRET=0
for tentative in $(seq 1 30); do
  if curl -fsS --max-time 3 \
    "http://${IP}:3000/api/health" >/dev/null; then
    PRET=1
    break
  fi
  sleep 2
done

if [ "$PRET" -ne 1 ]; then
  echo "ERREUR : Grafana ne r?pond pas sur le port 3000." >&2
  exit 1
fi

# D?finir le mot de passe administrateur sans l'afficher.
printf '%s\n' "$GRAFANA_PASSWORD" |
  /usr/share/grafana/bin/grafana cli \
    --homepath /usr/share/grafana \
    --config /etc/grafana/grafana.ini \
    admin reset-admin-password --password-from-stdin

echo "OK : Grafana actif sur ${IP}:3000"
echo "=== Installation de la supervision termin?e ==="
