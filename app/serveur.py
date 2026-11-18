#!/usr/bin/env python3
import os, json, socket, base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import psycopg2
from contextlib import closing

DB = {
    "host": os.environ["DB_HOST"],
    "port": int(os.getenv("DB_PORT", "5432")),
    "dbname": os.getenv("DB_NAME", "resultats"),
    "user": os.getenv("DB_USER", "resultats_app"),
    "password": base64.b64decode(os.environ["DB_PASSWORD_B64"]).decode(),
    "connect_timeout": 2
}

class Handler(BaseHTTPRequestHandler):
    def reply(self, status, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path)
        if path.path == "/info":
            return self.reply(200, {"hostname": socket.gethostname()})
        if path.path == "/sante":
            try:
                with closing(psycopg2.connect(**DB)) as conn:
                    with conn.cursor() as cur:
                        cur.execute("SELECT 1")
                return self.reply(200, {"etat": "OK", "base": "accessible"})
            except Exception:
                return self.reply(503, {"etat": "INDISPONIBLE", "base": "inaccessible"})
        if path.path == "/resultat":
            matricule = parse_qs(path.query).get("matricule", [""])[0]
            if not matricule:
                return self.reply(400, {"erreur": "Matricule obligatoire"})
            try:
                with closing(psycopg2.connect(**DB)) as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT matricule, nom, serie, moyenne, admis "
                            "FROM resultats WHERE matricule = %s", (matricule,))
                        row = cur.fetchone()
                if not row:
                    return self.reply(404, {"erreur": "Candidat introuvable"})
                return self.reply(200, {
                    "matricule": row[0], "nom": row[1], "serie": row[2],
                    "moyenne": float(row[3]), "admis": row[4]
                })
            except Exception:
                return self.reply(503, {"erreur": "Base de données indisponible"})
        return self.reply(404, {"erreur": "Route inconnue"})

ThreadingHTTPServer(("0.0.0.0", 3000), Handler).serve_forever()
