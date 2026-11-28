# RÉSULTATS-BF

Une plateforme de consultation de résultats d'examens qui **se reconstruit toute seule**, se répartit sur plusieurs serveurs et survit aux pannes. Toute l'infrastructure est décrite en code (Vagrant + VirtualBox) : deux commandes suffisent pour la détruire puis la retrouver.

Projet du **groupe 8**, Master Informatique, module *DevOps et infrastructures reproductibles*, Université Joseph Ki-Zerbo (Ouagadougou). Enseignant : SOMDA Flavien Hervé.

## Ce que fait la plateforme

Un candidat saisit son matricule et obtient son résultat. Derrière, plusieurs machines virtuelles se partagent le travail :

```text
 poste hôte ──► lb1 (HAProxy) ──► app1, app2 … (service Python sans état) ──► bdd1 (PostgreSQL)
                  ▲                                                              │ réplication
        lb2 + IP virtuelle (E1)                                                  ▼
                                                                              bdd2 (réplique)
                  obs : Prometheus + Grafana (E2), pour observer l'ensemble
```

| Machine | Adresse (groupe 8) | Rôle |
| --- | --- | --- |
| `lb1` | 192.168.63.11 | Répartiteur de charge HAProxy ; seule machine exposée à votre poste |
| `app1` … `appN` | 192.168.63.21 … | Serveurs applicatifs sans état (port 3000) |
| `bdd1` | 192.168.63.31 | PostgreSQL primaire |
| `bdd2` | 192.168.63.32 | PostgreSQL réplique en flux, promouvable |
| `lb2` + IP virtuelle `.5` | 192.168.63.12 | Extension E1 : répartiteur de secours (keepalived, VRRP) |
| `obs` | 192.168.63.41 | Extension E2 : Prometheus et Grafana |

La liste des machines est écrite **une seule fois**, dans le `Vagrantfile`, qui engendre `config/noeuds.yml` ; la configuration de HAProxy et celle de la supervision en sont déduites. Aucune adresse de serveur applicatif n'est écrite à la main. Le détail et les justifications sont dans [`docs/dossier-architecture.md`](docs/dossier-architecture.md).

## Ce qu'il faut avoir

| Outil | Pourquoi | Où l'installer |
| --- | --- | --- |
| **VirtualBox 7.x** | fait tourner les machines virtuelles | [virtualbox.org/wiki/Downloads](https://www.virtualbox.org/wiki/Downloads) |
| **Vagrant 2.4.x** | construit les machines à partir du `Vagrantfile` | [developer.hashicorp.com/vagrant/install](https://developer.hashicorp.com/vagrant/install) |
| **Git** | récupère le dépôt | [git-scm.com/downloads](https://git-scm.com/downloads) |
| **Python 3** | uniquement pour lancer les scripts de test | [python.org/downloads](https://www.python.org/downloads/) |
| **WSL** (Windows seulement) | fournit un terminal Bash pour lancer les scripts de test | [learn.microsoft.com/windows/wsl/install](https://learn.microsoft.com/windows/wsl/install) |

Nous avons testé la plateforme avec VirtualBox 7.2 et Vagrant 2.4.9. Sous Linux, vous pouvez aussi installer ces outils avec le gestionnaire de paquets de votre distribution.

Il faut en plus :

- **8 Go de mémoire** sur votre poste (le socle en utilise environ 3 Go) et plusieurs Go d'espace disque ;
- une connexion Internet pour le premier lancement (la boîte `bento/ubuntu-24.04` et les paquets sont téléchargés) ;
- un terminal Bash : celui de Linux ou de macOS, ou WSL sous Windows.

Ne modifiez pas `/etc/vbox/networks.conf` : la plateforme utilise la plage `192.168.56.0/21` que VirtualBox autorise par défaut.

## Démarrer en cinq minutes de travail (et vingt de patience)

```bash
git clone https://github.com/Brj04/Virtualisation-resultats-bf.git
cd Virtualisation-resultats-bf
vagrant up
```

Au premier lancement, le fichier `.env` est créé automatiquement à partir de `.env.exemple`. Les mots de passe d'exemple suffisent pour essayer ; pour un usage réel, ouvrez `.env` et remplacez-les (lettres et chiffres uniquement). Le fichier `.env` n'est jamais versionné.

**Combien de temps ?** Une reconstruction complète prend de **20 à 25 minutes** selon votre machine. C'est normal : les machines sont créées l'une après l'autre et les paquets sont téléchargés. Laissez la commande aller jusqu'au bout.

### Vérifier que ça marche

Le port par défaut est 8080 (variable `PORT_HOTE` dans `.env`) :

```bash
curl http://127.0.0.1:8080/sante                          # 200 si tout va bien
curl http://127.0.0.1:8080/info                           # nom du serveur qui répond
curl "http://127.0.0.1:8080/resultat?matricule=BF000001"  # un résultat en JSON
```

Répétez la deuxième commande : le nom du serveur alterne entre `app1` et `app2`, c'est la répartition de charge à l'œuvre. Résultat attendu pour le matricule d'essai :

```json
{"matricule": "BF000001", "nom": "CANDIDAT_1", "serie": "C", "moyenne": 9.14, "admis": false}
```

## Les réglages (fichier `.env`)

| Variable | Valeur | Effet |
| --- | --- | --- |
| `GROUPE` | 1 à 8 | Choix du sous-réseau `192.168.(55 + GROUPE).0/24` (groupe 8 : `192.168.63.0/24`) |
| `NB_APP` | 2 à 9 | Nombre de serveurs applicatifs. Exemple : `NB_APP=4 vagrant up` |
| `PORT_HOTE` | un port libre | Port de votre poste redirigé vers `lb1` |
| `WITH_LB2` | 0 ou 1 | 1 : ajoute `lb2` et l'IP virtuelle (extension E1) |
| `WITH_OBS` | 0 ou 1 | 1 : ajoute `obs`, avec Prometheus et Grafana (extension E2) |

Une variable exportée dans le terminal l'emporte sur `.env`.

## Les deux extensions

**E1, répartiteur redondant.** Mettez `WITH_LB2=1`, puis `vagrant up`. L'adresse virtuelle `192.168.63.5` est portée par `lb1` ; si `lb1` s'arrête, `lb2` la reprend et les clients ne changent rien.

**E2, supervision.** Mettez `WITH_OBS=1`, puis `vagrant up`, puis `vagrant provision` pour installer l'agent de mesure sur les machines existantes. Grafana est alors sur `http://192.168.63.41:3000` (utilisateur `admin`, mot de passe : `GRAFANA_PASSWORD` de votre `.env`) et Prometheus sur `http://192.168.63.41:9090`.

## Éprouver la plateforme : les scénarios V1 à V6

Les scripts sont dans `tests/` ; chacun écrit sa preuve dans `tests/resultats/`. Lancez-les depuis la racine du dépôt.

| Scénario | Ce qu'il vérifie | Commandes |
| --- | --- | --- |
| **V1** Répartition | Les serveurs répondent à tour de rôle | `bash tests/v1_repartition.sh` |
| **V2** Panne d'un serveur applicatif | Le service continue sans `app1` | `vagrant halt app1`, `bash tests/v2_panne_app.sh app1`, puis `vagrant up app1 --no-provision` |
| **V3** Charge | 100 requêtes sans échec | `bash tests/v3_charge.sh` |
| **V4** Panne de la base | 503 propre, puis reprise sur `bdd2` | `bash tests/v4_panne_bdd.sh initial`, `vagrant halt bdd1`, `bash tests/v4_panne_bdd.sh panne`, `bash scripts/bascule.sh --panne --confirme-bdd1-arretee`, `bash tests/v4_panne_bdd.sh apres-bascule` |
| **V5** Reconstruction | Tout se reconstruit sans geste manuel | `vagrant destroy -f`, `time vagrant up`, `vagrant ssh bdd1 -c 'sudo bash /vagrant/tests/v5_reconstruction.sh'` |
| **V6** Panne du répartiteur (E1, `WITH_LB2=1`) | `lb2` reprend l'adresse virtuelle | `vagrant ssh app1 -c 'bash /vagrant/tests/v6_panne_lb.sh initial'`, `vagrant halt lb1`, `... panne`, `vagrant up lb1 --no-provision`, `... retour` |

Deux précautions : **V4 modifie l'état de la base** (la bascule ne se défait pas), donc reconstruisez la plateforme avant de le rejouer ; et lancez **V5 en premier** après une reconstruction neuve, tant que l'état est vierge.

Les résultats que nous avons mesurés, avec leurs limites, sont dans la section 7 du [dossier d'architecture](docs/dossier-architecture.md).

## Exploitation courante

| Je veux… | Commande |
| --- | --- |
| Tout reconstruire de zéro | `vagrant destroy -f && vagrant up` |
| Ajouter des serveurs applicatifs | mettre `NB_APP=4` dans `.env`, puis `vagrant up` |
| Rejouer le provisionnement sans effet de bord | `vagrant provision` |
| Basculer la base pendant une maintenance | `bash scripts/bascule.sh` |
| Basculer la base après une panne de `bdd1` | `bash scripts/bascule.sh --panne --confirme-bdd1-arretee` |

Les procédures détaillées (et les précautions après une bascule) sont dans [`docs/procedures.md`](docs/procedures.md). **Après une bascule, ne redémarrez pas `bdd1` telle quelle** : elle contient un état ancien et deviendrait un second primaire.

## Si quelque chose ne va pas

| Symptôme | Cause probable | Que faire |
| --- | --- | --- |
| Un démarrage dépasse le délai ou une machine est annoncée « already provisioned » alors que son script n'a pas tourné | Poste chargé | `vagrant halt -f X`, puis `vagrant up X --no-provision`, puis `vagrant provision X` |
| Une erreur de port au démarrage de `lb1` | Le port 8080 de votre poste est déjà utilisé | Changez `PORT_HOTE` dans `.env` (par exemple 8081) |
| Plantage faute de mémoire | Trop de machines pour votre poste | Gardez `WITH_OBS=0`, ou fermez d'autres programmes |
| Erreur de plage d'adresses réseau | `GROUPE` invalide | `GROUPE` doit valoir de 1 à 8 |
| `py : commande introuvable` pendant un test | Python absent | Installez Python 3 (`python3` ou `py`) |
| Un test de panne renvoie 200 au lieu de 503 | Une bascule a déjà eu lieu | Reconstruisez : `vagrant destroy -f && vagrant up` |

## Organisation du dépôt

```text
Vagrantfile     les machines et les réglages (source unique de vérité)
.env.exemple    modèle des réglages et des mots de passe
config/         modèle de configuration HAProxy, tableau de bord Grafana
                (noeuds.yml est engendré au lancement, jamais écrit à la main)
scripts/        provisionnement (common, lb, app, bdd, replique, obs) et bascule
app/            service applicatif (Python)
sql/            schéma de la base et 50 000 candidats d'essai
tests/          scénarios V1 à V6 et preuves mesurées
docs/           dossier d'architecture, procédures, schéma, journal de bord
```

## Limites connues

Nous préférons les dire plutôt que les cacher :

- La bascule de la base est **manuelle** ; il n'y a pas de bascule retour automatique.
- En mode panne, les écritures de `bdd1` pas encore reçues par `bdd2` sont perdues.
- Après une bascule, `bdd1` doit être reconstruite comme réplique : ce n'est pas automatisé.
- Les machines virtuelles se partagent le processeur de votre poste : ajouter des serveurs applicatifs n'augmente pas forcément le débit.
- Pendant une panne de la base, les clients reçoivent la page d'erreur 503 de HAProxy, pas un message JSON.
- Après une bascule, relancer `vagrant provision` sur les serveurs applicatifs les ferait pointer de nouveau vers `bdd1` : ne le faites pas sans reconstruire.
- Le test de charge V3 envoie les requêtes l'une après l'autre ; il mesure la fiabilité (100/100), pas le débit maximal de la plateforme.

## L'équipe

| Membre | Rôle |
| --- | --- |
| BASSOLÉ René Junior | Architecte réseau et répartition (Vagrantfile, HAProxy, E1, E2) |
| BELEMBOULLI Massahouda | Ingénieur applicatif (service HTTP sans état) |
| YARO Binjassi Laurentine | Ingénieur données (PostgreSQL, réplication, bascule) |
| ZONGO Roukiatou | Ingénieur essais (scénarios V1 à V6, mesures) |
