#!/usr/bin/env bash
# Répartiteur HAProxy. Idempotent : ne recharge que si la configuration change.
# Extension E1 : si plusieurs répartiteurs existent (WITH_LB2=1), keepalived porte une IP virtuelle.
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

# ---- E1 : keepalived et IP virtuelle (seulement s'il y a au moins deux répartiteurs) ----
LBS=$(awk '/^- nom:/{nom=$3} /^  ip:/{ip=$2} /^  role:/{ if ($2=="lb") print nom, ip }' "$NOEUDS")
if [ "$(echo "$LBS" | grep -c .)" -gt 1 ]; then
  apt-get install -y -qq keepalived

  MOI=$(hostname)
  MON_IP=$(echo "$LBS" | awk -v m="$MOI" '$1==m {print $2}')
  PAIR_IP=$(echo "$LBS" | awk -v m="$MOI" '$1!=m {print $2; exit}')
  VIP=$(awk '/^vip:/ {print $2}' "$NOEUDS")
  IFACE=$(ip -o -4 addr show | awk -v ip="$MON_IP" '$4 ~ "^" ip "/" {print $2; exit}')
  [ -n "$MON_IP" ] && [ -n "$PAIR_IP" ] && [ -n "$VIP" ] && [ -n "$IFACE" ] \
    || { echo "ERREUR keepalived : IP, pair, VIP ou interface introuvable" >&2; exit 1; }

  # Le premier répartiteur de la liste (lb1) est MASTER, les autres BACKUP.
  if [ "$MOI" = "$(echo "$LBS" | head -1 | awk '{print $1}')" ]; then ETAT=MASTER; PRIO=100; else ETAT=BACKUP; PRIO=90; fi

  KA=$(mktemp)
  cat > "$KA" <<CONF
global_defs {
    enable_script_security
    script_user root
}

# Un répartiteur dont HAProxy est arrêté cède l'IP virtuelle
vrrp_script chk_haproxy {
    script "/usr/bin/systemctl is-active --quiet haproxy"
    interval 1
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state ${ETAT}
    interface ${IFACE}
    virtual_router_id 51
    priority ${PRIO}
    advert_int 1
    unicast_src_ip ${MON_IP}
    unicast_peer {
        ${PAIR_IP}
    }
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_haproxy
    }
}
CONF
  systemctl enable keepalived >/dev/null 2>&1
  if ! cmp -s "$KA" /etc/keepalived/keepalived.conf 2>/dev/null; then
    install -m 644 "$KA" /etc/keepalived/keepalived.conf
    systemctl restart keepalived
    echo "lb : keepalived mis à jour (${ETAT}, priorité ${PRIO}, IP virtuelle ${VIP})"
  else
    systemctl start keepalived
    echo "lb : keepalived déjà à jour (${ETAT}, IP virtuelle ${VIP})"
  fi
  rm -f "$KA"
fi