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

Le script `scripts/bascule.sh` promeut bdd2 en nouveau serveur primaire. Il se lance depuis le poste hôte, à la racine du projet, et fonctionne selon deux modes. La bascule est toujours **manuelle** : rien ne se déclenche automatiquement en cas de panne.

### Connexion des applications à la base

Les serveurs applicatifs ne passent pas par HAProxy pour joindre PostgreSQL. Chaque application se connecte **directement** à la base désignée par la variable `DB_HOST` du fichier `/etc/resultats.env`. Au démarrage, `DB_HOST` vaut l'adresse de bdd1. HAProxy (`lb1`) ne répartit que les requêtes HTTP entre les serveurs applicatifs.

Pour basculer, le script change `DB_HOST` vers l'adresse de bdd2 sur chaque serveur applicatif, puis redémarre le service systemd `resultats`.

### Mode planifié (bdd1 fonctionne)

À utiliser pour une opération de maintenance, quand bdd1 est saine.

```bash
bash scripts/bascule.sh
```

Étapes :

1. vérifier que bdd1 est primaire et bdd2 sa réplique ;
2. vérifier que la réplication est en streaming ;
3. arrêter temporairement les applications ;
4. relever la dernière position WAL de bdd1, puis arrêter bdd1 ;
5. attendre que bdd2 ait rejoué cette position (aucune écriture perdue) ;
6. promouvoir bdd2 avec `pg_promote`, puis créer le marqueur de promotion ;
7. changer `DB_HOST`, redémarrer les applications et vérifier HAProxy et les applications.

Durée mesurée : 105 secondes, avec des données identiques avant et après.

### Mode panne (bdd1 est tombée)

À utiliser quand bdd1 est déjà arrêtée ou injoignable. Le script ne peut pas lui parler : il saute les étapes qui dépendent de bdd1.

```bash
vagrant halt bdd1        # si bdd1 n'est pas déjà éteinte
bash scripts/bascule.sh --panne --confirme-bdd1-arretee
```

- L'option `--confirme-bdd1-arretee` est obligatoire : on affirme que bdd1 est éteinte. Sans elle, le script refuse de démarrer.
- Si bdd1 répond encore comme primaire, le script refuse aussi, pour ne jamais avoir deux primaires.
- Le script attend que bdd2 rejoue les journaux déjà reçus, puis la promeut et redirige les applications comme en mode planifié.

**Limite :** les écritures validées sur bdd1 mais pas encore reçues par bdd2 au moment de la panne sont perdues.

### Après une bascule

- bdd2 est le primaire. bdd1 ne doit **pas** être redémarrée telle quelle : elle contient un état ancien et deviendrait un second primaire.
-bdd1 doit être reconstruite comme réplique de bdd2 ; cette étape n'est pas automatisée (limite connue).
- Le marqueur `/var/lib/postgresql/.resultats-bdd2-promoted` sur bdd2 empêche de relancer le provisionnement de la réplique sur un serveur déjà promu.



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
