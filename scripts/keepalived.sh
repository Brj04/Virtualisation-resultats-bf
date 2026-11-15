#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Configuration Keepalived : ${NOM:-inconnu} ==="

# ----------------------------------------------------------
# 1. Vérification des paramètres transmis par Vagrant
# ----------------------------------------------------------

for variable in NOM IP RESEAU VIP PEER_IP VRID VRRP_STATE VRRP_PRIORITY; do
    if [[ -z "${!variable:-}" ]]; then
        echo "ERREUR : paramètre manquant : $variable" >&2
        exit 1
    fi
done

if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
   [[ ! "$PEER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
   [[ "$IP" == "$PEER_IP" ]]; then
    echo "ERREUR : adresses IP locales ou distantes invalides." >&2
    exit 1
fi

if [[ ! "$RESEAU" =~ ^192\.168\.[0-9]{1,3}$ ]] ||
   [[ "$VIP" != "${RESEAU}.5" ]]; then
    echo "ERREUR : réseau ou adresse VIP invalide." >&2
    exit 1
fi

if [[ ! "$VRID" =~ ^[0-9]+$ ]] || (( VRID < 1 || VRID > 255 )); then
    echo "ERREUR : VRID doit être compris entre 1 et 255." >&2
    exit 1
fi

if [[ ! "$VRRP_PRIORITY" =~ ^[0-9]+$ ]] ||
   (( VRRP_PRIORITY < 1 || VRRP_PRIORITY > 254 )); then
    echo "ERREUR : priorité VRRP invalide." >&2
    exit 1
fi

case "$VRRP_STATE" in
    MASTER|BACKUP) ;;
    *)
        echo "ERREUR : VRRP_STATE doit être MASTER ou BACKUP." >&2
        exit 1
        ;;
esac

# ----------------------------------------------------------
# 2. Détection de l'interface réseau privée
# ----------------------------------------------------------

INTERFACE="$(ip -o -4 addr show |
    awk -v ip="${IP}/" 'index($4, ip) == 1 {print $2; exit}')"

if [[ -z "$INTERFACE" ]]; then
    echo "ERREUR : impossible de trouver l'interface portant $IP." >&2
    exit 1
fi

echo "Adresse locale : $IP"
echo "Adresse du pair : $PEER_IP"
echo "Interface réseau : $INTERFACE"
echo "Adresse virtuelle : $VIP"

# ----------------------------------------------------------
# 3. Installation de Keepalived si nécessaire
# ----------------------------------------------------------

if ! command -v keepalived >/dev/null 2>&1; then
    echo "Installation de Keepalived..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y keepalived
else
    echo "Keepalived est déjà installé."
fi

# HAProxy doit être opérationnel avant le démarrage de VRRP.
if ! systemctl is-active --quiet haproxy; then
    echo "ERREUR : HAProxy n'est pas actif sur $NOM." >&2
    exit 1
fi

# Création de l'utilisateur dédié aux scripts Keepalived
if ! id keepalived_script >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin keepalived_script
fi

# ----------------------------------------------------------
# 4. Création du contrôle de santé de HAProxy
# ----------------------------------------------------------

cat > /usr/local/sbin/verifier-haproxy.sh <<'SCRIPT'
#!/usr/bin/env bash
systemctl is-active --quiet haproxy
SCRIPT

chmod 0755 /usr/local/sbin/verifier-haproxy.sh

# ----------------------------------------------------------
# 5. Génération de la configuration Keepalived
# ----------------------------------------------------------

FICHIER_TEMP="$(mktemp)"

cat > "$FICHIER_TEMP" <<EOF
global_defs {
    router_id RBF_${NOM^^}
    enable_script_security
    script_user keepalived_script
}
vrrp_script chk_haproxy {
    script "/usr/local/sbin/verifier-haproxy.sh"
    interval 2
    timeout 2
    fall 2
    rise 2
    weight -60
}

vrrp_instance VI_RESULTATS {
    state ${VRRP_STATE}
    interface ${INTERFACE}
    virtual_router_id ${VRID}
    priority ${VRRP_PRIORITY}
    advert_int 1
    version 3

    unicast_src_ip ${IP}
    unicast_peer {
        ${PEER_IP}
    }

    virtual_ipaddress {
        ${VIP}/24 dev ${INTERFACE}
    }

    track_script {
        chk_haproxy
    }
}
EOF

# ----------------------------------------------------------
# 6. Validation avant installation
# ----------------------------------------------------------

echo "Validation de la configuration Keepalived..."

if ! keepalived -t -f "$FICHIER_TEMP"; then
    echo "ERREUR : configuration Keepalived invalide." >&2
    rm -f "$FICHIER_TEMP"
    exit 1
fi

install -o root -g root -m 0644 \
    "$FICHIER_TEMP" /etc/keepalived/keepalived.conf

rm -f "$FICHIER_TEMP"

# ----------------------------------------------------------
# 7. Activation du service
# ----------------------------------------------------------

systemctl enable keepalived
systemctl restart keepalived

if ! systemctl is-active --quiet keepalived; then
    echo "ERREUR : Keepalived n'a pas démarré correctement." >&2
    systemctl status keepalived --no-pager || true
    exit 1
fi

echo "=== Keepalived configuré avec succès sur ${NOM} ==="