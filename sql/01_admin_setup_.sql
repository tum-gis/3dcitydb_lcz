-- ================================================================
-- 01_admin_setup.sql 
-- One-time setup of the "lcz" schema and all empty tables/views.
-- Schema-agnostic: automatically detects the 3D CityDB schema.
-- Run ONCE by a database administrator.
-- ================================================================

-- Set the search path dynamically based on the schema containing the 'feature' table.
DO $$
DECLARE
    citydb_schema text;
BEGIN
    SELECT table_schema INTO citydb_schema
    FROM information_schema.tables
    WHERE table_name = 'feature'
      AND table_schema NOT IN ('information_schema', 'pg_catalog', 'lcz')
    LIMIT 1;
    IF citydb_schema IS NOT NULL THEN
        EXECUTE format('SET search_path = %I, lcz, public;', citydb_schema);
    END IF;
END $$;

-- ================================================================
-- ADMIN SETUP (creates all tables, no stored procedures)
-- ================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS lcz;

DROP TABLE IF EXISTS lcz.lcz_params CASCADE;
CREATE TABLE lcz.lcz_params (
    param_name  TEXT PRIMARY KEY,
    param_value TEXT NOT NULL
);

INSERT INTO lcz.lcz_params (param_name, param_value) VALUES
    ('boundary_buffer',          '25'),
    ('grid_resolution',          '10'),
    ('class_grid_resolution',    '100'),
    ('tree_pit_radius',          '2.0'),
    ('landuse_default_imperv',   '0.40'),
    ('svf_radius',               '60'),
    ('svf_ray_step',             '2'),
    ('tree_crown_ratio',         '0.35'),
    ('include_trees_in_svf',     'true'),
    ('svf_edge_buffer',          '60'),
    ('ar_cell_area',             '10000'),
    ('svf_weight',               '3.0'),
    ('bsf_weight',               '8.0'),
    ('isf_weight',               '2.0'),
    ('psf_weight',               '2.0'),
    ('height_weight',            '6.0'),
    ('ar_weight',                '4.0'),
    ('svf_norm_min',             '0.2'),
    ('svf_norm_max',             '1.0'),
    ('bsf_norm_min',             '0.0'),
    ('bsf_norm_max',             '0.9'),
    ('isf_norm_min',             '0.0'),
    ('isf_norm_max',             '1.0'),
    ('psf_norm_min',             '0.0'),
    ('psf_norm_max',             '1.0'),
    ('height_norm_min',          '2.0'),
    ('height_norm_max',          '50.0'),
    ('ar_norm_min',              '0.1'),
    ('ar_norm_max',              '5.0'),
    ('forest_cover_threshold',   '0.80');

-- ================================================================
-- Detect the projected SRID and store it in the parameter table
-- ================================================================
DO $$
DECLARE
    citydb_schema TEXT;
    detected_srid INTEGER;
    is_projected  BOOLEAN;
BEGIN
    -- Find the citydb schema that contains the 'database_srs' table
    SELECT table_schema INTO citydb_schema
    FROM information_schema.tables
    WHERE table_name = 'database_srs'
      AND table_schema NOT IN ('information_schema', 'pg_catalog', 'lcz')
    LIMIT 1;

    -- Get any SRID from the 3DCityDB schema (v5 doesn't have is_3d)
    EXECUTE format('SELECT srid FROM %I.database_srs WHERE srid != 0 LIMIT 1', citydb_schema)
    INTO detected_srid;

    -- Strictly validate that the SRID is a projected CRS (e.g., UTM)
    SELECT (srtext LIKE '%PROJCS%') INTO is_projected
    FROM spatial_ref_sys
    WHERE srid = detected_srid;

    IF NOT is_projected THEN
        RAISE EXCEPTION 'LCZ requires a projected coordinate system. Detected SRID % is geographic.', detected_srid;
    END IF;

    -- Save the SRID into the parameter table
    INSERT INTO lcz.lcz_params (param_name, param_value)
    VALUES ('srid', detected_srid::text)
    ON CONFLICT (param_name) DO UPDATE SET param_value = EXCLUDED.param_value;

END $$;

-- Shared geometric support tables (now SRID-free)
DROP TABLE IF EXISTS lcz.lcz_study_area_hull CASCADE;
CREATE TABLE lcz.lcz_study_area_hull (
    id   SERIAL PRIMARY KEY,
    geom geometry(POLYGON)
);
CREATE INDEX idx_lcz_study_area_hull ON lcz.lcz_study_area_hull USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_inner_boundary CASCADE;
CREATE TABLE lcz.lcz_inner_boundary (
    id   SERIAL PRIMARY KEY,
    geom geometry(POLYGON)
);
CREATE INDEX idx_lcz_inner_boundary ON lcz.lcz_inner_boundary USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_grid CASCADE;
CREATE TABLE lcz.lcz_grid (
    gx INTEGER,
    gy INTEGER,
    PRIMARY KEY (gx, gy)
);

DROP TABLE IF EXISTS lcz.lcz_ar_grid_100m CASCADE;
CREATE TABLE lcz.lcz_ar_grid_100m (
    gx   INTEGER,
    gy   INTEGER,
    geom geometry(POLYGON),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_ar_grid_100m_geom ON lcz.lcz_ar_grid_100m USING GIST(geom);

-- Phase 1: BSF tables
DROP TABLE IF EXISTS lcz.lcz_bsf_buildings CASCADE;
CREATE TABLE lcz.lcz_bsf_buildings (
    id   INTEGER,
    geom geometry(GEOMETRY)
);
CREATE INDEX idx_lcz_bsf_buildings_geom ON lcz.lcz_bsf_buildings USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_bsf_fractions CASCADE;
CREATE TABLE lcz.lcz_bsf_fractions (
    gx        INTEGER,
    gy        INTEGER,
    bsf_value NUMERIC(4,3),
    PRIMARY KEY (gx, gy)
);

DROP TABLE IF EXISTS lcz.lcz_bsf_map CASCADE;
CREATE TABLE lcz.lcz_bsf_map (
    gx        INTEGER,
    gy        INTEGER,
    geom      geometry(POINT),
    bsf_value NUMERIC(4,3),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_bsf_map_geom ON lcz.lcz_bsf_map USING GIST(geom);

DROP MATERIALIZED VIEW IF EXISTS lcz.lcz_bsf_mat_view CASCADE;
CREATE MATERIALIZED VIEW lcz.lcz_bsf_mat_view AS
SELECT
    row_number() OVER ()::int AS id,
    gx, gy, bsf_value, geom
FROM lcz.lcz_bsf_map
WITH NO DATA;
CREATE INDEX idx_lcz_bsf_mat_view_geom ON lcz.lcz_bsf_mat_view USING GIST(geom);

-- Phase 2: ISF tables
DROP TABLE IF EXISTS lcz.lcz_isf_buildings CASCADE;
CREATE TABLE lcz.lcz_isf_buildings (
    id   INTEGER,
    geom geometry(GEOMETRY)
);
CREATE INDEX idx_lcz_isf_buildings_geom ON lcz.lcz_isf_buildings USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_isf_tree_pits CASCADE;
CREATE TABLE lcz.lcz_isf_tree_pits (
    id   INTEGER,
    geom geometry(GEOMETRY)
);
CREATE INDEX idx_lcz_isf_tree_pits_geom ON lcz.lcz_isf_tree_pits USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_isf_landuse CASCADE;
CREATE TABLE lcz.lcz_isf_landuse (
    id             INTEGER,
    geom           geometry(GEOMETRY),
    imperv_coeff   NUMERIC
);
CREATE INDEX idx_lcz_isf_landuse_geom ON lcz.lcz_isf_landuse USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_isf_building_fractions CASCADE;
CREATE TABLE lcz.lcz_isf_building_fractions (
    gx           INTEGER,
    gy           INTEGER,
    b_geom       geometry(GEOMETRY),
    bsf_fraction NUMERIC,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_isf_building_fractions_xy ON lcz.lcz_isf_building_fractions (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_isf_landuse_fractions CASCADE;
CREATE TABLE lcz.lcz_isf_landuse_fractions (
    gx           INTEGER,
    gy           INTEGER,
    residual_isf NUMERIC,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_isf_landuse_fractions_xy ON lcz.lcz_isf_landuse_fractions (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_isf_map CASCADE;
CREATE TABLE lcz.lcz_isf_map (
    gx        INTEGER,
    gy        INTEGER,
    geom      geometry(POINT),
    isf_value NUMERIC(4,3),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_isf_map_geom ON lcz.lcz_isf_map USING GIST(geom);

DROP MATERIALIZED VIEW IF EXISTS lcz.lcz_isf_mat_view CASCADE;
CREATE MATERIALIZED VIEW lcz.lcz_isf_mat_view AS
SELECT
    row_number() OVER ()::int AS id,
    gx, gy, isf_value, geom
FROM lcz.lcz_isf_map
WITH NO DATA;
CREATE INDEX idx_lcz_isf_mat_view_geom ON lcz.lcz_isf_mat_view USING GIST(geom);

-- Phase 3: PSF table
DROP TABLE IF EXISTS lcz.lcz_psf_map CASCADE;
CREATE TABLE lcz.lcz_psf_map (
    gx        INTEGER,
    gy        INTEGER,
    geom      geometry(POINT),
    psf_value NUMERIC(4,3),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_psf_map_geom ON lcz.lcz_psf_map USING GIST(geom);

DROP MATERIALIZED VIEW IF EXISTS lcz.lcz_psf_mat_view CASCADE;
CREATE MATERIALIZED VIEW lcz.lcz_psf_mat_view AS
SELECT
    row_number() OVER ()::int AS id,
    gx, gy, psf_value, geom
FROM lcz.lcz_psf_map
WITH NO DATA;
CREATE INDEX idx_lcz_psf_mat_view_geom ON lcz.lcz_psf_mat_view USING GIST(geom);

-- Phase 4: Height tables
DROP TABLE IF EXISTS lcz.lcz_height_buildings CASCADE;
CREATE TABLE lcz.lcz_height_buildings (
    building_id     TEXT,
    geom            geometry(GEOMETRY),
    building_height NUMERIC
);
CREATE INDEX idx_lcz_height_buildings_geom ON lcz.lcz_height_buildings USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_height_fractions CASCADE;
CREATE TABLE lcz.lcz_height_fractions (
    gx           INTEGER,
    gy           INTEGER,
    height_value NUMERIC(6,2),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_height_fractions_xy ON lcz.lcz_height_fractions (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_height_map CASCADE;
CREATE TABLE lcz.lcz_height_map (
    gx           INTEGER,
    gy           INTEGER,
    geom         geometry(POINT),
    height_value NUMERIC(6,2),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_height_map_geom ON lcz.lcz_height_map USING GIST(geom);

DROP MATERIALIZED VIEW IF EXISTS lcz.lcz_height_mat_view CASCADE;
CREATE MATERIALIZED VIEW lcz.lcz_height_mat_view AS
SELECT
    row_number() OVER ()::int AS id,
    gx, gy, height_value, geom
FROM lcz.lcz_height_map
WITH NO DATA;
CREATE INDEX idx_lcz_height_mat_view_geom ON lcz.lcz_height_mat_view USING GIST(geom);

-- Phase 5: SVF tables
DROP TABLE IF EXISTS lcz.lcz_svf_ray_dictionary CASCADE;
CREATE TABLE lcz.lcz_svf_ray_dictionary (
    direction_id INTEGER PRIMARY KEY,
    dx           NUMERIC,
    dy           NUMERIC
);
INSERT INTO lcz.lcz_svf_ray_dictionary VALUES
    (1, 0, 1),
    (2, 0.707, 0.707),
    (3, 1, 0),
    (4, 0.707, -0.707),
    (5, 0, -1),
    (6, -0.707, -0.707),
    (7, -1, 0),
    (8, -0.707, 0.707);

DROP TABLE IF EXISTS lcz.lcz_svf_buildings CASCADE;
CREATE TABLE lcz.lcz_svf_buildings (
    building_id  INTEGER,
    footprint_2d geometry(GEOMETRY),
    ground_z     NUMERIC
);
CREATE INDEX idx_lcz_svf_buildings ON lcz.lcz_svf_buildings USING GIST(footprint_2d);

DROP TABLE IF EXISTS lcz.lcz_svf_roof_obstacles CASCADE;
CREATE TABLE lcz.lcz_svf_roof_obstacles (
    roof_id          INTEGER,
    footprint_2d     geometry(GEOMETRY),
    relative_height  NUMERIC(5,2)
);
CREATE INDEX idx_lcz_svf_roof_obstacles ON lcz.lcz_svf_roof_obstacles USING GIST(footprint_2d);

DROP TABLE IF EXISTS lcz.lcz_svf_tree_obstacles CASCADE;
CREATE TABLE lcz.lcz_svf_tree_obstacles (
    tree_id          INTEGER,
    footprint_2d     geometry(GEOMETRY),
    relative_height  NUMERIC(5,2)
);
CREATE INDEX idx_lcz_svf_tree_obstacles_geom ON lcz.lcz_svf_tree_obstacles USING GIST(footprint_2d);

DROP TABLE IF EXISTS lcz.lcz_svf_all_obstacles CASCADE;
CREATE TABLE lcz.lcz_svf_all_obstacles (
    footprint_2d    geometry(GEOMETRY),
    relative_height NUMERIC(5,2)
);
CREATE INDEX idx_lcz_svf_all_obstacles_geom ON lcz.lcz_svf_all_obstacles USING GIST(footprint_2d);

DROP TABLE IF EXISTS lcz.lcz_svf_ray_results CASCADE;
CREATE TABLE lcz.lcz_svf_ray_results (
    gx           INTEGER,
    gy           INTEGER,
    direction_id INTEGER,
    max_alpha    NUMERIC
);
CREATE INDEX idx_lcz_svf_ray_results_gx ON lcz.lcz_svf_ray_results (gx, gy, direction_id);

DROP TABLE IF EXISTS lcz.lcz_svf_map CASCADE;
CREATE TABLE lcz.lcz_svf_map (
    id        SERIAL PRIMARY KEY,
    gx        INTEGER,
    gy        INTEGER,
    svf_value NUMERIC(4,3),
    geom      geometry(POINT)
);
CREATE INDEX idx_lcz_svf_map_geom ON lcz.lcz_svf_map USING GIST(geom);

DROP MATERIALIZED VIEW IF EXISTS lcz.lcz_svf_mat_view CASCADE;
CREATE MATERIALIZED VIEW lcz.lcz_svf_mat_view AS
SELECT
    row_number() OVER ()::int AS id,
    gx, gy, svf_value, geom
FROM lcz.lcz_svf_map
WITH NO DATA;
CREATE INDEX idx_lcz_svf_mat_view_geom ON lcz.lcz_svf_mat_view USING GIST(geom);

-- Phase 6: Aspect Ratio tables
DROP TABLE IF EXISTS lcz.lcz_ar_facade CASCADE;
CREATE TABLE lcz.lcz_ar_facade (
    gx                INTEGER,
    gy                INTEGER,
    total_facade_area NUMERIC,
    wall_count        INTEGER,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_ar_facade_gxy ON lcz.lcz_ar_facade (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_ar_bsf_100m CASCADE;
CREATE TABLE lcz.lcz_ar_bsf_100m (
    gx       INTEGER,
    gy       INTEGER,
    mean_bsf NUMERIC,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_ar_bsf_100m_gxy ON lcz.lcz_ar_bsf_100m (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_ar_height_100m CASCADE;
CREATE TABLE lcz.lcz_ar_height_100m (
    gx          INTEGER,
    gy          INTEGER,
    mean_height NUMERIC,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_ar_height_100m_gxy ON lcz.lcz_ar_height_100m (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_ar_map CASCADE;
CREATE TABLE lcz.lcz_ar_map (
    gx                INTEGER,
    gy                INTEGER,
    geom              geometry(POINT),
    mean_height       NUMERIC,
    total_facade_area NUMERIC,
    wall_count        INTEGER,
    mean_bsf          NUMERIC,
    ar_value          NUMERIC(8,3),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_ar_map_geom ON lcz.lcz_ar_map USING GIST(geom);

DROP MATERIALIZED VIEW IF EXISTS lcz.lcz_ar_mat_view CASCADE;
CREATE MATERIALIZED VIEW lcz.lcz_ar_mat_view AS
SELECT
    row_number() OVER ()::int AS id,
    gx, gy, mean_height, total_facade_area, wall_count, mean_bsf, ar_value, geom
FROM lcz.lcz_ar_map
WITH NO DATA;
CREATE INDEX idx_lcz_ar_mat_view_geom ON lcz.lcz_ar_mat_view USING GIST(geom);

-- Aggregation and parameter tables
DROP TABLE IF EXISTS lcz.lcz_aggregate_svf_100m CASCADE;
CREATE TABLE lcz.lcz_aggregate_svf_100m (
    gx       INTEGER,
    gy       INTEGER,
    svf_mean NUMERIC(6,4),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_svf_100m_gxy ON lcz.lcz_aggregate_svf_100m (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_aggregate_isf_100m CASCADE;
CREATE TABLE lcz.lcz_aggregate_isf_100m (
    gx       INTEGER,
    gy       INTEGER,
    isf_mean NUMERIC(6,4),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_isf_100m_gxy ON lcz.lcz_aggregate_isf_100m (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_trc_trees CASCADE;
CREATE TABLE lcz.lcz_trc_trees (
    gx               INTEGER,
    gy               INTEGER,
    tree_count       INTEGER,
    mean_tree_height NUMERIC,
    total_tree_area  NUMERIC,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_trc_trees_gxy ON lcz.lcz_trc_trees (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_trc_elements CASCADE;
CREATE TABLE lcz.lcz_trc_elements (
    gx              INTEGER,
    gy              INTEGER,
    z_h             NUMERIC,
    bsf             NUMERIC,
    lambda_f        NUMERIC,
    tree_count      INTEGER,
    mean_tree_height NUMERIC,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_trc_elements_gxy ON lcz.lcz_trc_elements (gx, gy);

DROP TABLE IF EXISTS lcz.lcz_100m_params CASCADE;
CREATE TABLE lcz.lcz_100m_params (
    gx     INTEGER,
    gy     INTEGER,
    geom   geometry(POINT),
    svf    NUMERIC,
    bsf    NUMERIC,
    isf    NUMERIC,
    psf    NUMERIC,
    height NUMERIC,
    ar     NUMERIC,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_params_gxy ON lcz.lcz_100m_params (gx, gy);

-- LCZ reference table
DROP TABLE IF EXISTS lcz.lcz_reference CASCADE;
CREATE TABLE lcz.lcz_reference (
    lcz_class INTEGER PRIMARY KEY,
    lcz_name  TEXT,
    svf_mid   NUMERIC(5,3),
    ar_mid    NUMERIC(5,3),
    bsf_mid   NUMERIC(4,2),
    isf_mid   NUMERIC(4,2),
    psf_mid   NUMERIC(4,2),
    h_mid     NUMERIC(5,1)
);
INSERT INTO lcz.lcz_reference VALUES
(1,  'Compact high-rise',    0.300, 2.500, 0.50, 0.50, 0.05, 30.0),
(2,  'Compact mid-rise',     0.450, 1.375, 0.55, 0.40, 0.10, 17.5),
(3,  'Compact low-rise',     0.400, 1.125, 0.55, 0.35, 0.15,  6.5),
(4,  'Open high-rise',       0.600, 1.000, 0.30, 0.35, 0.35, 30.0),
(5,  'Open mid-rise',        0.650, 0.525, 0.30, 0.40, 0.30, 17.5),
(6,  'Open low-rise',        0.750, 0.525, 0.30, 0.35, 0.45,  6.5),
(7,  'Lightweight low-rise', 0.350, 1.500, 0.75, 0.10, 0.15,  3.0),
(8,  'Large low-rise',       0.850, 0.200, 0.40, 0.45, 0.10,  6.5),
(9,  'Sparsely built',       0.900, 0.175, 0.15, 0.10, 0.70,  6.5),
(10, 'Heavy industry',       0.750, 0.350, 0.25, 0.30, 0.45, 10.0),
(11, 'Dense trees',          0.200, 2.000, 0.05, 0.05, 0.95, 16.5),
(12, 'Scattered trees',      0.650, 0.500, 0.05, 0.05, 0.95,  9.0),
(13, 'Bush scrub',           0.800, 0.625, 0.05, 0.05, 0.95,  1.0),
(14, 'Low plants',           0.950, 0.050, 0.05, 0.05, 0.95,  0.5),
(15, 'Bare rock paved',      0.950, 0.050, 0.05, 0.95, 0.05,  0.25),
(16, 'Bare soil sand',       0.950, 0.050, 0.05, 0.05, 0.95,  0.25),
(17, 'Water',                0.999, 0.000, 0.00, 0.00, 1.00,  0.0);

-- Final output tables
DROP TABLE IF EXISTS lcz.lcz_map CASCADE;
CREATE TABLE lcz.lcz_map (
    gx           INTEGER,
    gy           INTEGER,
    geom         geometry(POINT),
    lcz_class    INTEGER,
    lcz_name     TEXT,
    distance_sq  NUMERIC,
    svf          NUMERIC,
    bsf          NUMERIC,
    isf          NUMERIC,
    psf          NUMERIC,
    height       NUMERIC,
    ar           NUMERIC,
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_map_geom ON lcz.lcz_map USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_map_polygons CASCADE;
CREATE TABLE lcz.lcz_map_polygons (
    gx           INTEGER,
    gy           INTEGER,
    lcz_class    INTEGER,
    lcz_name     TEXT,
    distance_sq  NUMERIC,
    svf          NUMERIC,
    bsf          NUMERIC,
    isf          NUMERIC,
    psf          NUMERIC,
    height       NUMERIC,
    ar           NUMERIC,
    geom         geometry(POLYGON),
    PRIMARY KEY (gx, gy)
);
CREATE INDEX idx_lcz_map_polygons_geom ON lcz.lcz_map_polygons USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_map_dissolved CASCADE;
CREATE TABLE lcz.lcz_map_dissolved (
    lcz_class INTEGER PRIMARY KEY,
    lcz_name  TEXT,
    geom      geometry(MULTIPOLYGON)
);
CREATE INDEX idx_lcz_map_dissolved_geom ON lcz.lcz_map_dissolved USING GIST(geom);

DROP TABLE IF EXISTS lcz.lcz_validation_samples CASCADE;
CREATE TABLE lcz.lcz_validation_samples (
    cell_x      INTEGER,
    cell_y      INTEGER,
    manual_lcz  INTEGER,
    notes       TEXT
);

DROP TABLE IF EXISTS lcz.lcz_run_steps CASCADE;
DROP TABLE IF EXISTS lcz.lcz_run_metadata CASCADE;

CREATE TABLE lcz.lcz_run_metadata (
    run_id              SERIAL PRIMARY KEY,
    start_time          TIMESTAMP WITH TIME ZONE DEFAULT now(),
    end_time            TIMESTAMP WITH TIME ZONE,
    study_area_geometry geometry(GEOMETRY),
    parameters          JSONB,
    status              TEXT DEFAULT 'running',
    notes               TEXT
);

CREATE TABLE lcz.lcz_run_steps (
    step_id         SERIAL PRIMARY KEY,
    run_id          INTEGER REFERENCES lcz.lcz_run_metadata(run_id) ON DELETE CASCADE,
    step_name       TEXT,
    start_time      TIMESTAMP WITH TIME ZONE,
    end_time        TIMESTAMP WITH TIME ZONE,
    duration_seconds NUMERIC,
    status          TEXT,
    rows_affected   INTEGER,
    error_message   TEXT
);

-- ================================================================
-- Configurable land‑use → impervious coefficient lookup table
-- (Hybrid approach: numeric class + usage key, with few text exceptions)
-- ================================================================

DROP TABLE IF EXISTS lcz.lcz_landuse_impervious CASCADE;
CREATE TABLE lcz.lcz_landuse_impervious (
    id            SERIAL PRIMARY KEY,
    class_code    TEXT NOT NULL,
    usage_code    TEXT,          -- can be NULL for generic fallbacks
    bez_text      TEXT,          -- can be NULL for usage / class defaults
    imperv_coeff  NUMERIC(4,2) NOT NULL
);

-- ================================================================
-- Generic class fallback (when even usage is unknown)
-- ================================================================
INSERT INTO lcz.lcz_landuse_impervious (class_code, usage_code, bez_text, imperv_coeff) VALUES
('1000', NULL, NULL, 0.40),
('1100', NULL, NULL, 0.50),
('2000', NULL, NULL, 0.90),
('3000', NULL, NULL, 0.10),
('4000', NULL, NULL, 0.00);

-- ================================================================
-- Normalised defaults per USAGE (bez_text = NULL)
-- ================================================================
INSERT INTO lcz.lcz_landuse_impervious (class_code, usage_code, bez_text, imperv_coeff) VALUES
('1000', '1020', NULL, 0.60),   -- industrial/commercial default
('1000', '1030', NULL, 0.40),   -- mixed use
('1000', '1040', NULL, 0.50),   -- special functional
('1000', '1100', NULL, 0.40),   -- residential
('1000', '1110', NULL, 0.20),   -- sport/leisure/recreation
('1000', '1120', NULL, 0.07),   -- cemetery
('1000', '1130', NULL, 0.20),   -- sport/leisure (remaining, except golf/swimming/weekend)
('1100', '1140', NULL, 0.02),   -- mining/quarry
('1100', '3080', NULL, 0.02),   -- unvegetated
('2000', '2010', NULL, 0.90),   -- traffic/plaza
('2000', '2020', NULL, 0.70),   -- rail
('2000', '2030', NULL, 0.90),   -- air traffic
('2000', '2050', NULL, 0.68),   -- path
('2000', '2060', NULL, 0.90),   -- pedestrian/square
('3000', '3020', NULL, 0.01),   -- agriculture
('3000', '3030', NULL, 0.00),   -- forest
('3000', '3040', NULL, 0.00),   -- woody vegetation
('3000', '3050', NULL, 0.10),   -- heath
('3000', '3060', NULL, 0.00),   -- moor
('4000', '4010', NULL, 0.00),   -- flowing water
('4000', '4020', NULL, 0.00);   -- standing water

-- ================================================================
-- EXCEPTIONS (bez_text is the specific German text)
-- ================================================================

-- usage 1020 exceptions (original, must not be lost)
INSERT INTO lcz.lcz_landuse_impervious (class_code, usage_code, bez_text, imperv_coeff) VALUES
('1000', '1020', 'Gärtnerei', 0.20),
('1000', '1020', 'Deponie (oberirdisch)', 0.20);

-- usage 1130 exceptions (existing)
INSERT INTO lcz.lcz_landuse_impervious (class_code, usage_code, bez_text, imperv_coeff) VALUES
('1000', '1130', 'Golf', 0.01),
('1000', '1130', 'Schwimmen', 0.50),
('1000', '1130', 'Wochenend- und Ferienhausfläche', 0.10);

-- New exceptions for existing usage codes (yellow rows)
INSERT INTO lcz.lcz_landuse_impervious (class_code, usage_code, bez_text, imperv_coeff) VALUES
-- usage 1020 (industrial/commercial)
('1000', '1020', 'Werft', 0.65),
-- usage 1110 (sport/leisure)
('1000', '1110', 'Freilichtmuseum', 0.20),   -- same as Freizeitanlage
('1000', '1110', 'Autokino, Freilichtkino', 0.50),   -- balanced estimate
-- usage 1130 (remaining sport/leisure)
('1000', '1130', 'Modellfluggelände', 0.01);  -- same as Golf

-- usage 2030 (air traffic) specific exceptions
INSERT INTO lcz.lcz_landuse_impervious (class_code, usage_code, bez_text, imperv_coeff) VALUES
('2000', '2030', 'Verkehrslandeplatz', 0.20),
('2000', '2030', 'Segelfluggelände', 0.20),
('2000', '2030', 'Regionalflughafen', 0.31),
('2000', '2030', 'Internationaler Flughafen', 0.31);

-- New usage defaults for yellow‑row codes (class + usage, bez_text = NULL)
INSERT INTO lcz.lcz_landuse_impervious (class_code, usage_code, bez_text, imperv_coeff) VALUES
('1000', '1060', NULL, 0.50),   -- Halde, Deponie (untertägig) – mix of sealed waste areas
('1000', '1070', NULL, 0.50),   -- Bergbaubetrieb – mining
('2000', '2040', NULL, 0.90),   -- Schiffsverkehr land areas
('1100', '3060', NULL, 0.00),   -- Torf (peat mining) – like moor
('1100', '3070', NULL, 0.00),   -- Sumpf (swamp)
('4000', '4030', NULL, 0.00);   -- Hafenbecken (harbour basin)

-- Additional specific exceptions for new bez under existing usage defaults
INSERT INTO lcz.lcz_landuse_impervious (class_code, usage_code, bez_text, imperv_coeff) VALUES
('1000', '1060', 'Deponie (untertägig)', 0.20),   -- engineered landfill
('1000', '1060', 'Halde', 0.02);                  -- natural rock/gravel spoil heap

COMMIT;

-- ================================================================
-- CLASSIFICATION VIEW (created dynamically with the correct SRID)
-- ================================================================

DO $$
DECLARE
    v_srid INTEGER;
    citydb_schema TEXT;
BEGIN
    -- retrieve the projected SRID we stored earlier
    SELECT param_value::integer INTO v_srid
    FROM lcz.lcz_params
    WHERE param_name = 'srid';

    -- detect the citydb schema
    SELECT table_schema INTO citydb_schema
    FROM information_schema.tables
    WHERE table_name = 'feature'
      AND table_schema NOT IN ('information_schema', 'pg_catalog', 'lcz')
    LIMIT 1;

    -- set search path so the view can find the tables
    EXECUTE format('SET search_path = %I, lcz, public;', citydb_schema);

    -- drop old version if it exists
    DROP MATERIALIZED VIEW IF EXISTS lcz.lcz_classification CASCADE;

    -- create the view with the correct SRID and explicit schema bindings
    EXECUTE format('
        CREATE MATERIALIZED VIEW lcz.lcz_classification AS
        WITH    
        water_mask AS (
            SELECT DISTINCT
                floor(gx / 100) * 100 AS gx,
                floor(gy / 100) * 100 AS gy
            FROM (SELECT DISTINCT floor(gx/100)*100 AS gx, floor(gy/100)*100 AS gy FROM lcz.lcz_grid) g
            JOIN %I.feature f ON f.objectclass_id = 300
            JOIN %I.property p ON p.feature_id = f.id
                           AND p.name = ''class''
                           AND p.val_string = ''4000''
            JOIN %I.geometry_data gd ON gd.feature_id = f.id
            WHERE ST_Intersects(
                    ST_SetSRID(ST_MakeEnvelope(floor(gx/100)*100, floor(gy/100)*100,
                                                floor(gx/100)*100+100, floor(gy/100)*100+100), %s),
                    ST_Force2D(gd.geometry)
                  )
            GROUP BY 1,2
            HAVING SUM(ST_Area(ST_Intersection(
                    ST_SetSRID(ST_MakeEnvelope(floor(gx/100)*100, floor(gy/100)*100,
                                                floor(gx/100)*100+100, floor(gy/100)*100+100), %s),
                    ST_Force2D(gd.geometry)
                ))) > 3000
        ),

        norm_cells AS (
            SELECT
                gx, gy, geom,
                GREATEST(0.0, LEAST(1.0, (svf  - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''svf_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''svf_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''svf_norm_min''), 0))) AS n_svf,
                GREATEST(0.0, LEAST(1.0, (bsf  - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''bsf_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''bsf_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''bsf_norm_min''), 0))) AS n_bsf,
                GREATEST(0.0, LEAST(1.0, (isf  - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''isf_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''isf_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''isf_norm_min''), 0))) AS n_isf,
                GREATEST(0.0, LEAST(1.0, (psf  - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''psf_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''psf_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''psf_norm_min''), 0))) AS n_psf,
                GREATEST(0.0, LEAST(1.0, (height - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''height_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''height_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''height_norm_min''), 0))) AS n_height,
                GREATEST(0.0, LEAST(1.0, (ar    - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''ar_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''ar_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''ar_norm_min''), 0))) AS n_ar,
                bsf, psf
            FROM lcz.lcz_100m_params
        ),
        norm_ref AS (
            SELECT
                lcz_class, lcz_name,
                GREATEST(0.0, LEAST(1.0, (svf_mid - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''svf_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''svf_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''svf_norm_min''), 0))) AS r_svf,
                GREATEST(0.0, LEAST(1.0, (bsf_mid - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''bsf_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''bsf_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''bsf_norm_min''), 0))) AS r_bsf,
                GREATEST(0.0, LEAST(1.0, (isf_mid - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''isf_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''isf_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''isf_norm_min''), 0))) AS r_isf,
                GREATEST(0.0, LEAST(1.0, (psf_mid - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''psf_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''psf_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''psf_norm_min''), 0))) AS r_psf,
                GREATEST(0.0, LEAST(1.0, (h_mid  - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''height_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''height_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''height_norm_min''), 0))) AS r_height,
                GREATEST(0.0, LEAST(1.0, (ar_mid - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''ar_norm_min''))
                        / NULLIF((SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''ar_norm_max'') - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''ar_norm_min''), 0))) AS r_ar
            FROM lcz.lcz_reference
        ),
        distances AS (
            SELECT
                c.gx, c.gy, c.geom, c.bsf, c.psf,
                r.lcz_class, r.lcz_name,
                (
                    (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''svf_weight'')    * POWER(c.n_svf    - r.r_svf,    2) +
                    (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''bsf_weight'')    * POWER(c.n_bsf    - r.r_bsf,    2) +
                    (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''isf_weight'')    * POWER(c.n_isf    - r.r_isf,    2) +
                    (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''psf_weight'')    * POWER(c.n_psf    - r.r_psf,    2) +
                    (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''height_weight'') * POWER(c.n_height - r.r_height, 2) +
                    (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name=''ar_weight'')     * POWER(c.n_ar     - r.r_ar,     2)
                ) AS weighted_dist_sq
            FROM norm_cells c
            CROSS JOIN norm_ref r
        ),
        ranked AS (
            SELECT DISTINCT ON (gx, gy)
                gx, gy, geom, bsf, psf, lcz_class, lcz_name, weighted_dist_sq
            FROM distances
            ORDER BY gx, gy, weighted_dist_sq
        )
        SELECT
            r.gx, r.gy, r.geom,
            CASE
                WHEN w.gx IS NOT NULL AND r.bsf = 0 AND r.psf > 0.80 THEN 17
                WHEN r.lcz_class IN (9,10) AND r.bsf < 0.10 AND r.psf > 0.50 THEN 12
                ELSE r.lcz_class
            END AS lcz_class,
            CASE
                WHEN w.gx IS NOT NULL AND r.bsf = 0 AND r.psf > 0.80 THEN ''Water''
                WHEN r.lcz_class IN (9,10) AND r.bsf < 0.10 AND r.psf > 0.50 THEN ''Scattered trees''
                ELSE r.lcz_name
            END AS lcz_name,
            r.weighted_dist_sq AS distance_sq
        FROM ranked r
        LEFT JOIN water_mask w ON r.gx = w.gx AND r.gy = w.gy
        WITH DATA;
    ', citydb_schema, citydb_schema, citydb_schema, v_srid, v_srid);

    -- add spatial index
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_lcz_classification_geom ON lcz.lcz_classification USING GIST(geom);';

END $$;