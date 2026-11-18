# Procédures d'administration de la base de données

## 1. Présentation

Le projet RÉSULTATS-BF utilise PostgreSQL pour stocker les résultats des examens. L'architecture prévoit deux serveurs de bases de données :

- **bdd1 (192.168.63.31)** : serveur PostgreSQL primaire.
- **bdd2 (192.168.63.32)** : serveur PostgreSQL secondaire destiné à la réplication.

La base de données utilisée est `resultats`.

Les rôles PostgreSQL sont :
- `resultats_app` : utilisateur destiné à l'application.
- `replicator` : utilisateur dédié à la réplication physique.

## 2. Démarrage des machines

Depuis le répertoire racine du projet :

```powershell
vagrant status
vagrant up
```

Pour démarrer uniquement les deux serveurs de bases de données :

```powershell
vagrant up bdd1 bdd2
```

## 3. Configuration du serveur primaire bdd1

Le script `scripts/bdd.sh` assure notamment :

- l'installation de PostgreSQL ;
- l'activation du service PostgreSQL ;
- la configuration de l'accès réseau ;
- la création des rôles PostgreSQL ;
- la création de la base `resultats` ;
- l'exécution du script SQL d'initialisation.

Le fichier `sql/init.sql` crée la table `resultats` et insère les données de test.

Pour consulter l'état du service :

```powershell
vagrant ssh bdd1 -c "sudo pg_lsclusters"
```

Pour vérifier les paramètres de réplication :

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -c 'SHOW wal_level;' -c 'SHOW max_wal_senders;' -c 'SHOW max_connections;'"
```

Pour vérifier le nombre de résultats :

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -c 'SELECT COUNT(*) FROM resultats;'"
```

## 4. Configuration de la réplication sur bdd2

Le script `scripts/replique.sh` est prévu pour :

- installer PostgreSQL 16 ;
- configurer le serveur secondaire ;
- effectuer une copie physique de la base primaire avec `pg_basebackup` ;
- configurer le mode standby ;
- démarrer PostgreSQL en mode secondaire.

La réplication doit être configurée après la disponibilité du serveur primaire.

Commande de provisionnement :

```powershell
vagrant provision bdd2
```

Vérifier ensuite l'état du cluster :

```powershell
vagrant ssh bdd2 -c "sudo pg_lsclusters"
```

Vérifier que le serveur est en mode secondaire :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();'"
```

Résultat attendu :

```text
t
```

Vérifier la présence des données répliquées :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c 'SELECT COUNT(*) FROM resultats;'"
```

La réplication ne doit être considérée comme opérationnelle qu'après ces vérifications.

## 5. Vérification de la réplication depuis bdd1

Sur le serveur primaire :

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -x -c 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'"
```

Le serveur secondaire doit apparaître dans les connexions de réplication.

## 6. Procédure de bascule

Le fichier `scripts/bascule.sh` contient une procédure de bascule manuelle de bdd1 vers bdd2.

Cette opération consiste à :

1. vérifier que bdd1 est le serveur primaire et bdd2 sa réplique ;
2. vérifier que la réplication est active et que le récepteur WAL de bdd2 est en streaming ;
3. arrêter temporairement les applications ;
4. relever la dernière position WAL puis arrêter bdd1 ;
5. attendre que bdd2 rejoue les dernières écritures ;
6. promouvoir bdd2 en nouveau serveur primaire ;
7. redémarrer les applications et vérifier leur disponibilité.

### Redirection des connexions PostgreSQL

Avant la bascule, les applications utilisent HAProxy (`lb1`) comme adresse de connexion à PostgreSQL.

Après la promotion de bdd2, le script `scripts/bascule.sh` met à jour directement la variable `DB_HOST` dans `/etc/resultats.env` sur chaque serveur applicatif. Cette variable reçoit l'adresse IP de bdd2, puis le service systemd `resultats` est redémarré afin que l'application utilise le nouveau serveur primaire.

Le contrôle externe `check_pg_primary.sh` interroge les serveurs PostgreSQL à l'aide de `pg_is_in_recovery()`. HAProxy peut ainsi identifier le serveur qui n'est plus en mode récupération et lui diriger les connexions qui passent par lui.

La redirection des applications et la continuité du service doivent être vérifiées lors des tests de bascule.
**Attention :** cette procédure est manuelle. Elle ne constitue pas une bascule automatique en cas de panne de bdd1. Elle ne réalise pas non plus de bascule retour automatique vers bdd1.

## 7. Vérification après une bascule

Après une promotion réussie, vérifier le rôle de bdd2 :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();'"
```

Résultat attendu :

```text
f
```

Vérifier que la base est accessible :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c 'SELECT COUNT(*) FROM resultats;'"
```

## 8. Sécurité des informations de connexion

Les mots de passe sont stockés dans le fichier `.env`.

Ce fichier ne doit jamais être ajouté au dépôt Git.

Le fichier `.env.exemple` peut servir de modèle sans contenir de véritables secrets.

## 9. Précautions

- Ne jamais supprimer manuellement le répertoire de données PostgreSQL sans sauvegarde.
- Ne pas relancer une initialisation de réplication sur un serveur déjà promu.
- Ne pas effectuer de bascule sans vérifier l'état de la réplication.
- Ne pas publier les mots de passe dans les scripts, les captures d'écran ou les dépôts.
- Vérifier les journaux PostgreSQL en cas d'échec.
