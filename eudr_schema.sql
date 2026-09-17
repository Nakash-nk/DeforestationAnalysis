-- =====================================================================
--  ANALYSE DE CONFORMITE EUDR - PLANTEURS CAFE & CACAO (RDC)
--  Schéma MySQL 8.0+  |  Virunga Coffee Company
--
--  PREREQUIS : MySQL >= 8.0  ->  SELECT VERSION();
--  SRID 4326 = WGS84 (stockage + export GeoJSON/DDS)
--  SRID 32735 = WGS 84 / UTM zone 35S (tous les calculs métriques)
--
--  RAPPEL AXES : en SRID 4326 MySQL attend lat-long.
--  Toujours utiliser ST_GeomFromText(wkt, 4326, 'axis-order=long-lat')
-- =====================================================================

CREATE DATABASE IF NOT EXISTS eudr
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE eudr;


-- ---------------------------------------------------------------------
-- 1. REFERENTIEL PLANTEURS
-- ---------------------------------------------------------------------

CREATE TABLE planteur (
  id                BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  olam_farmer_id    VARCHAR(64)  NOT NULL,          -- clé de rapprochement (100% remplie)
  farmer_code       VARCHAR(64)  NULL,              -- peu fiable, à titre indicatif
  nom               VARCHAR(255) NOT NULL,
  sexe              ENUM('M','F','NC') DEFAULT 'NC',
  filiere           ENUM('CAFE_ARABICA','CAFE_ROBUSTA','CACAO') NOT NULL,
  cooperative       VARCHAR(255) NULL,
  village           VARCHAR(255) NULL,
  axe               VARCHAR(255) NULL,
  subdistrict       VARCHAR(255) NULL,
  district          VARCHAR(255) NULL,
  region            VARCHAR(255) NULL,
  actif             TINYINT(1)   NOT NULL DEFAULT 1,
  cree_le           DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  maj_le            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uk_planteur_olam (olam_farmer_id, filiere),
  KEY idx_planteur_axe (axe),
  KEY idx_planteur_nom (nom)
) ENGINE=InnoDB;


-- ---------------------------------------------------------------------
-- 2. PARCELLES
--    geom      : géométrie officielle WGS84 (point OU polygone)
--    geom_utm  : même géométrie projetée, calculée par PHP à l'insertion
--    geom_prud : cercle prudentiel (points uniquement) pour l'analyse
--                de risque -- JAMAIS soumis dans une DDS
-- ---------------------------------------------------------------------

CREATE TABLE parcelle (
  id                    BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  planteur_id           BIGINT UNSIGNED NOT NULL,
  ref_parcelle          VARCHAR(64)  NULL,          -- code interne si existant
  filiere               ENUM('CAFE_ARABICA','CAFE_ROBUSTA','CACAO') NOT NULL,
  type_geo              ENUM('POINT','POLYGONE') NOT NULL,

  latitude              DECIMAL(12,8) NULL,         -- >= 6 décimales exigées
  longitude             DECIMAL(12,8) NULL,
  nb_decimales_lat      TINYINT UNSIGNED NULL,      -- rempli par le contrôle A01
  nb_decimales_lon      TINYINT UNSIGNED NULL,

  superficie_declaree   DECIMAL(10,4) NULL,         -- ha, source terrain
  superficie_calculee   DECIMAL(10,4) NULL,         -- ha, ST_Area(geom_utm)/10000

  geom                  GEOMETRY SRID 4326 NOT NULL,
  geom_utm              GEOMETRY SRID 32735 NOT NULL,
  geom_prud             POLYGON  SRID 32735 NULL,   -- cercle r = sqrt(A/pi)

  geo_id                VARCHAR(128) NULL,          -- GeoID retourné par Whisp
  source_fichier        VARCHAR(255) NULL,          -- Coffee_EUDR.xlsx, etc.
  enumerateur           VARCHAR(255) NULL,          -- compte rattaché à la fiche
  surveyed_by           VARCHAR(255) NULL,          -- agent de terrain réel
  date_collecte         DATE NULL,
  annee_campagne        SMALLINT UNSIGNED NULL,

  statut_global         ENUM('CONFORME','A_VERIFIER','NON_CONFORME','NON_ANALYSE')
                        NOT NULL DEFAULT 'NON_ANALYSE',
  cree_le               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  maj_le                DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,

  CONSTRAINT fk_parcelle_planteur FOREIGN KEY (planteur_id)
    REFERENCES planteur(id) ON DELETE CASCADE,
  SPATIAL INDEX sx_parcelle_geom (geom),
  SPATIAL INDEX sx_parcelle_utm  (geom_utm),
  KEY idx_parcelle_statut (statut_global),
  KEY idx_parcelle_type (type_geo),
  KEY idx_parcelle_geoid (geo_id)
) ENGINE=InnoDB;


-- ---------------------------------------------------------------------
-- 3. COUCHES DE REFERENCE
--    Chargées une fois (WDPA pour les aires protégées, OSM pour hydro
--    et routes). Doublon 4326 / 32735 pour la même raison.
-- ---------------------------------------------------------------------

CREATE TABLE ref_aire_protegee (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  wdpa_id       VARCHAR(64)  NULL,
  nom           VARCHAR(255) NOT NULL,              -- Virunga, Maiko, Kahuzi-Biega...
  designation   VARCHAR(255) NULL,                  -- parc national, réserve, domaine de chasse
  iucn_cat      VARCHAR(16)  NULL,
  geom          GEOMETRY SRID 4326  NOT NULL,
  geom_utm      GEOMETRY SRID 32735 NOT NULL,
  SPATIAL INDEX sx_ap_geom (geom),
  SPATIAL INDEX sx_ap_utm  (geom_utm)
) ENGINE=InnoDB;

CREATE TABLE ref_hydro (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  nom           VARCHAR(255) NULL,                  -- lac Kivu, lac Edouard, rivières
  type_hydro    VARCHAR(64)  NULL,
  geom          GEOMETRY SRID 4326  NOT NULL,
  geom_utm      GEOMETRY SRID 32735 NOT NULL,
  SPATIAL INDEX sx_hydro_geom (geom),
  SPATIAL INDEX sx_hydro_utm  (geom_utm)
) ENGINE=InnoDB;

CREATE TABLE ref_route (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  nom           VARCHAR(255) NULL,
  classe        VARCHAR(64)  NULL,                  -- trunk, primary, secondary...
  emprise_m     SMALLINT UNSIGNED NOT NULL DEFAULT 20, -- demi-largeur du tampon
  geom          GEOMETRY SRID 4326  NOT NULL,
  geom_utm      GEOMETRY SRID 32735 NOT NULL,
  SPATIAL INDEX sx_route_geom (geom),
  SPATIAL INDEX sx_route_utm  (geom_utm)
) ENGINE=InnoDB;


-- ---------------------------------------------------------------------
-- 4. CATALOGUE DE CONTROLES
--    bloc A = recevabilité EUDR      -> bloque la DDS
--    bloc B = plausibilité / fraude  -> mission terrain
--    bloc C = déforestation Art.3(a) -> rejet du lot
--    bloc D = légalité Art.3(b)      -> rejet, à instruire
-- ---------------------------------------------------------------------

CREATE TABLE controle (
  code          VARCHAR(8)   PRIMARY KEY,
  bloc          ENUM('A','B','C','D') NOT NULL,
  libelle       VARCHAR(255) NOT NULL,
  motif_terrain TEXT NULL,                          -- phrase lisible par l'agronome
  severite      ENUM('BLOQUANT','MAJEUR','MINEUR','INFO') NOT NULL,
  actif         TINYINT(1) NOT NULL DEFAULT 1
) ENGINE=InnoDB;

INSERT INTO controle (code, bloc, libelle, severite, motif_terrain) VALUES
-- Bloc A : recevabilité
('A01','A','Coordonnees manquantes ou hors emprise RDC','BLOQUANT',
  'Le point GPS est absent ou situe hors de la RDC. Reprendre le releve.'),
('A02','A','Precision insuffisante (< 6 decimales)','BLOQUANT',
  'Le GPS n a pas ete enregistre avec assez de decimales. Reprendre avec un appareil regle en degres decimaux.'),
('A03','A','Parcelle > 4 ha declaree avec un simple point','BLOQUANT',
  'Cette parcelle depasse 4 ha : le polygone est obligatoire. Programmer une mission de polygonage.'),
('A04','A','Polygone invalide (auto-intersection, < 4 sommets, non ferme)','BLOQUANT',
  'Le trace du champ se recoupe ou est incomplet. Refaire le tour de la parcelle.'),
('A05','A','Ecart superficie declaree / calculee hors tolerance','MAJEUR',
  'La superficie declaree ne correspond pas au trace. Verifier avec le planteur.'),
('A06','A','Forme aberrante (pic, sommets alignes)','MAJEUR',
  'Le trace presente une forme anormale. Verifier le releve sur le terrain.'),
-- Bloc B : plausibilité et fraude
('B01','B','Chevauchement avec une autre parcelle','MAJEUR',
  'Ce champ se superpose a celui d un autre planteur. Arbitrage terrain necessaire.'),
('B02','B','Point GPS a l interieur du polygone d un autre planteur','MAJEUR',
  'Le point tombe dans le champ deja trace d un autre planteur.'),
('B03','B','Points distincts trop proches','MINEUR',
  'Deux parcelles declarees quasiment au meme endroit. Verifier s il ne s agit pas du meme champ.'),
('B04','B','Doublon inter-filiere cafe / cacao','MAJEUR',
  'Le meme champ semble declare a la fois en cafe et en cacao. Verifier la double declaration.'),
('B05','B','Parcelle situee dans un plan d eau','BLOQUANT',
  'Le GPS tombe dans un lac ou une riviere : le releve est faux. Reprendre le point.'),
('B06','B','Parcelle situee sur une emprise routiere','MAJEUR',
  'Le GPS a probablement ete pris depuis la route. Reprendre le point au centre du champ.'),
('B07','B','Coordonnees strictement identiques a une autre fiche','MAJEUR',
  'Le meme GPS a ete saisi sur plusieurs fiches. Verifier la saisie.'),
-- Bloc C : déforestation (via Whisp)
('C01','C','Perte de couvert forestier apres le 31/12/2020','BLOQUANT',
  'Perte forestiere detectee apres la date butoir EUDR. Instruire le dossier avant tout achat.'),
('C02','C','Alerte de perturbation recente (RADD)','MAJEUR',
  'Perturbation recente detectee. Verifier la nature du changement sur le terrain.'),
('C03','C','Risque Whisp classe "more info needed"','MAJEUR',
  'Les couches satellites ne permettent pas de trancher. Complement d information requis.'),
-- Bloc D : légalité
('D01','D','Intersection avec une aire protegee','BLOQUANT',
  'La parcelle empiete sur une aire protegee. Verifier le statut foncier aupres de l ICCN.'),
('D02','D','Parcelle a proximite immediate d une aire protegee','MINEUR',
  'La parcelle jouxte une aire protegee. Verifier la limite exacte.');


-- ---------------------------------------------------------------------
-- 5. RESULTATS D'ANALYSE
-- ---------------------------------------------------------------------

CREATE TABLE analyse_run (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  lance_le      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  lance_par     VARCHAR(128) NULL,
  perimetre     VARCHAR(255) NULL,                  -- ex : "cacao / axe Beni"
  nb_parcelles  INT UNSIGNED NULL,
  parametres    JSON NULL,                          -- copie des seuils utilises
  termine_le    DATETIME NULL
) ENGINE=InnoDB;

CREATE TABLE resultat_controle (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  run_id        BIGINT UNSIGNED NOT NULL,
  parcelle_id   BIGINT UNSIGNED NOT NULL,
  controle_code VARCHAR(8) NOT NULL,
  declenche     TINYINT(1) NOT NULL,
  valeur_num    DECIMAL(14,4) NULL,                 -- % chevauchement, ha perdus, distance m...
  detail        JSON NULL,                          -- contexte : id parcelle opposee, nom du parc...
  CONSTRAINT fk_res_run  FOREIGN KEY (run_id)      REFERENCES analyse_run(id) ON DELETE CASCADE,
  CONSTRAINT fk_res_parc FOREIGN KEY (parcelle_id) REFERENCES parcelle(id)    ON DELETE CASCADE,
  CONSTRAINT fk_res_ctrl FOREIGN KEY (controle_code) REFERENCES controle(code),
  KEY idx_res_parc (parcelle_id, declenche),
  KEY idx_res_run  (run_id, controle_code)
) ENGINE=InnoDB;

-- Table dédiée : un chevauchement est une relation, pas un attribut
CREATE TABLE chevauchement (
  id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  run_id          BIGINT UNSIGNED NOT NULL,
  parcelle_a      BIGINT UNSIGNED NOT NULL,
  parcelle_b      BIGINT UNSIGNED NOT NULL,
  type_relation   ENUM('POLY_POLY','POINT_DANS_POLY','CERCLE_CERCLE') NOT NULL,
  surface_commune DECIMAL(10,4) NULL,               -- ha
  pct_a           DECIMAL(6,2)  NULL,
  pct_b           DECIMAL(6,2)  NULL,
  meme_planteur   TINYINT(1) NOT NULL DEFAULT 0,
  meme_filiere    TINYINT(1) NOT NULL DEFAULT 0,
  arbitrage       ENUM('EN_ATTENTE','A_CONSERVE','B_CONSERVE','FUSION','LES_DEUX_OK')
                  NOT NULL DEFAULT 'EN_ATTENTE',
  note_terrain    TEXT NULL,
  CONSTRAINT fk_chv_run FOREIGN KEY (run_id)     REFERENCES analyse_run(id) ON DELETE CASCADE,
  CONSTRAINT fk_chv_a   FOREIGN KEY (parcelle_a) REFERENCES parcelle(id)    ON DELETE CASCADE,
  CONSTRAINT fk_chv_b   FOREIGN KEY (parcelle_b) REFERENCES parcelle(id)    ON DELETE CASCADE,
  UNIQUE KEY uk_chv (run_id, parcelle_a, parcelle_b, type_relation)
) ENGINE=InnoDB;


-- ---------------------------------------------------------------------
-- 6. CACHE WHISP
--    Une parcelle inchangee ne doit JAMAIS etre re-interrogee.
--    geom_hash = SHA1 du WKT normalise -> invalidation automatique
--    si la geometrie change.
-- ---------------------------------------------------------------------

CREATE TABLE whisp_cache (
  id                BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  parcelle_id       BIGINT UNSIGNED NOT NULL,
  geom_hash         CHAR(40) NOT NULL,
  geo_id            VARCHAR(128) NULL,
  risk_pcrop        VARCHAR(32) NULL,               -- low / high / more_info_needed
  risk_acrop        VARCHAR(32) NULL,
  treecover_2020    DECIMAL(8,4) NULL,              -- % ou ha selon le champ retenu
  perte_post_2020   DECIMAL(10,4) NULL,             -- ha
  payload           JSON NOT NULL,                  -- reponse brute, pour l audit
  interroge_le      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_whisp_parc FOREIGN KEY (parcelle_id) REFERENCES parcelle(id) ON DELETE CASCADE,
  UNIQUE KEY uk_whisp_hash (parcelle_id, geom_hash)
) ENGINE=InnoDB;


-- ---------------------------------------------------------------------
-- 7. PARAMETRES (seuils modifiables sans toucher au code)
-- ---------------------------------------------------------------------

CREATE TABLE parametre (
  cle         VARCHAR(64) PRIMARY KEY,
  valeur      VARCHAR(255) NOT NULL,
  unite       VARCHAR(32)  NULL,
  description VARCHAR(255) NULL
) ENGINE=InnoDB;

INSERT INTO parametre (cle, valeur, unite, description) VALUES
('seuil_polygone_ha',        '4',     'ha', 'Au-dela, le polygone est obligatoire (EUDR art. 9)'),
('date_butoir',              '2020-12-31', NULL, 'Date butoir de non-deforestation EUDR'),
('decimales_min',            '6',     NULL, 'Nombre minimal de decimales exigees'),
('tol_superficie_pct',       '20',    '%',  'Ecart tolere entre superficie declaree et calculee'),
('tol_superficie_abs_ha',    '0.05',  'ha', 'Ecart absolu tolere en dessous duquel on ne signale rien'),
('seuil_chevauchement_pct',  '5',     '%',  'Chevauchement minimal signale'),
('dist_min_points_m',        '30',    'm',  'Distance minimale entre deux points distincts'),
('emprise_route_m',          '20',    'm',  'Demi-largeur du tampon routier'),
('buffer_aire_protegee_m',   '500',   'm',  'Distance d alerte de proximite d une aire protegee'),
('emprise_rdc_lat_min',      '-13.5', 'deg', NULL),
('emprise_rdc_lat_max',      '5.4',   'deg', NULL),
('emprise_rdc_lon_min',      '12.2',  'deg', NULL),
('emprise_rdc_lon_max',      '31.4',  'deg', NULL);


-- ---------------------------------------------------------------------
-- 8. VUES DE RESTITUTION
-- ---------------------------------------------------------------------

-- Fiche de non-conformite par parcelle (base de l export Excel et Power BI)
CREATE OR REPLACE VIEW v_non_conformites AS
SELECT
  p.axe, p.subdistrict, p.village,
  p.olam_farmer_id, p.nom AS planteur, p.filiere,
  pa.id AS parcelle_id, pa.type_geo,
  pa.superficie_declaree, pa.superficie_calculee,
  pa.statut_global,
  c.bloc, c.code AS controle, c.libelle, c.severite, c.motif_terrain,
  r.valeur_num, r.detail,
  pa.surveyed_by, pa.date_collecte, r.run_id
FROM resultat_controle r
JOIN parcelle  pa ON pa.id = r.parcelle_id
JOIN planteur  p  ON p.id  = pa.planteur_id
JOIN controle  c  ON c.code = r.controle_code
WHERE r.declenche = 1;

-- Synthese par axe : le tableau que le Country Director veut voir
CREATE OR REPLACE VIEW v_synthese_axe AS
SELECT
  p.filiere, p.axe,
  COUNT(DISTINCT pa.id)                                          AS nb_parcelles,
  SUM(pa.statut_global = 'CONFORME')                             AS nb_conformes,
  SUM(pa.statut_global = 'A_VERIFIER')                           AS nb_a_verifier,
  SUM(pa.statut_global = 'NON_CONFORME')                         AS nb_non_conformes,
  SUM(pa.type_geo = 'POINT' AND pa.superficie_declaree > 4)      AS nb_polygonage_requis,
  ROUND(SUM(pa.superficie_declaree), 2)                          AS ha_declares
FROM parcelle pa
JOIN planteur p ON p.id = pa.planteur_id
GROUP BY p.filiere, p.axe;
