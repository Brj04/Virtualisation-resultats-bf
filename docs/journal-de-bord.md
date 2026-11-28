# Journal de bord — groupe 8, RÉSULTATS-BF


## Novembre — BELEM (service applicatif)

Écriture du service HTTP Python sans état : `/sante` (vérifie la base avec un `SELECT 1`, répond 200 ou 503),
`/info` (nom de la machine qui répond) et `/resultat?matricule=` (résultat d'un candidat en JSON).
Le service lit sa configuration dans `/etc/resultats.env`, ce qui permet d'ajouter des serveurs applicatifs
sans toucher au code.

## Novembre — Laurentine (données, réplication, bascule)

Mise en place de PostgreSQL sur `bdd1` (schéma et 50 000 candidats d'essai), de la réplication en flux vers `bdd2`,
et du script `bascule.sh` (mode planifié et mode panne). La bascule réécrit la cible de la base sur les serveurs
applicatifs.  


## 25-26 novembre — Roukia

Correction des scripts V1 à V4, ajout du V5 (reconstruction) et du V6 (panne du répartiteur), avec leurs preuves.
Difficulté : les scripts devaient marcher sous Windows et sous Linux (`py -3` contre `python3`). Elle a ajouté
une détection automatique de l'interpréteur Python.


## 26 novembre — René

J'ai relu et testé sur ma machine (Arch Linux, VirtualBox 7.2, Vagrant 2.4.9) les scripts de Roukia :
V1, V2, V3, V4 et V6 passent. La preuve V5 (reconstruction, SUCCES) a été produite par Roukia le 25/11 ;
de mon côté, j'ai mesuré la reconstruction complète en 23 min 03 s. Autres mesures : V3 100/100 en 5,5 s ;
bascule de la base en 59 s après panne ; avec `lb1` arrêté, `lb2` reprend l'adresse virtuelle
(200 avant, pendant et après).
J'ai poussé sur la branche de Roukia un commit de nettoyage (preuve V4 en un seul fichier, lignes vides
retirées, anciennes preuves obsolètes supprimées). La campagne finale a été exécutée sur ma machine
avec ses scripts ; Roukia pousse les preuves.


## Bilan du groupe

La plateforme se reconstruit entièrement avec `vagrant destroy -f && vagrant up` (environ 20 à 25 minutes).
Les scénarios V1 à V6 sont validés avec des preuves dans `tests/resultats`. Limites connues : bascule de la base
manuelle, écritures non répliquées perdues en cas de panne, et page 503 de HAProxy pendant la panne de la base.
Extensions réalisées : E1 (lb2 et IP virtuelle) et E2 (Prometheus et Grafana).
