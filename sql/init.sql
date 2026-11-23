-- =========================================================
-- PROJET : RESULTATS-BF
-- MEMBRE 3 : INGENIEUR DONNEES
-- FICHIER : sql/init.sql
-- OBJECTIF : Creer et initialiser 50 000 resultats scolaires
-- =========================================================

CREATE TABLE IF NOT EXISTS resultats (
    matricule VARCHAR(20) PRIMARY KEY,
    nom VARCHAR(100) NOT NULL,
    serie VARCHAR(20) NOT NULL,
    moyenne NUMERIC(4,2) NOT NULL
        CHECK (moyenne >= 0 AND moyenne <= 20),
    admis BOOLEAN NOT NULL
);

-- Autoriser l'application a consulter les resultats.
GRANT SELECT ON resultats TO resultats_app;

-- Generation deterministe de 50 000 candidats fictifs.
-- Les matricules vont de BF000001 a BF050000.
-- Les moyennes restent identiques apres chaque reconstruction.
-- Les doublons sont ignores lors des reexecutions.

WITH candidats AS (
    SELECT
        numero,
        ROUND((((numero * 7919) % 1501) / 100.0 + 5)::NUMERIC, 2) AS moyenne
    FROM GENERATE_SERIES(1, 50000) AS numeros(numero)
)
INSERT INTO resultats (
    matricule,
    nom,
    serie,
    moyenne,
    admis
)
SELECT
    'BF' || LPAD(numero::TEXT, 6, '0'),
    'CANDIDAT_' || numero,
    CASE
        WHEN numero % 3 = 0 THEN 'A'
        WHEN numero % 3 = 1 THEN 'C'
        ELSE 'D'
    END,
    moyenne,
    moyenne >= 10
FROM candidats
ON CONFLICT (matricule) DO NOTHING;

-- Verification du nombre total de resultats.
SELECT COUNT(*) AS nombre_total_resultats
FROM resultats;