#!/usr/bin/env bash
# Fonctions communes — sourcé par tous les scripts de provisionnement.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
cd /tmp

NOEUDS_YML=/vagrant/config/noeuds.yml
CHANGED=0   # passe à 1 quand ecrire_fichier modifie réellement un fichier

# Variables transmises par le Vagrantfile : APP_DB_PASSWORD, REPLICATION_PASSWORD, GRAFANA_PASSWORD.
# Les noms de base et de rôle applicatif sont fixes (modifiables ici, à un seul endroit).
DB_NAME=${DB_NAME:-resultats}
DB_USER=${DB_USER:-resultats_app}
DB_PASSWORD=${DB_PASSWORD:-${APP_DB_PASSWORD:-}}
# E2 est active si la machine obs figure dans noeuds.yml (pas de variable en plus)
AVEC_OBS=0
if grep -q '^- nom: obs$' "$NOEUDS_YML" 2>/dev/null; then AVEC_OBS=1; fi

log() { echo "[$(hostname)] $*"; }

# apt : un seul update si les listes ont plus d'une heure, installs groupés
apt_install() {
  if [ -z "$(find /var/lib/apt/lists -maxdepth 1 -type f -name '*_Packages*' -mmin -60 -print -quit)" ]; then
    apt-get update -qq
  fi
  apt-get install -y -qq --no-install-recommends "$@"
}

# Écrit stdin dans un fichier SEULEMENT si le contenu change (idempotence).
# Usage : ecrire_fichier /chemin <<EOF ... EOF   (jamais dans un pipe : CHANGED serait perdu)
ecrire_fichier() {
  local cible="$1" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ ! -f "$cible" ] || ! cmp -s "$tmp" "$cible"; then
    cat "$tmp" > "$cible"      # écrit en place : conserve propriétaire et droits
    CHANGED=1
    log "mis à jour : $cible"
  fi
  rm -f "$tmp"
}

# Lecture de config/noeuds.yml (source unique de vérité)
noeuds_par_role() {   # affiche "nom ip" pour chaque nœud du rôle demandé
  awk -v role="$1" '
    /^- nom:/  { nom=$3 }
    /^  ip:/   { ip=$2 }
    /^  role:/ { if ($2 == role) print nom, ip }' "$NOEUDS_YML"
}
ip_de() {             # ip_de bdd1  ->  192.168.56.31
  awk -v n="$1" '/^- nom:/ { nom=$3 } /^  ip:/ { if (nom == n) print $2 }' "$NOEUDS_YML"
}

pg_version() { ls /usr/lib/postgresql | sort -V | tail -1; }

# Configuration PostgreSQL commune à bdd1 et bdd2 (bdd2 doit pouvoir être promue)
configurer_postgres() {
  local pgv reseau hba nouveau
  pgv=$(pg_version)
  reseau="$(ip_de bdd1 | sed 's/\.[0-9]*$//').0/24"
  mkdir -p "/etc/postgresql/$pgv/main/conf.d"

  # ATTENTION : max_connections doit être identique sur primaire et réplique
  ecrire_fichier "/etc/postgresql/$pgv/main/conf.d/90-resultats.conf" <<'CONF'
listen_addresses = '*'
wal_level = replica
max_wal_senders = 5
wal_keep_size = '128MB'
hot_standby = on
max_connections = 150
CONF

  hba="/etc/postgresql/$pgv/main/pg_hba.conf"
  nouveau=$(
    sed '/# BEGIN RESULTATS/,/# END RESULTATS/d' "$hba"
    cat <<HBA
# BEGIN RESULTATS
host  all          ${DB_USER}  ${reseau}  scram-sha-256
host  replication  replicator  ${reseau}  scram-sha-256
# END RESULTATS
HBA
  )
  ecrire_fichier "$hba" <<< "$nouveau"
}

# --- Extensions -------------------------------------------------------------
reseau_prefixe() { ip_de bdd1 | sed 's/\.[0-9]*$//'; }     # 192.168.56
ip_vip()         { echo "$(reseau_prefixe).5"; }            # IP virtuelle VRRP (E1)
tous_noeuds()    { awk '/^- nom:/ { nom=$3 } /^  ip:/ { print nom, $2 }' "$NOEUDS_YML"; }

# E2 : node_exporter sur chaque VM (seulement si AVEC_OBS=1)
installer_node_exporter() {
  [ "${AVEC_OBS:-0}" = "1" ] || return 0
  apt_install prometheus-node-exporter
  systemctl enable --now prometheus-node-exporter
}
