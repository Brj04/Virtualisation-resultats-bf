# RÉSULTATS-BF

## Présentation

RÉSULTATS-BF est un projet visant à mettre en place une infrastructure virtualisée et résiliente pour une application de consultation des résultats des examens au Burkina Faso.

Le projet repose sur plusieurs machines virtuelles qui assurent les différents services de l'architecture.

## Architecture générale

L'infrastructure comprend notamment :

| Machine | Adresse IP | Rôle |
|---|---|---|
| bdd1 | 192.168.63.31 | Base PostgreSQL primaire |
| bdd2 | 192.168.63.32 | Base PostgreSQL secondaire |
| app1 | 192.168.63.21 | Serveur applicatif |
| app2 | 192.168.63.22 | Second serveur applicatif |
| lb1 | 192.168.63.11 | Équilibrage de charge |
| VIP | 192.168.63.5 | Adresse IP virtuelle |

Réseau privé : `192.168.63.0/24`.

## Technologies utilisées

- Vagrant et VirtualBox : virtualisation ;
- Ubuntu : système d'exploitation des machines virtuelles ;
- PostgreSQL 16 : système de gestion de base de données ;
- Bash : scripts d'installation et d'administration ;
- Git et GitHub : gestion du code source et du travail collaboratif.

## Organisation du dépôt

```text
Projet_RÉSULTATS-BF/
├── app/
├── config/
├── docs/
│   ├── procedures.md
│   └── journal-de-bord.md
├── scripts/
│   ├── common.sh
│   ├── bdd.sh
│   ├── replique.sh
│   └── bascule.sh
├── sql/
│   └── init.sql
├── tests/
├── .env.exemple
├── .gitignore
├── Vagrantfile
└── README.md
```

## Démarrage du projet

### Prérequis

- VirtualBox ;
- Vagrant ;
- Git ;
- PowerShell ou un terminal compatible.

### Installation

Cloner le dépôt :

```bash
git clone https://github.com/Brj04/Virtualisation-resultats-bf.git
cd Virtualisation-resultats-bf
```

Créer le fichier `.env` à partir du modèle `.env.exemple`, puis renseigner les mots de passe nécessaires.

Démarrer les machines :

```bash
vagrant up
```

Consulter leur état :

```bash
vagrant status
```

## Base de données

La base utilisée est `resultats`.

La table principale est `resultats` et contient les informations suivantes :

- `matricule` : identifiant du candidat ;
- `nom` : nom du candidat ;
- `serie` : série de l'examen ;
- `moyenne` : moyenne obtenue ;
- `admis` : indique si le candidat est admis.

## Documentation

Les procédures d'administration PostgreSQL sont disponibles dans `docs/procedures.md`.

Le suivi des travaux du membre chargé des bases de données est disponible dans `docs/journal-de-bord.md`.

## Sécurité

Le fichier `.env` contient des informations confidentielles. Il ne doit jamais être publié sur GitHub.

Utiliser `.env.exemple` pour partager la structure des variables d'environnement sans divulguer les secrets.

## État d'avancement

La configuration du serveur primaire et l'initialisation des données ont été réalisées et vérifiées.

La configuration effective de la réplication sur bdd2, les tests de bascule et la redirection des applications restent à valider.

## Dépôt GitHub

https://github.com/Brj04/Virtualisation-resultats-bf
