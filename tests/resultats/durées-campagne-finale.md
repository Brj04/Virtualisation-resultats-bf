# Campagne finale, poste de Roukia (Windows, PowerShell, VirtualBox 7.2.20, Vagrant 2.4.9)

| Scénario | Résultat mesuré |
| --- | --- |
| V1 | 10/10 réponses réparties entre app1 et app2 |
| V2 | 20/20 réponses 200 avec app1 arrêtée |
| V3 | 100/100 en 5,478 s (18,25 req/s, 4 ms en moyenne, requêtes séquentielles) |
| V4 | /sante renvoie 503 pendant la panne ; bascule en mode panne en 59 s (mesure précédente : 78 s) ; ensuite 200/200 avec des données identiques |
| V5 | reconstruction complète en 23 min 03 s (mesure précédente : 20 min 21 s) ; script V5 : SUCCES, preuve de Roukia du 25/11 |
| V6 | 200 avant la panne, pendant la panne (lb1 arrêté, lb2 prend l'IP virtuelle) et après le retour |

Les scripts de test sont ceux de Roukia (PR #17). La campagne a été exécutée sur la machine de René.
