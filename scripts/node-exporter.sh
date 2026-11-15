#!/usr/bin/env bash
# RÉSULTATS-BF : agent Prometheus de supervision des machines.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${NOM:?Variable NOM absente}"
: "${IP:?Variable IP absente}"

PAQUET=prometheus-node-exporter
SERVICE=prometheus-node-exporter
OVERRIDE_DIR=/etc/systemd/system/${SERVICE}.service.d
OVERRIDE=${OVERRIDE_DIR}/override.conf

echo "=== Installation node_exporter sur ${NOM} (${IP}) ==="

# Installer l'agent et curl si nécessaire.
if ! command -v prometheus-node-exporter >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq "$PAQUET" curl
elif ! command -v curl >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq curl
fi

# Vérifier que le service fourni par Ubuntu existe.
if ! systemctl cat "${SERVICE}.service" >/dev/null 2>&1; then
  echo "ERREUR : service ${SERVICE}.service introuvable." >&2
  exit 1
fi

# Forcer l'écoute sur l'adresse privée de la machine.
install -d -m 755 "$OVERRIDE_DIR"

TMP=$(mktemp)
METRICS=$(mktemp)
trap 'rm -f "$TMP" "$METRICS"' EXIT

cat > "$TMP" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter \$ARGS --web.listen-address=${IP}:9100
EOF

if ! cmp -s "$TMP" "$OVERRIDE"; then
  install -m 644 "$TMP" "$OVERRIDE"
  systemctl daemon-reload
fi

# Activer et démarrer l'agent.
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

# Vérifier le service et attendre l'exposition des métriques.
systemctl is-active --quiet "$SERVICE"

OK=0

for tentative in {1..10}; do
  if curl -fsS --max-time 3 -o "$METRICS" \
    "http://${IP}:9100/metrics" 2>/dev/null \
    && grep -q '^node_' "$METRICS"; then
    OK=1
    break
  fi

  echo "Attente de node_exporter (${tentative}/10)..."
  sleep 2
done

if [[ "$OK" -ne 1 ]]; then
  echo "ERREUR : les métriques node_exporter ne sont pas accessibles." >&2
  exit 1
fi
echo "OK : node_exporter actif sur ${IP}:9100"