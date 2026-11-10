
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

-- Génération de 50 000 candidats fictifs.
-- Les matricules vont de BF000001 à BF050000.
-- Les doublons sont ignorés lors des réexécutions.

WITH candidats AS (
    SELECT
        numero,
        ROUND((5 + RANDOM() * 15)::NUMERIC, 2) AS moyenne
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

-- Vérification du nombre total de résultats.
SELECT COUNT(*) AS nombre_total_resultats
FROM resultats;
