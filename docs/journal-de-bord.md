# Journal de bord — Membre 3 : Administration des bases de données

## Présentation de la mission

La mission du membre 3 porte sur la mise en place et l'administration de l'infrastructure PostgreSQL du projet RÉSULTATS-BF.

Les tâches principales sont :
- configurer le serveur PostgreSQL primaire ;
- préparer le serveur secondaire ;
- mettre en place la réplication ;
- préparer une procédure de bascule ;
- documenter les opérations et les vérifications.

## 1. Configuration du serveur primaire

Fichiers concernés :
- `scripts/bdd.sh`
- `sql/init.sql`

Travaux réalisés :
- configuration de l'installation de PostgreSQL ;
- création de la base `resultats` ;
- création des rôles `resultats_app` et `replicator` ;
- configuration des paramètres nécessaires à la réplication ;
- création de la table `resultats` ;
- insertion de 50 000 données de test.

Vérifications effectuées :
- PostgreSQL 16 installé sur bdd1 ;
- cluster PostgreSQL démarré ;
- paramètres `wal_level`, `max_wal_senders` et `max_connections` vérifiés ;
- présence de 50 000 enregistrements dans la table `resultats` ;
- règles d'accès réseau PostgreSQL corrigées manuellement sur bdd1.

## 2. Préparation de la réplication

Fichier concerné :
- `scripts/replique.sh`

Travaux réalisés :
- préparation du script d'installation du serveur secondaire ;
- configuration du mode standby ;
- préparation de la copie physique avec `pg_basebackup` ;
- préparation de l'authentification du compte `replicator` ;
- ajout de contrôles destinés à éviter l'écrasement d'un serveur déjà promu.

État :
- script créé et publié dans la branche `feature/replication` ;
- exécution complète et validation de la réplication encore à effectuer.

## 3. Préparation de la bascule

Fichier concerné :
- `scripts/bascule.sh`

Travaux réalisés :
- préparation d'une procédure de vérification du mode standby ;
- arrêt prévu de bdd1 ;
- promotion prévue de bdd2 avec `pg_promote` ;
- vérification prévue du nouveau rôle primaire ;
- ajout d'un marqueur permettant d'identifier un serveur promu.

État :
- script créé et publié dans la branche `feature/bascule` ;
- test réel de bascule non effectué ;
- redirection automatique des applications non encore intégrée.

## 4. Documentation

Fichiers documentés :
- `docs/procedures.md` : procédures d'administration et commandes de vérification ;
- `docs/journal-de-bord.md` : suivi des travaux ;
- `README.md` : présentation générale du projet.

## 5. Points restant à réaliser

- vérifier la configuration réseau et l'authentification entre bdd1 et bdd2 ;
- exécuter le provisionnement de bdd2 ;
- vérifier la présence des données répliquées ;
- contrôler l'état de réplication depuis bdd1 ;
- tester la continuité des données après une éventuelle bascule ;
- coordonner avec le membre chargé des applications pour la redirection vers le nouveau primaire ;
- effectuer les tests de panne et mesurer le temps de bascule ;
- mettre à jour ce journal avec les résultats réels des tests.

## 6. Branches Git utilisées

- `feature/bdd-primaire` : configuration du serveur primaire et initialisation SQL ;
- `feature/replication` : préparation de la réplication PostgreSQL ;
- `feature/bascule` : préparation de la procédure de bascule.

Les branches ont été publiées sur le dépôt distant du projet.

## 7. Vérifications de la réplication et des données — 18/11/2026

- Commande : `vagrant up`
  - Résultat : les cinq machines (bdd1, bdd2, app1, app2 et lb1) sont démarrées sans erreur bloquante.
  - HAProxy : configuration validée et service opérationnel sur lb1.
  - Note : bdd1, bdd2, app1 et app2 étaient déjà provisionnées ; seul lb1 a exécuté son provisionneur pendant cette commande.

- Commande : `vagrant ssh bdd2 -c "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery();'"`
  - Résultat : `t` — bdd2 est bien en mode standby/réplica.

- Commande : `vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -Atc 'SELECT COUNT(*) FROM resultats;'"`
  - Résultat : `50000` — 50 000 résultats sont présents sur bdd1.

- Réserve : le test de bascule effective et le contrôle explicite de l'état `streaming` de la réplication restent à réaliser.
