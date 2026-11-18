#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NOEUDS=/vagrant/config/noeuds.yml
TPL=/vagrant/config/haproxy.cfg.tpl
CIBLE=/etc/haproxy/haproxy.cfg
CONTROLE=/usr/local/bin/check_pg_primary.sh

DB_USER="${DB_USER:-resultats_app}"
DB_PASSWORD="${APP_DB_PASSWORD:-${DB_PASSWORD:-}}"

: "${DB_PASSWORD:?APP_DB_PASSWORD est obligatoire}"

# Récupération des adresses depuis noeuds.yml.
ip_de() {
    awk -v cible="$1" '
        /^[[:space:]]*-[[:space:]]*nom:/ {
            nom=$NF
            gsub(/\r/, "", nom)
        }
        /^[[:space:]]*ip:/ {
            ip=$NF
            gsub(/\r/, "", ip)
            if (nom == cible) {
                print ip
                exit
            }
        }
    ' "$NOEUDS"
}

BDD1_IP="$(ip_de bdd1)"
BDD2_IP="$(ip_de bdd2)"

[ -n "$BDD1_IP" ] && [ -n "$BDD2_IP" ] || {
    echo "ERREUR : adresses bdd1 ou bdd2 introuvables."
    exit 1
}

[ -f "$TPL" ] || {
    echo "ERREUR : modèle HAProxy introuvable : $TPL"
    exit 1
}

[ -f /vagrant/scripts/check_pg_primary.sh ] || {
    echo "ERREUR : check_pg_primary.sh introuvable."
    exit 1
}

echo "[1/6] Installation des dépendances..."
apt-get update -qq
apt-get install -y -qq haproxy postgresql-client

echo "[2/6] Installation du contrôle PostgreSQL..."
install -o root -g root -m 755 \
    /vagrant/scripts/check_pg_primary.sh "$CONTROLE"

echo "[3/6] Configuration sécurisée de l'authentification..."

install -d -o haproxy -g haproxy -m 700 /var/lib/haproxy

# Échapper les caractères spéciaux du format .pgpass.
PASS_ESCAPED="${DB_PASSWORD//\\/\\\\}"
PASS_ESCAPED="${PASS_ESCAPED//:/\\:}"

PGPASS_TMP="$(mktemp)"
trap 'rm -f "$PGPASS_TMP"' EXIT

printf '%s:5432:resultats:%s:%s\n' \
    "$BDD1_IP" "$DB_USER" "$PASS_ESCAPED" > "$PGPASS_TMP"

printf '%s:5432:resultats:%s:%s\n' \
    "$BDD2_IP" "$DB_USER" "$PASS_ESCAPED" >> "$PGPASS_TMP"

install -o haproxy -g haproxy -m 600 \
    "$PGPASS_TMP" /var/lib/haproxy/.pgpass

echo "[4/6] Génération de la configuration HAProxy..."

SRV="$(mktemp)"
NOUVEAU="$(mktemp)"

trap 'rm -f "$SRV" "$NOUVEAU" "$PGPASS_TMP"' EXIT

awk '
    { sub(sprintf("%c",13), "", $0) }
    /^- nom:/ { nom=$3 }
    /^  ip:/ { ip=$2 }
    /^  role:/ {
        if ($2=="app") printf "    server %s %s:3000 check\n", nom, ip
    }
' "$NOEUDS" > "$SRV"

[ -s "$SRV" ] || {
    echo "ERREUR : aucun serveur applicatif trouvé."
    exit 1
}

sed \
    -e "/__SERVEURS__/{r $SRV" -e "d}" \
    -e "s|192.168.63.31|$BDD1_IP|g" \
    -e "s|192.168.63.32|$BDD2_IP|g" \
    "$TPL" > "$NOUVEAU"

echo "[5/6] Validation de la configuration..."
haproxy -c -f "$NOUVEAU"

install -o root -g root -m 644 "$NOUVEAU" "$CIBLE"

systemctl enable haproxy >/dev/null
systemctl restart haproxy

echo "HAProxy opérationnel."

# Configuration Keepalived si deux répartiteurs sont déclarés.
LBS="$(awk '
    { sub(sprintf("%c",13), "", $0) }
    /^- nom:/ { nom=$3 }
    /^  ip:/ { ip=$2 }
    /^  role:/ {
        if ($2=="lb") print nom, ip
    }
' "$NOEUDS")"

if [ "$(printf '%s\n' "$LBS" | grep -c .)" -gt 1 ]; then
    echo "[6/6] Configuration de Keepalived..."

    apt-get install -y -qq keepalived

    MOI="$(hostname)"
    MON_IP="$(printf '%s\n' "$LBS" | awk -v m="$MOI" '$1==m {print $2}')"
    PAIR_IP="$(printf '%s\n' "$LBS" | awk -v m="$MOI" '$1!=m {print $2; exit}')"
    VIP="$(awk '$1=="vip:" {print $2}' "$NOEUDS")"

    IFACE="$(ip -o -4 addr show | awk -v ip="$MON_IP" '
        index($4, ip "/")==1 {print $2; exit}
    ')"

    [ -n "$MON_IP" ] && [ -n "$PAIR_IP" ] &&
    [ -n "$VIP" ] && [ -n "$IFACE" ] || {
        echo "ERREUR : paramètres Keepalived incomplets."
        exit 1
    }

    if [ "$MOI" = "$(printf '%s\n' "$LBS" | head -1 | awk '{print $1}')" ]; then
        ETAT=MASTER
        PRIO=100
    else
        ETAT=BACKUP
        PRIO=90
    fi

    KA="$(mktemp)"

    cat > "$KA" <<CONF
global_defs {
    enable_script_security
    script_user root
}

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

    install -d -m 755 /etc/keepalived
    install -o root -g root -m 644 "$KA" /etc/keepalived/keepalived.conf

    rm -f "$KA"

    systemctl enable keepalived >/dev/null
    systemctl restart keepalived

    echo "Keepalived configuré : ${ETAT}, VIP ${VIP}"
else
    echo "[6/6] Un seul répartiteur : Keepalived non activé."
fi

echo "========================================"
echo "Provisionnement de lb1 terminé."
echo "HTTP : port 80"
echo "PostgreSQL : port 5432"
echo "BDD primaire détectée dynamiquement."
echo "========================================"