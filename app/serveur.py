
#!/usr/bin/env python3
"""
RÉSULTATS-BF
Serveur applicatif de consultation des résultats d'examen.
"""

import os
import socket

import psycopg2
from flask import Flask, jsonify, request


app = Flask(__name__)

# Configuration de la base de données.
DB_CONFIG = {
    # Les deux serveurs PostgreSQL, dans l'ordre de préférence.
    "host": os.environ["DB_HOSTS"],

    "port": int(os.environ.get("DB_PORT", "5432")),
    "dbname": os.environ.get("DB_NAME", "resultatsbf"),
    "user": os.environ.get("DB_USER", "resultats_app"),
    "password": os.environ.get("DB_PASSWORD", ""),

    # Accepter uniquement un serveur PostgreSQL principal.
    "target_session_attrs": "read-write",

    # Délai maximal de connexion par serveur.
    "connect_timeout": 3,
}


def obtenir_connexion():
    """Établit une connexion avec PostgreSQL."""
    return psycopg2.connect(**DB_CONFIG)


@app.route("/sante", methods=["GET"])
def sante():
    """
    Vérifie que l'application peut réellement communiquer
    avec la base de données.
    """
    connexion = None

    try:
        connexion = obtenir_connexion()

        with connexion.cursor() as curseur:
            curseur.execute("SELECT 1;")
            curseur.fetchone()

        return jsonify({
            "statut": "OK",
            "application": "resultats-bf",
            "base_de_donnees": "accessible"
        }), 200

    except psycopg2.Error:
        app.logger.exception("Échec de la vérification PostgreSQL.")

        return jsonify({
            "statut": "ERREUR",
            "application": "resultats-bf",
            "base_de_donnees": "indisponible"
        }), 503

    finally:
        if connexion is not None:
            connexion.close()


@app.route("/info", methods=["GET"])
def info():
    """Identifie le serveur qui traite la requête."""
    return jsonify({
        "application": "resultats-bf",
        "serveur": socket.gethostname()
    }), 200


@app.route("/resultat", methods=["GET"])
def resultat():
    """Recherche le résultat d'un candidat par son matricule."""

    matricule = request.args.get("matricule", "").strip()

    if not matricule:
        return jsonify({
            "erreur": "Le paramètre matricule est obligatoire."
        }), 400

    if len(matricule) > 20:
        return jsonify({
            "erreur": "Le matricule ne doit pas dépasser 20 caractères."
        }), 400

    connexion = None

    try:
        connexion = obtenir_connexion()

        with connexion.cursor() as curseur:
            curseur.execute(
                """
                SELECT matricule, nom, serie, moyenne, admis
                FROM resultats
                WHERE matricule = %s;
                """,
                (matricule,)
            )

            ligne = curseur.fetchone()

        if ligne is None:
            return jsonify({
                "erreur": "Aucun résultat trouvé pour ce matricule."
            }), 404

        return jsonify({
            "matricule": ligne[0],
            "nom": ligne[1],
            "serie": ligne[2],
            "moyenne": float(ligne[3]),
            "admis": ligne[4]
        }), 200

    except psycopg2.Error:
        app.logger.exception("Erreur lors de la recherche du résultat.")

        return jsonify({
            "erreur": "Le service de consultation est temporairement indisponible."
        }), 503

    finally:
        if connexion is not None:
            connexion.close()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000)
