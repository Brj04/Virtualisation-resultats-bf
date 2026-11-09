#!/usr/bin/env python3
"""Service RÉSULTATS-BF — sans état : tout l'état vit dans la base."""
import json, os, socket, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from psycopg2 import pool

DSN = dict(host=os.environ["DB_HOST"], dbname=os.environ["DB_NAME"],
           user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
           connect_timeout=2, tcp_user_timeout=3000,
           keepalives=1, keepalives_idle=1, keepalives_interval=1, keepalives_count=2)
MAX = 30
_sem, _lock, _pool = threading.BoundedSemaphore(MAX), threading.Lock(), None


def get_pool():
    """Pool créé à la demande : l'app démarre même si la base est absente."""
    global _pool
    with _lock:
        if _pool is None:
            _pool = pool.ThreadedConnectionPool(1, MAX, **DSN)
        return _pool


def requete(sql, params=()):
    """Lit la base ; lève une exception si elle est injoignable."""
    with _sem:
        p = get_pool()
        conn = p.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(sql, params)
                rows = cur.fetchall()
            conn.rollback()
            p.putconn(conn)
            return rows
        except Exception:
            p.putconn(conn, close=True)
            raise


class Serveur(ThreadingHTTPServer):
    request_queue_size = 128


class H(BaseHTTPRequestHandler):
    def reponse(self, code, obj):
        corps = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        u = urlparse(self.path)
        try:
            if u.path == "/sante":                    # sonde du répartiteur
                requete("SELECT 1")
                self.reponse(200, {"statut": "ok"})
            elif u.path == "/info":                   # observe la répartition
                self.reponse(200, {"hote": socket.gethostname()})
            elif u.path == "/resultat":
                m = parse_qs(u.query).get("matricule", [""])[0]
                if not m:
                    return self.reponse(400, {"erreur": "paramètre matricule manquant"})
                rows = requete("SELECT matricule, nom, serie, moyenne, admis "
                               "FROM resultats WHERE matricule = %s", (m,))
                if not rows:
                    return self.reponse(404, {"erreur": "matricule inconnu"})
                r = rows[0]
                self.reponse(200, {"matricule": r[0], "nom": r[1], "serie": r[2],
                                   "moyenne": float(r[3]), "admis": r[4]})
            else:
                self.reponse(404, {"erreur": "route inconnue"})
        except Exception:                             # base KO : 503 propre
            self.reponse(503, {"erreur": "base de données indisponible"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    Serveur(("0.0.0.0", int(os.environ.get("PORT", "3000"))), H).serve_forever()
