# -*- mode: ruby -*-
# RÉSULTATS-BF : la recette de toutes les machines.
# Source unique de vérité : la table NOEUDS ci-dessous. Elle engendre config/noeuds.yml.
require 'yaml'
require 'fileutils'

ENV_FILE = File.join(__dir__, '.env')
EXEMPLE  = File.join(__dir__, '.env.exemple')

# Premier lancement : on part de l'exemple (penser à changer les mots de passe).
if !File.exist?(ENV_FILE) && File.exist?(EXEMPLE)
  FileUtils.cp(EXEMPLE, ENV_FILE)
  puts ">> .env créé depuis .env.exemple : changez les mots de passe."
end

def lire_env(chemin)
  h = {}
  return h unless File.exist?(chemin)
  File.readlines(chemin).each do |l|
    l = l.strip
    next if l.empty? || l.start_with?('#')
    k, v = l.split('=', 2)
    next if v.nil?
    h[k.strip] = v.sub(/\s+#.*\z/, '').strip.gsub(/\A["']|["']\z/, '')
  end
  h
end

CONF = lire_env(ENV_FILE)
# Une variable exportée dans le terminal l'emporte sur le .env.
def val(cle, defaut)
  v = ENV[cle]
  v = CONF[cle] if v.nil? || v.empty?
  (v.nil? || v.empty?) ? defaut : v
end

GROUPE    = val('GROUPE', '1').to_i
NB_APP    = val('NB_APP', '2').to_i
PORT_HOTE = val('PORT_HOTE', '8080').to_i
WITH_LB2  = val('WITH_LB2', '0') == '1'
WITH_OBS  = val('WITH_OBS', '0') == '1'

abort "GROUPE doit être entre 1 et 8" unless (1..8).cover?(GROUPE)
abort "NB_APP doit être entre 2 et 9" unless (2..9).cover?(NB_APP)

RESEAU  = "192.168.#{55 + GROUPE}"
BOITE   = 'bento/ubuntu-24.04'
VERSION = '202404.26.0'

# Table des machines : nom, adresse, rôle (= scripts/<rôle>.sh), mémoire en Mo.
NOEUDS = []
NOEUDS << { 'nom' => 'bdd1', 'ip' => "#{RESEAU}.31", 'role' => 'bdd',      'ram' => 768 }
NOEUDS << { 'nom' => 'bdd2', 'ip' => "#{RESEAU}.32", 'role' => 'replique', 'ram' => 768 }
(1..NB_APP).each do |i|
  NOEUDS << { 'nom' => "app#{i}", 'ip' => "#{RESEAU}.#{20 + i}", 'role' => 'app', 'ram' => 512 }
end
NOEUDS << { 'nom' => 'lb1', 'ip' => "#{RESEAU}.11", 'role' => 'lb', 'ram' => 512 }
NOEUDS << { 'nom' => 'lb2', 'ip' => "#{RESEAU}.12", 'role' => 'lb', 'ram' => 512 } if WITH_LB2
NOEUDS << { 'nom' => 'obs', 'ip' => "#{RESEAU}.41", 'role' => 'obs', 'ram' => 768 } if WITH_OBS

# Fichier engendré, lu par les scripts (HAProxy, etc.). Réécrit seulement s'il change.
FileUtils.mkdir_p(File.join(__dir__, 'config'))
NOEUDS_YML = File.join(__dir__, 'config', 'noeuds.yml')
contenu = YAML.dump({ 'groupe' => GROUPE, 'reseau' => RESEAU, 'vip' => "#{RESEAU}.5",
                      'avec_lb2' => WITH_LB2, 'noeuds' => NOEUDS })
if !File.exist?(NOEUDS_YML) || File.read(NOEUDS_YML) != contenu
  File.write(NOEUDS_YML, contenu)
end

# Secrets : transmis aux machines par variables d'environnement, jamais écrits dans le dépôt.
SECRETS = %w[POSTGRES_PASSWORD REPLICATION_PASSWORD APP_DB_PASSWORD GRAFANA_PASSWORD DB_HOSTS]
          .each_with_object({}) { |k, h| h[k] = val(k, '') }

Vagrant.configure('2') do |config|
  config.vm.box = BOITE
  config.vm.box_version = VERSION
  config.vm.box_check_update = false

  NOEUDS.each do |n|
    config.vm.define n['nom'] do |m|
      m.vm.hostname = n['nom']
      m.vm.network 'private_network', ip: n['ip']

      # Seul lb1 est exposé sur le poste hôte.
      if n['nom'] == 'lb1'
        m.vm.network 'forwarded_port', guest: 80, host: PORT_HOTE,
                     host_ip: '127.0.0.1', auto_correct: false
      end

      m.vm.provider 'virtualbox' do |vb|
        vb.name = "resultats-bf-g#{GROUPE}-#{n['nom']}"
        vb.memory = n['ram']
        vb.cpus = 1
        vb.linked_clone = true
      end

      script = File.join(__dir__, 'scripts', "#{n['role']}.sh")

      # Arrêter Vagrant si le script d'un rôle est absent.
      abort "Script de provisionnement introuvable : #{script}" unless
        File.file?(script)

      env = SECRETS.merge(
  'NOM' => n['nom'], 'IP' => n['ip'], 'ROLE' => n['role'],
  'RESEAU' => RESEAU, 'GROUPE' => GROUPE.to_s
)

if n['role'] == 'app'
  env['DB_HOSTS'] = val('DB_HOSTS', "#{RESEAU}.31,#{RESEAU}.32")
end

      # Le répartiteur suit NB_APP : on le reprovisionne à chaque "vagrant up".
      m.vm.provision 'shell', path: script, env: env,
                     run: (n['role'] == 'lb' ? 'always' : 'once')
      # Extension E1 : haute disponibilité des load balancers.
      # Keepalived est configuré uniquement si lb2 est activé.
      if WITH_LB2 && n['role'] == 'lb'
        if n['nom'] == 'lb1'
          peer_ip = "#{RESEAU}.12"
          vrrp_state = 'MASTER'
          vrrp_priority = '150'
        else
          peer_ip = "#{RESEAU}.11"
          vrrp_state = 'BACKUP'
          vrrp_priority = '100'
        end

        keepalived_script = File.join(
          __dir__, 'scripts', 'keepalived.sh'
        )

        abort "Script Keepalived introuvable : #{keepalived_script}" unless
          File.exist?(keepalived_script)

        keepalived_env = {
          'NOM' => n['nom'],
          'IP' => n['ip'],
          'RESEAU' => RESEAU,
          'VIP' => "#{RESEAU}.5",
          'PEER_IP' => peer_ip,
          'VRID' => (55 + GROUPE).to_s,
          'VRRP_STATE' => vrrp_state,
          'VRRP_PRIORITY' => vrrp_priority
        }

        # Exécuté après lb.sh, à chaque provisionnement.
        m.vm.provision 'shell',
                       path: keepalived_script,
                       env: keepalived_env,
                       run: 'always'
      end

      # Extension E2 : agent de supervision sur chaque machine.
      node_exporter_script = File.join(
        __dir__, 'scripts', 'node-exporter.sh'
      )

      abort "Script node_exporter introuvable : #{node_exporter_script}" unless
        File.file?(node_exporter_script)

      m.vm.provision 'shell',
                     path: node_exporter_script,
                     env: env,
                     run: 'once'
    end
  end
end
