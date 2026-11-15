
-- ==========================================================
-- RÉSULTATS-BF
-- Initialisation de la table des résultats d'examen
-- 50 000 candidats fictifs pour les tests
-- ==========================================================

CREATE TABLE IF NOT EXISTS resultats (
    matricule VARCHAR(20) PRIMARY KEY,
    nom       VARCHAR(100) NOT NULL,
    serie     VARCHAR(10) NOT NULL,
    moyenne   NUMERIC(4,2) NOT NULL
              CHECK (moyenne >= 0 AND moyenne <= 20),
    admis     BOOLEAN NOT NULL
);

-- Génération déterministe de 50 000 candidats fictifs.
-- ON CONFLICT évite les doublons si le script est rejoué.

INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
SELECT
    'BF2026-' || LPAD(g::TEXT, 6, '0'),
    'Candidat ' || LPAD(g::TEXT, 5, '0'),
    CASE
        WHEN g % 3 = 0 THEN 'A4'
        WHEN g % 3 = 1 THEN 'C'
        ELSE 'D'
    END,
    score.moyenne,
    score.moyenne >= 10
FROM generate_series(1, 50000) AS g
CROSS JOIN LATERAL (
    SELECT ((g * 37) % 2001)::NUMERIC / 100 AS moyenne
) AS score
ON CONFLICT (matricule) DO NOTHING;

-- Vérification du nombre de résultats disponibles.
SELECT COUNT(*) AS nombre_resultats
FROM resultats;
