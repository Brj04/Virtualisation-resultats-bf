#!/usr/bin/env bash
# Répartiteur HAProxy. Idempotent : ne recharge que si la configuration change.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NOEUDS=/vagrant/config/noeuds.yml
TPL=/vagrant/config/haproxy.cfg.tpl
CIBLE=/etc/haproxy/haproxy.cfg

if ! command -v haproxy >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq haproxy
fi

SRV=$(mktemp); NOUVEAU=$(mktemp)
trap 'rm -f "$SRV" "$NOUVEAU"' EXIT

# Une ligne "server" par machine de rôle app, lue dans noeuds.yml.
awk '/^- nom:/{nom=$3} /^  ip:/{ip=$2} /^  role:/{ if ($2=="app") printf "    server %s %s:3000 check\n", nom, ip }' "$NOEUDS" > "$SRV"
[ -s "$SRV" ] || { echo "ERREUR : aucun serveur app dans $NOEUDS" >&2; exit 1; }

sed -e "/__SERVEURS__/{r $SRV" -e "d}" "$TPL" > "$NOUVEAU"
haproxy -c -f "$NOUVEAU" >/dev/null

systemctl enable haproxy >/dev/null 2>&1
if ! cmp -s "$NOUVEAU" "$CIBLE"; then
  install -m 644 "$NOUVEAU" "$CIBLE"
  systemctl restart haproxy
  echo "lb : configuration mise à jour ($(wc -l < "$SRV") serveurs app)"
else
  systemctl start haproxy
  echo "lb : configuration déjà à jour"
fi
