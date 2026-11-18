# DOSSIER D'ARCHITECTURE – PROJET RÉSULTATS-BF

## 1. Présentation générale

Le projet RÉSULTATS-BF vise à mettre en place une infrastructure virtualisée permettant d'héberger une application de consultation des résultats scolaires.

L'architecture repose sur plusieurs machines virtuelles configurées avec Vagrant et VirtualBox.

## 2. Architecture générale

L'infrastructure comprend :

- bdd1 : serveur PostgreSQL primaire ;
- bdd2 : serveur PostgreSQL secondaire et réplique ;
- app1 : premier serveur applicatif ;
- app2 : deuxième serveur applicatif ;
- lb1 : répartiteur de charge HAProxy.

## 3. Architecture de la base de données

La base de données utilisée est `resultats`.

Elle contient notamment la table `resultats`, destinée à stocker les informations des candidats et leurs résultats.

PostgreSQL est utilisé sur les deux serveurs de base de données.

## 4. Réplication PostgreSQL

bdd1 joue initialement le rôle de serveur primaire.

bdd2 fonctionne en mode secondaire et reçoit les journaux WAL du serveur primaire.

La réplication permet de disposer d'une copie des données sur un deuxième serveur afin de faciliter une opération de bascule.

L'état de la réplication peut être contrôlé à partir des vues statistiques PostgreSQL, notamment `pg_stat_replication` et `pg_stat_wal_receiver`.

## 5. Couche applicative

Les serveurs app1 et app2 hébergent chacun une instance de l'application.

Les applications utilisent PostgreSQL pour accéder aux données et passent par lb1 pour leurs connexions à la base de données.

Le service systemd utilisé est `resultats`. Son unité est `/etc/systemd/system/resultats.service` et sa configuration est stockée dans `/etc/resultats.env`.

## 6. Répartition de charge et accès à PostgreSQL

HAProxy assure deux fonctions principales :

- répartir les requêtes HTTP entre les serveurs applicatifs ;
- orienter les connexions PostgreSQL vers le serveur primaire.

Le script `check_pg_primary.sh` effectue un contrôle externe en interrogeant PostgreSQL.

Il utilise la fonction `pg_is_in_recovery()` pour déterminer si le serveur interrogé est en mode récupération. Le serveur qui n'est plus en récupération peut être identifié comme primaire.

## 7. Procédure de bascule

La bascule de bdd1 vers bdd2 est déclenchée manuellement à l'aide de `scripts/bascule.sh`.

Le script vérifie notamment l'état des deux serveurs, la réplication, la position WAL, puis arrête bdd1 avant de promouvoir bdd2.

### Redirection des connexions PostgreSQL

Avant la bascule, les applications utilisent HAProxy (`lb1`) comme adresse de connexion à PostgreSQL.

Après la promotion de bdd2, le script `scripts/bascule.sh` met à jour directement la variable `DB_HOST` dans `/etc/resultats.env` sur chaque serveur applicatif. Cette variable reçoit l'adresse IP de bdd2, puis le service systemd `resultats` est redémarré afin que l'application utilise le nouveau serveur primaire.

Le contrôle externe `check_pg_primary.sh` interroge les serveurs PostgreSQL à l'aide de `pg_is_in_recovery()`. HAProxy peut ainsi identifier le serveur qui n'est plus en mode récupération et lui diriger les connexions qui passent par lui.

La redirection des applications et la continuité du service doivent être vérifiées lors des tests de bascule.




## 8. Limites et perspectives

L'architecture présente les limites suivantes :

- la bascule de bdd1 vers bdd2 est manuelle et n'est pas déclenchée automatiquement en cas de panne ;
- aucune bascule retour automatique vers bdd1 n'est prévue après la promotion de bdd2 ;
- une intervention et des vérifications sont nécessaires avant toute nouvelle opération de bascule ;
- la détection du nouveau primaire par HAProxy doit être validée par des tests réels après promotion ;
- les connexions déjà établies peuvent être interrompues pendant la bascule et nécessiter une reconnexion des applications.

Pour améliorer cette architecture, plusieurs perspectives peuvent être envisagées : automatisation contrôlée de la détection des pannes, supervision renforcée, sauvegardes régulières, tests périodiques de restauration et mécanisme sécurisé de réintégration de l'ancien serveur primaire.
