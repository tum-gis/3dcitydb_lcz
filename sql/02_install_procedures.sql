-- ================================================================
-- install_procedures.sql (schema-agnostic, CRS-agnostic)
-- ================================================================
-- Input data check
-- Must be called before any other phase.
-- Verifies object classes, properties, geometry, and mapping coverage.
-- ================================================================
CREATE OR REPLACE PROCEDURE lcz.check_input_data()
LANGUAGE plpgsql AS $$
DECLARE
    citydb_schema TEXT;
    v_oc_building INTEGER;
    v_oc_ground INTEGER;
    v_oc_roof INTEGER;
    v_oc_wall INTEGER;
    v_oc_landuse INTEGER;
    v_oc_tree INTEGER;

    cnt_building BIGINT;
    cnt_ground BIGINT;
    cnt_roof BIGINT;
    cnt_wall BIGINT;
    cnt_landuse BIGINT;
    cnt_tree BIGINT;

    cnt_prop_class BIGINT;
    cnt_prop_bez BIGINT;
    cnt_prop_usage BIGINT;
    cnt_prop_zmax BIGINT;
    cnt_prop_flaeche BIGINT;
    cnt_prop_lod2 BIGINT;

    cnt_geom_ground BIGINT;
    cnt_geom_roof BIGINT;
    cnt_geom_wall BIGINT;
    cnt_geom_building BIGINT;
    cnt_geom_landuse BIGINT;

    cnt_tree_envelope BIGINT;

    cnt_unmapped_combinations BIGINT;
BEGIN
    -- Schema detection and search path
    SELECT table_schema INTO citydb_schema
    FROM information_schema.tables
    WHERE table_name = 'feature'
      AND table_schema NOT IN ('information_schema', 'pg_catalog', 'lcz')
    LIMIT 1;

    IF citydb_schema IS NULL THEN
        RAISE EXCEPTION 'No 3DCityDB schema with a feature table found.';
    END IF;

    EXECUTE format('SET search_path = %I, lcz, public;', citydb_schema);

    -- Object class IDs
    SELECT id INTO v_oc_building FROM objectclass WHERE classname = 'Building';
    SELECT id INTO v_oc_ground   FROM objectclass WHERE classname = 'GroundSurface';
    SELECT id INTO v_oc_roof     FROM objectclass WHERE classname = 'RoofSurface';
    SELECT id INTO v_oc_wall     FROM objectclass WHERE classname = 'WallSurface';
    SELECT id INTO v_oc_landuse  FROM objectclass WHERE classname = 'LandUse';
    SELECT id INTO v_oc_tree     FROM objectclass WHERE classname = 'SolitaryVegetationObject';

    IF v_oc_building IS NULL THEN RAISE EXCEPTION 'Required object class "Building" not found.'; END IF;
    IF v_oc_ground   IS NULL THEN RAISE EXCEPTION 'Required object class "GroundSurface" not found.'; END IF;
    IF v_oc_roof     IS NULL THEN RAISE EXCEPTION 'Required object class "RoofSurface" not found.'; END IF;
    IF v_oc_wall     IS NULL THEN RAISE EXCEPTION 'Required object class "WallSurface" not found.'; END IF;
    IF v_oc_landuse  IS NULL THEN RAISE EXCEPTION 'Required object class "LandUse" not found.'; END IF;
    IF v_oc_tree     IS NULL THEN RAISE EXCEPTION 'Required object class "SolitaryVegetationObject" not found.'; END IF;

    -- Active feature counts
    SELECT COUNT(*) INTO cnt_building FROM feature WHERE objectclass_id = v_oc_building AND termination_date IS NULL;
    SELECT COUNT(*) INTO cnt_ground   FROM feature WHERE objectclass_id = v_oc_ground   AND termination_date IS NULL;
    SELECT COUNT(*) INTO cnt_roof     FROM feature WHERE objectclass_id = v_oc_roof     AND termination_date IS NULL;
    SELECT COUNT(*) INTO cnt_wall     FROM feature WHERE objectclass_id = v_oc_wall     AND termination_date IS NULL;
    SELECT COUNT(*) INTO cnt_landuse  FROM feature WHERE objectclass_id = v_oc_landuse  AND termination_date IS NULL;
    SELECT COUNT(*) INTO cnt_tree     FROM feature WHERE objectclass_id = v_oc_tree     AND termination_date IS NULL;

    IF cnt_building = 0 THEN RAISE EXCEPTION 'No active Building features found.'; END IF;
    IF cnt_ground   = 0 THEN RAISE EXCEPTION 'No active GroundSurface features found.'; END IF;
    IF cnt_roof     = 0 THEN RAISE EXCEPTION 'No active RoofSurface features found.'; END IF;
    IF cnt_wall     = 0 THEN RAISE EXCEPTION 'No active WallSurface features found.'; END IF;
    IF cnt_landuse  = 0 THEN RAISE EXCEPTION 'No active LandUse features found.'; END IF;
    IF cnt_tree     = 0 THEN RAISE EXCEPTION 'No active SolitaryVegetationObject features found.'; END IF;

    -- Required property existence (at least one feature of that class has the property)
    SELECT COUNT(DISTINCT p.feature_id) INTO cnt_prop_class
    FROM property p JOIN feature f ON p.feature_id = f.id
    WHERE f.objectclass_id = v_oc_landuse AND f.termination_date IS NULL
      AND p.name = 'class';

    SELECT COUNT(DISTINCT p.feature_id) INTO cnt_prop_bez
    FROM property p JOIN feature f ON p.feature_id = f.id
    WHERE f.objectclass_id = v_oc_landuse AND f.termination_date IS NULL
      AND p.name = 'bez';

    SELECT COUNT(DISTINCT p.feature_id) INTO cnt_prop_usage
    FROM property p JOIN feature f ON p.feature_id = f.id
    WHERE f.objectclass_id = v_oc_landuse AND f.termination_date IS NULL
      AND p.name = 'usage';

    SELECT COUNT(DISTINCT p.feature_id) INTO cnt_prop_zmax
    FROM property p JOIN feature f ON p.feature_id = f.id
    WHERE f.objectclass_id = v_oc_roof AND f.termination_date IS NULL
      AND p.name = 'Z_MAX';

    SELECT COUNT(DISTINCT p.feature_id) INTO cnt_prop_flaeche
    FROM property p JOIN feature f ON p.feature_id = f.id
    WHERE f.objectclass_id = v_oc_wall AND f.termination_date IS NULL
      AND p.name = 'Flaeche';

    SELECT COUNT(DISTINCT p.feature_id) INTO cnt_prop_lod2
    FROM property p JOIN feature f ON p.feature_id = f.id
    WHERE f.objectclass_id = v_oc_tree AND f.termination_date IS NULL
      AND p.name = 'lod2ImplicitRepresentation';

    IF cnt_prop_class = 0 THEN RAISE EXCEPTION 'LandUse: required property "class" not found.'; END IF;
    IF cnt_prop_bez   = 0 THEN RAISE EXCEPTION 'LandUse: required property "bez" not found.'; END IF;
    IF cnt_prop_usage = 0 THEN RAISE EXCEPTION 'LandUse: required property "usage" not found.'; END IF;
    IF cnt_prop_zmax = 0 THEN RAISE EXCEPTION 'RoofSurface: required property "Z_MAX" not found.'; END IF;
    IF cnt_prop_flaeche = 0 THEN RAISE EXCEPTION 'WallSurface: required property "Flaeche" not found.'; END IF;
    IF cnt_prop_lod2 = 0 THEN RAISE EXCEPTION 'SolitaryVegetationObject: required property "lod2ImplicitRepresentation" not found.'; END IF;

    SELECT COUNT(*) INTO cnt_tree_envelope
    FROM feature
    WHERE objectclass_id = v_oc_tree
      AND termination_date IS NULL
      AND envelope IS NOT NULL;

    IF cnt_tree_envelope = 0 THEN
        RAISE EXCEPTION 'SolitaryVegetationObject: no envelope geometry found.';
    END IF;

    -- Geometry existence
    SELECT COUNT(DISTINCT g.feature_id) INTO cnt_geom_ground
    FROM geometry_data g JOIN feature f ON g.feature_id = f.id
    WHERE f.objectclass_id = v_oc_ground AND f.termination_date IS NULL;

    SELECT COUNT(DISTINCT g.feature_id) INTO cnt_geom_roof
    FROM geometry_data g JOIN feature f ON g.feature_id = f.id
    WHERE f.objectclass_id = v_oc_roof AND f.termination_date IS NULL;

    SELECT COUNT(DISTINCT g.feature_id) INTO cnt_geom_wall
    FROM geometry_data g JOIN feature f ON g.feature_id = f.id
    WHERE f.objectclass_id = v_oc_wall AND f.termination_date IS NULL;

    SELECT COUNT(DISTINCT g.feature_id) INTO cnt_geom_building
    FROM geometry_data g JOIN feature f ON g.feature_id = f.id
    WHERE f.objectclass_id = v_oc_building AND f.termination_date IS NULL;

    SELECT COUNT(DISTINCT g.feature_id) INTO cnt_geom_landuse
    FROM geometry_data g JOIN feature f ON g.feature_id = f.id
    WHERE f.objectclass_id = v_oc_landuse AND f.termination_date IS NULL;

    IF cnt_geom_ground   = 0 THEN RAISE EXCEPTION 'GroundSurface: no geometry found.'; END IF;
    IF cnt_geom_roof     = 0 THEN RAISE EXCEPTION 'RoofSurface: no geometry found.'; END IF;
    IF cnt_geom_wall     = 0 THEN RAISE EXCEPTION 'WallSurface: no geometry found.'; END IF;
    IF cnt_geom_building = 0 THEN RAISE EXCEPTION 'Building: no geometry found.'; END IF;
    IF cnt_geom_landuse  = 0 THEN RAISE EXCEPTION 'LandUse: no geometry found.'; END IF;

    -- Land-use mapping coverage check (warning only)
    WITH all_combinations AS (
        SELECT DISTINCT
            p_class.val_string AS class_code,
            p_usage.val_string AS usage_code,
            p_bez.val_string   AS bez_text
        FROM feature f
        JOIN property p_class ON f.id = p_class.feature_id AND p_class.name = 'class'
        LEFT JOIN property p_usage ON f.id = p_usage.feature_id AND p_usage.name = 'usage'
        LEFT JOIN property p_bez   ON f.id = p_bez.feature_id   AND p_bez.name = 'bez'
        WHERE f.objectclass_id = v_oc_landuse
          AND f.termination_date IS NULL
    ),
    covered AS (
        SELECT a.class_code, a.usage_code, a.bez_text
        FROM all_combinations a
        WHERE EXISTS (
            SELECT 1 FROM lcz.lcz_landuse_impervious m
            WHERE m.class_code = a.class_code
              AND ((m.usage_code = a.usage_code AND m.bez_text = a.bez_text)      -- exact
                OR (m.usage_code = a.usage_code AND m.bez_text IS NULL)          -- usage default
                OR (m.usage_code IS NULL AND m.bez_text IS NULL))                -- class fallback
        )
    )
    SELECT COUNT(*) INTO cnt_unmapped_combinations
    FROM all_combinations a
    WHERE NOT EXISTS (
        SELECT 1 FROM covered c
        WHERE c.class_code = a.class_code
          AND c.usage_code IS NOT DISTINCT FROM a.usage_code
          AND c.bez_text   IS NOT DISTINCT FROM a.bez_text
    );

    -- Output summary
    RAISE NOTICE '[Input check] Building: %, GroundSurface: %, RoofSurface: %, WallSurface: %, LandUse: %, Trees: %.',
                 cnt_building, cnt_ground, cnt_roof, cnt_wall, cnt_landuse, cnt_tree;

    RAISE NOTICE '[Input check] Required properties and geometry present.';

    IF cnt_unmapped_combinations > 0 THEN
        RAISE WARNING '[Input check] % distinct land-use class/usage/bez combination(s) are not covered by the mapping table. They will use the default impervious coefficient.', cnt_unmapped_combinations;
    ELSE
        RAISE NOTICE '[Input check] All land-use combinations are covered by the mapping table.';
    END IF;

END $$;


-- Phase 0: Grid & Study Area
CREATE OR REPLACE PROCEDURE lcz.phase0_grid()
LANGUAGE plpgsql AS $$
DECLARE
    v_xmin INTEGER; v_xmax INTEGER; v_ymin INTEGER; v_ymax INTEGER;
    v_boundary_buffer NUMERIC := 200; v_grid_res INTEGER := 2;
    v_srid INTEGER;
    v_run_id INTEGER;
    already_done BIGINT;
BEGIN
    SELECT param_value::numeric INTO v_boundary_buffer FROM lcz.lcz_params WHERE param_name = 'boundary_buffer';
    SELECT param_value::integer INTO v_grid_res FROM lcz.lcz_params WHERE param_name = 'grid_resolution';
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';

    INSERT INTO lcz.lcz_run_metadata (start_time, study_area_geometry, parameters, status)
    VALUES (now(), NULL, (SELECT jsonb_object_agg(param_name, param_value) FROM lcz.lcz_params), 'running')
    RETURNING run_id INTO v_run_id;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_grid;
    IF already_done > 0 THEN
        RAISE NOTICE '[Phase 0] Grid already exists — skipping.';
        INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
        VALUES (v_run_id, 'Phase 0 — Study Area & Shared Grids', now(), now(), 0, 'skipped', already_done);
        UPDATE lcz.lcz_run_metadata SET study_area_geometry = (SELECT geom FROM lcz.lcz_inner_boundary LIMIT 1) WHERE run_id = v_run_id;
        COMMIT; RETURN;
    END IF;
    RAISE NOTICE '[Phase 0] Building study area and grid...';
    INSERT INTO lcz.lcz_study_area_hull (geom)
SELECT ST_Union(geom) AS geom FROM (
    -- building footprints
    SELECT ST_Buffer(ST_Collect(ST_Force2D(g.geometry)), 0) AS geom
    FROM feature f JOIN geometry_data g ON f.id=g.feature_id
    WHERE f.objectclass_id=710
    UNION ALL
    -- land‑use polygons
    SELECT ST_Buffer(ST_Collect(ST_Force2D(g.geometry)), 0) AS geom
    FROM feature f JOIN geometry_data g ON f.id=g.feature_id
    WHERE f.objectclass_id=300
) all_features;
    INSERT INTO lcz.lcz_inner_boundary (geom)
    SELECT ST_Buffer(geom, -v_boundary_buffer) FROM lcz.lcz_study_area_hull;
SELECT (floor(ST_XMin(geom) / v_grid_res) * v_grid_res)::int,
       (ceil(ST_XMax(geom) / v_grid_res) * v_grid_res)::int,
       (floor(ST_YMin(geom) / v_grid_res) * v_grid_res)::int,
       (ceil(ST_YMax(geom) / v_grid_res) * v_grid_res)::int
    INTO v_xmin, v_xmax, v_ymin, v_ymax FROM lcz.lcz_inner_boundary;

    EXECUTE format('INSERT INTO lcz.lcz_grid (gx, gy) SELECT x, y FROM generate_series(%s,%s,%s) AS x, generate_series(%s,%s,%s) AS y WHERE ST_Within(ST_SetSRID(ST_MakePoint(x,y), %s), (SELECT geom FROM lcz.lcz_inner_boundary))',
        v_xmin, v_xmax, v_grid_res, v_ymin, v_ymax, v_grid_res, v_srid);
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES (v_run_id, 'Phase 0 — Study Area & Shared Grids', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_grid));
    UPDATE lcz.lcz_run_metadata SET study_area_geometry = (SELECT geom FROM lcz.lcz_inner_boundary LIMIT 1) WHERE run_id = v_run_id;
    RAISE NOTICE '[Phase 0] Grid: DONE ✓';
    COMMIT;
END $$;

-- Phase 1: BSF
CREATE OR REPLACE PROCEDURE lcz.phase1_bsf()
LANGUAGE plpgsql AS $$
DECLARE
    v_grid_res INTEGER;
    v_srid INTEGER;
    already_done BIGINT;
    expected_rows BIGINT;
BEGIN
    SELECT param_value::integer INTO v_grid_res FROM lcz.lcz_params WHERE param_name = 'grid_resolution';
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_grid;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_bsf_map;
    IF already_done = expected_rows THEN
        RAISE NOTICE '[Phase 1] BSF already complete — skipping.';
        INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
        VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 1 — BSF', now(), now(), 0, 'skipped', expected_rows);
        COMMIT; RETURN;
    END IF;
    RAISE NOTICE '[Phase 1] BSF — running...';
    TRUNCATE lcz.lcz_bsf_buildings, lcz.lcz_bsf_fractions, lcz.lcz_bsf_map;
    INSERT INTO lcz.lcz_bsf_buildings (id, geom) SELECT f.id, ST_Force2D(g.geometry) FROM feature f JOIN geometry_data g ON f.id=g.feature_id WHERE f.objectclass_id=710 AND ST_Intersects(ST_Force2D(g.geometry),(SELECT geom FROM lcz.lcz_inner_boundary));
    INSERT INTO lcz.lcz_bsf_fractions (gx, gy, bsf_value) WITH cell_envelopes AS (SELECT gx,gy,ST_SetSRID(ST_MakeEnvelope(gx,gy,gx+v_grid_res,gy+v_grid_res), v_srid) AS geom FROM lcz.lcz_grid) SELECT c.gx,c.gy,ST_Area(ST_Union(ST_Intersection(c.geom,b.geom)))/(v_grid_res*v_grid_res)::numeric FROM cell_envelopes c JOIN lcz.lcz_bsf_buildings b ON ST_Intersects(c.geom,b.geom) GROUP BY c.gx,c.gy;
    INSERT INTO lcz.lcz_bsf_map (gx, gy, geom, bsf_value) SELECT g.gx, g.gy, ST_SetSRID(ST_MakePoint(g.gx,g.gy), v_srid), COALESCE(b.bsf_value,0)::numeric(4,3) FROM lcz.lcz_grid g LEFT JOIN lcz.lcz_bsf_fractions b ON g.gx=b.gx AND g.gy=b.gy;
    REFRESH MATERIALIZED VIEW lcz.lcz_bsf_mat_view;
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 1 — BSF', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_bsf_map));
    RAISE NOTICE '[Phase 1] BSF: DONE ✓';
    COMMIT;
END $$;

-- Phase 2: ISF
CREATE OR REPLACE PROCEDURE lcz.phase2_isf()
LANGUAGE plpgsql AS $$
DECLARE
    v_default_imperv NUMERIC;
    v_tree_pit_radius NUMERIC;
    v_srid INTEGER;
    v_grid_res INTEGER;
    already_done BIGINT;
    expected_rows BIGINT;
BEGIN
    SELECT param_value::numeric INTO v_default_imperv FROM lcz.lcz_params WHERE param_name = 'landuse_default_imperv';
    SELECT param_value::numeric INTO v_tree_pit_radius FROM lcz.lcz_params WHERE param_name = 'tree_pit_radius';
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT param_value::integer INTO v_grid_res FROM lcz.lcz_params WHERE param_name = 'grid_resolution';

    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_grid;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_isf_map;
    IF already_done = expected_rows THEN
        RAISE NOTICE '[Phase 2] ISF already complete — skipping.';
        INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
        VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 2 — ISF', now(), now(), 0, 'skipped', expected_rows);
        COMMIT; RETURN;
    END IF;

    RAISE NOTICE '[Phase 2] ISF — running...';

    -- Buildings
    TRUNCATE TABLE lcz.lcz_isf_buildings;
    INSERT INTO lcz.lcz_isf_buildings (id, geom)
    SELECT f.id, ST_Force2D(g.geometry) AS geom
    FROM feature f JOIN geometry_data g ON f.id = g.feature_id
    WHERE f.objectclass_id = 710
      AND ST_Intersects(ST_Force2D(g.geometry), (SELECT geom FROM lcz.lcz_inner_boundary));

    -- Tree pits
    TRUNCATE TABLE lcz.lcz_isf_tree_pits;
    INSERT INTO lcz.lcz_isf_tree_pits (id, geom)
    SELECT f.id, ST_Buffer(ST_Force2D(ST_Centroid(f.envelope)), v_tree_pit_radius) AS geom
    FROM feature f
    WHERE f.objectclass_id = 1301 AND f.envelope IS NOT NULL
      AND ST_Intersects(ST_Force2D(ST_Centroid(f.envelope)), (SELECT geom FROM lcz.lcz_inner_boundary));

    -- Land‑use impervious layer (hybrid numeric + text exceptions via lookup table)
    TRUNCATE TABLE lcz.lcz_isf_landuse;
    INSERT INTO lcz.lcz_isf_landuse (id, geom, imperv_coeff)
    SELECT lu.id,
           ST_Difference(
               ST_Difference(
                   lu.geom,
                   COALESCE((SELECT ST_Union(b.geom) FROM lcz.lcz_isf_buildings b WHERE ST_Intersects(lu.geom, b.geom)),
                            ST_GeomFromText('POLYGON EMPTY', v_srid))
               ),
               COALESCE((SELECT ST_Union(t.geom) FROM lcz.lcz_isf_tree_pits t WHERE ST_Intersects(lu.geom, t.geom)),
                        ST_GeomFromText('POLYGON EMPTY', v_srid))
           ) AS geom,
           lu.imperv_coeff
    FROM (
        -- Single unified query using the configurable lookup table
        SELECT f.id,
               ST_Force2D(ST_CollectionExtract(ST_ForceCollection(g.geometry), 3)) AS geom,
               COALESCE(
                   spec.imperv_coeff,                -- exact match on class + usage + bez
                   usage_def.imperv_coeff,           -- default for class + usage (bez_text IS NULL)
                   class_def.imperv_coeff,           -- generic class fallback (usage_code IS NULL, bez_text IS NULL)
                   v_default_imperv                  -- ultimate fallback from lcz_params
               ) AS imperv_coeff
        FROM feature f
        JOIN geometry_data g ON f.id = g.feature_id
        LEFT JOIN property p_class ON f.id = p_class.feature_id AND p_class.name = 'class'
        LEFT JOIN property p_bez   ON f.id = p_bez.feature_id   AND p_bez.name   = 'bez'
        LEFT JOIN property p_usage ON f.id = p_usage.feature_id AND p_usage.name = 'usage'
        LEFT JOIN lcz.lcz_landuse_impervious spec
               ON p_class.val_string = spec.class_code
               AND p_usage.val_string = spec.usage_code
               AND p_bez.val_string   = spec.bez_text
        LEFT JOIN lcz.lcz_landuse_impervious usage_def
               ON p_class.val_string = usage_def.class_code
               AND p_usage.val_string = usage_def.usage_code
               AND usage_def.bez_text IS NULL
        LEFT JOIN lcz.lcz_landuse_impervious class_def
               ON p_class.val_string = class_def.class_code
               AND class_def.usage_code IS NULL
               AND class_def.bez_text IS NULL
        WHERE f.objectclass_id = 300
          AND ST_Intersects(
                ST_Force2D(ST_CollectionExtract(ST_ForceCollection(g.geometry), 3)),
                (SELECT geom FROM lcz.lcz_inner_boundary)
              )
    ) lu;

    -- Building fractions per 2m cell
    TRUNCATE TABLE lcz.lcz_isf_building_fractions;
    INSERT INTO lcz.lcz_isf_building_fractions (gx, gy, b_geom, bsf_fraction)
    WITH cell_envelopes AS (
        SELECT gx, gy, ST_SetSRID(ST_MakeEnvelope(gx, gy, gx + v_grid_res, gy + v_grid_res), v_srid) AS geom
        FROM lcz.lcz_grid
    )
    SELECT c.gx, c.gy,
           ST_Union(ST_Intersection(c.geom, b.geom)) AS b_geom,
           ST_Area(ST_Union(ST_Intersection(c.geom, b.geom))) / (v_grid_res * v_grid_res) AS bsf_fraction
    FROM cell_envelopes c JOIN lcz.lcz_isf_buildings b ON ST_Intersects(c.geom, b.geom)
    GROUP BY c.gx, c.gy;

    -- Land‑use fractions per 2m cell
    TRUNCATE TABLE lcz.lcz_isf_landuse_fractions;
    INSERT INTO lcz.lcz_isf_landuse_fractions (gx, gy, residual_isf)
    WITH cell_envelopes AS (
        SELECT gx, gy, ST_SetSRID(ST_MakeEnvelope(gx, gy, gx + v_grid_res, gy + v_grid_res), v_srid) AS geom
        FROM lcz.lcz_grid
    )
    SELECT c.gx, c.gy,
           SUM(ST_Area(ST_Intersection(
                   ST_Difference(c.geom, COALESCE(bd.b_geom, ST_GeomFromText('POLYGON EMPTY', v_srid))),
                   lu.geom)) * lu.imperv_coeff) / (v_grid_res * v_grid_res) AS residual_isf
    FROM cell_envelopes c
    LEFT JOIN lcz.lcz_isf_building_fractions bd ON c.gx = bd.gx AND c.gy = bd.gy
    JOIN lcz.lcz_isf_landuse lu ON ST_Intersects(c.geom, lu.geom)
    GROUP BY c.gx, c.gy;

    -- Final ISF map
    TRUNCATE TABLE lcz.lcz_isf_map;
    INSERT INTO lcz.lcz_isf_map (gx, gy, geom, isf_value)
    SELECT g.gx, g.gy,
           ST_SetSRID(ST_MakePoint(g.gx, g.gy), v_srid) AS geom,
           GREATEST(LEAST(COALESCE(lu.residual_isf, 0), 1.0), 0)::numeric(4,3) AS isf_value
    FROM lcz.lcz_grid g
    LEFT JOIN lcz.lcz_isf_landuse_fractions lu ON g.gx = lu.gx AND g.gy = lu.gy;

    REFRESH MATERIALIZED VIEW lcz.lcz_isf_mat_view;

    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 2 — ISF', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_isf_map));
    RAISE NOTICE '[Phase 2] ISF: DONE ✓';
    COMMIT;
END $$;

-- Phase 3: PSF
CREATE OR REPLACE PROCEDURE lcz.phase3_psf()
LANGUAGE plpgsql AS $$
DECLARE already_done BIGINT; expected_rows BIGINT;
    v_srid INTEGER;
BEGIN
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_grid;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_psf_map;
    IF already_done = expected_rows THEN
        RAISE NOTICE '[Phase 3] PSF already complete — skipping.';
        INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
        VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 3 — PSF', now(), now(), 0, 'skipped', expected_rows);
        COMMIT; RETURN;
    END IF;
    RAISE NOTICE '[Phase 3] PSF — running...';
    TRUNCATE lcz.lcz_psf_map;
    INSERT INTO lcz.lcz_psf_map (gx, gy, geom, psf_value) SELECT g.gx, g.gy, ST_SetSRID(ST_MakePoint(g.gx,g.gy), v_srid), GREATEST(1.0-COALESCE(b.bsf_value,0)-COALESCE(i.isf_value,0),0.0)::numeric(4,3) FROM lcz.lcz_grid g LEFT JOIN lcz.lcz_bsf_map b ON g.gx=b.gx AND g.gy=b.gy LEFT JOIN lcz.lcz_isf_map i ON g.gx=i.gx AND g.gy=i.gy;
    REFRESH MATERIALIZED VIEW lcz.lcz_psf_mat_view;
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 3 — PSF', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_psf_map));
    RAISE NOTICE '[Phase 3] PSF: DONE ✓';
    COMMIT;
END $$;

-- Phase 4: Height
CREATE OR REPLACE PROCEDURE lcz.phase4_height()
LANGUAGE plpgsql AS $$
DECLARE v_grid_res INTEGER; already_done BIGINT; expected_rows BIGINT;
    v_srid INTEGER;
BEGIN
    SELECT param_value::integer INTO v_grid_res FROM lcz.lcz_params WHERE param_name = 'grid_resolution';
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_grid;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_height_map;
    IF already_done = expected_rows THEN
        RAISE NOTICE '[Phase 4] Height already complete — skipping.';
        INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
        VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 4 — Height', now(), now(), 0, 'skipped', expected_rows);
        COMMIT; RETURN;
    END IF;
    RAISE NOTICE '[Phase 4] Height — running...';
    TRUNCATE lcz.lcz_height_buildings, lcz.lcz_height_fractions, lcz.lcz_height_map;
    INSERT INTO lcz.lcz_height_buildings (building_id, geom, building_height)
    WITH ground AS (SELECT SUBSTRING(f.objectid FROM 'DEBY_LOD2_(\d+)_') AS building_id, ST_Force2D(g.geometry) AS footprint_2d FROM feature f JOIN geometry_data g ON f.id=g.feature_id WHERE f.objectclass_id=710 AND ST_Intersects(ST_Force2D(g.geometry),(SELECT geom FROM lcz.lcz_inner_boundary))),
         roof AS (SELECT SUBSTRING(f.objectid FROM 'DEBY_LOD2_(\d+)_') AS building_id, MAX(p.val_string::numeric) AS roof_z_max FROM feature f JOIN property p ON f.id=p.feature_id WHERE f.objectclass_id=712 AND p.name='Z_MAX' GROUP BY SUBSTRING(f.objectid FROM 'DEBY_LOD2_(\d+)_'))
    SELECT g.building_id, g.footprint_2d, r.roof_z_max FROM ground g JOIN roof r ON g.building_id=r.building_id WHERE r.roof_z_max>0;
    INSERT INTO lcz.lcz_height_fractions (gx, gy, height_value) WITH cell_envelopes AS (SELECT gx,gy,ST_SetSRID(ST_MakeEnvelope(gx,gy,gx+v_grid_res,gy+v_grid_res), v_srid) AS geom FROM lcz.lcz_grid) SELECT c.gx,c.gy, EXP(SUM(ST_Area(ST_Intersection(c.geom,b.geom))*LN(b.building_height)) / NULLIF(SUM(ST_Area(ST_Intersection(c.geom,b.geom))),0))::numeric(6,2) FROM cell_envelopes c JOIN lcz.lcz_height_buildings b ON ST_Intersects(c.geom,b.geom) GROUP BY c.gx,c.gy;
    INSERT INTO lcz.lcz_height_map (gx, gy, geom, height_value) SELECT g.gx, g.gy, ST_SetSRID(ST_MakePoint(g.gx,g.gy), v_srid), h.height_value FROM lcz.lcz_grid g LEFT JOIN lcz.lcz_height_fractions h ON g.gx=h.gx AND g.gy=h.gy;
    REFRESH MATERIALIZED VIEW lcz.lcz_height_mat_view;
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 4 — Height', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_height_map));
    RAISE NOTICE '[Phase 4] Height: DONE ✓';
    COMMIT;
END $$;

-- Phase 5a: Build obstacle tables
CREATE OR REPLACE PROCEDURE lcz.phase5_build_obstacles()
LANGUAGE plpgsql AS $$
DECLARE
    v_include_trees TEXT;
    v_tree_crown_ratio NUMERIC;
    v_edge_buffer NUMERIC;
    v_srid INTEGER;
BEGIN
    SELECT param_value::text    INTO v_include_trees   FROM lcz.lcz_params WHERE param_name = 'include_trees_in_svf';
    SELECT param_value::numeric INTO v_tree_crown_ratio FROM lcz.lcz_params WHERE param_name = 'tree_crown_ratio';
    SELECT param_value::numeric INTO v_edge_buffer      FROM lcz.lcz_params WHERE param_name = 'svf_edge_buffer';
    SELECT param_value::integer INTO v_srid             FROM lcz.lcz_params WHERE param_name = 'srid';

    RAISE NOTICE '[Phase 5] Building obstacle tables...';

    -- Buildings
    TRUNCATE TABLE lcz.lcz_svf_buildings;
    EXECUTE format('INSERT INTO lcz.lcz_svf_buildings (building_id, footprint_2d, ground_z)
        SELECT f.id AS building_id, ST_Force2D(ST_CollectionExtract(g.geometry,3)) AS footprint_2d, ST_ZMin(g.geometry) AS ground_z
        FROM feature f JOIN geometry_data g ON f.id=g.feature_id
        WHERE f.objectclass_id=901 AND g.geometry && ST_SetSRID(ST_MakeEnvelope(%s,%s,%s,%s), %s)',
        (SELECT ST_XMin(geom)-v_edge_buffer FROM lcz.lcz_inner_boundary),
        (SELECT ST_YMin(geom)-v_edge_buffer FROM lcz.lcz_inner_boundary),
        (SELECT ST_XMax(geom)+v_edge_buffer FROM lcz.lcz_inner_boundary),
        (SELECT ST_YMax(geom)+v_edge_buffer FROM lcz.lcz_inner_boundary),
        v_srid);

    -- Roof obstacles
    TRUNCATE TABLE lcz.lcz_svf_roof_obstacles;
    EXECUTE format('INSERT INTO lcz.lcz_svf_roof_obstacles (roof_id, footprint_2d, relative_height)
        SELECT DISTINCT ON (f.id)
               f.id AS roof_id,
               ST_Force2D(ST_CollectionExtract(g.geometry,3)) AS footprint_2d,
               (ST_ZMax(g.geometry)-b.ground_z)::numeric(5,2) AS relative_height
        FROM feature f JOIN geometry_data g ON f.id=g.feature_id
        JOIN lcz.lcz_svf_buildings b
          ON ST_Intersects(ST_Force2D(ST_CollectionExtract(g.geometry,3)), b.footprint_2d)
        WHERE f.objectclass_id=712 AND g.geometry && ST_SetSRID(ST_MakeEnvelope(%s,%s,%s,%s), %s)
        ORDER BY f.id, ST_ZMax(g.geometry) - b.ground_z',
        (SELECT ST_XMin(geom)-v_edge_buffer FROM lcz.lcz_inner_boundary),
        (SELECT ST_YMin(geom)-v_edge_buffer FROM lcz.lcz_inner_boundary),
        (SELECT ST_XMax(geom)+v_edge_buffer FROM lcz.lcz_inner_boundary),
        (SELECT ST_YMax(geom)+v_edge_buffer FROM lcz.lcz_inner_boundary),
        v_srid);

    -- Tree obstacles
    TRUNCATE TABLE lcz.lcz_svf_tree_obstacles;
    IF v_include_trees='true' THEN
        EXECUTE format('INSERT INTO lcz.lcz_svf_tree_obstacles (tree_id, footprint_2d, relative_height)
            SELECT -f.id AS tree_id, ST_Buffer(ST_Force2D(ST_Centroid(f.envelope)),(p.val_array->0)::numeric*%s) AS footprint_2d,
                   (p.val_array->0)::numeric(5,2) AS relative_height
            FROM feature f JOIN property p ON f.id=p.feature_id AND p.name=''lod2ImplicitRepresentation'' AND p.val_array IS NOT NULL
            WHERE f.objectclass_id=1301 AND f.envelope IS NOT NULL AND (p.val_array->0)::numeric>0
            AND ST_Within(ST_Force2D(ST_Centroid(f.envelope)),(SELECT ST_Buffer(geom,%s) FROM lcz.lcz_inner_boundary))', v_tree_crown_ratio, v_edge_buffer);
    ELSE
        NULL;
    END IF;

    -- Combined obstacles
    TRUNCATE TABLE lcz.lcz_svf_all_obstacles;
    INSERT INTO lcz.lcz_svf_all_obstacles (footprint_2d, relative_height)
    SELECT footprint_2d, relative_height FROM lcz.lcz_svf_roof_obstacles
    UNION ALL
    SELECT footprint_2d, relative_height FROM lcz.lcz_svf_tree_obstacles;

    COMMIT;
    RAISE NOTICE '[Phase 5] Obstacle tables ready.';
END $$;

CREATE OR REPLACE PROCEDURE lcz.phase5_build_terrain_grid()
LANGUAGE plpgsql AS $$
DECLARE
    v_spacing NUMERIC;
    v_srid INTEGER;
BEGIN
    SELECT param_value::numeric INTO v_spacing FROM lcz.lcz_params WHERE param_name = 'terrain_grid_spacing';
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';

    RAISE NOTICE '[Phase 5] Building terrain grid (spacing % m)...', v_spacing;

    TRUNCATE lcz.lcz_terrain_grid;

    WITH bounds AS (
        SELECT ST_XMin(geom) AS xmin, ST_XMax(geom) AS xmax,
               ST_YMin(geom) AS ymin, ST_YMax(geom) AS ymax
        FROM lcz.lcz_inner_boundary
    ),
    grid_points AS (
        SELECT
            x::numeric AS x,
            y::numeric AS y,
            ST_SetSRID(ST_MakePoint(x::numeric, y::numeric, 0), v_srid) AS geom
        FROM bounds,
             generate_series(
                 (floor(xmin / v_spacing) * v_spacing)::numeric,
                 (ceil(xmax / v_spacing) * v_spacing)::numeric,
                 v_spacing::numeric
             ) AS x,
             generate_series(
                 (floor(ymin / v_spacing) * v_spacing)::numeric,
                 (ceil(ymax / v_spacing) * v_spacing)::numeric,
                 v_spacing::numeric
             ) AS y
        WHERE ST_Within(
            ST_SetSRID(ST_MakePoint(x::numeric, y::numeric), v_srid),
            (SELECT geom FROM lcz.lcz_inner_boundary)
        )
    ),
    z_values AS (
        SELECT gp.x, gp.y,
               MIN(
                   ST_Z(
                       ST_3DClosestPoint(
                           g.geometry,
                           ST_SetSRID(
                               ST_MakeLine(
                                   ST_MakePoint(gp.x, gp.y, 0),
                                   ST_MakePoint(gp.x, gp.y, 1000)
                               ), v_srid
                           )
                       )
                   )
               ) AS terrain_z
        FROM grid_points gp
        JOIN feature f ON f.objectclass_id = 300
        JOIN geometry_data g ON g.feature_id = f.id
        WHERE ST_Intersects(ST_Force2D(g.geometry), gp.geom)
        GROUP BY gp.x, gp.y
    )
    INSERT INTO lcz.lcz_terrain_grid (gx, gy, z, geom)
    SELECT x, y, terrain_z, ST_SetSRID(ST_MakePoint(x, y), v_srid)
    FROM z_values;

    RAISE NOTICE '[Phase 5] Terrain grid created with % points.', (SELECT COUNT(*) FROM lcz.lcz_terrain_grid);
END $$;

CREATE OR REPLACE PROCEDURE lcz.phase5_process_terrain_strip(
    x_start INTEGER,
    strip_number INTEGER,
    total_strips INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_svf_radius   NUMERIC;
    v_svf_ray_step NUMERIC;
    v_srid         INTEGER;
    v_spacing      NUMERIC;
    v_base_x       NUMERIC;
    v_base_y       NUMERIC;
    v_min_gx       NUMERIC;
    v_max_gx       NUMERIC;
    v_min_gy       NUMERIC;
    v_max_gy       NUMERIC;
    v_directions   INTEGER;
    expected_rows  BIGINT;
    already_done   BIGINT;
BEGIN
    SELECT param_value::numeric INTO v_svf_radius   FROM lcz.lcz_params WHERE param_name = 'svf_radius';
    SELECT param_value::numeric INTO v_svf_ray_step FROM lcz.lcz_params WHERE param_name = 'svf_ray_step';
    SELECT param_value::numeric INTO v_spacing      FROM lcz.lcz_params WHERE param_name = 'terrain_grid_spacing';
    SELECT param_value::integer INTO v_srid         FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT param_value::integer INTO v_directions   FROM lcz.lcz_params WHERE param_name = 'svf_directions';

    SELECT MIN(gx), MAX(gx), MIN(gy), MAX(gy)
      INTO v_min_gx, v_max_gx, v_min_gy, v_max_gy
    FROM lcz.lcz_terrain_grid;
    v_base_x := v_min_gx;
    v_base_y := v_min_gy;

    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_grid WHERE gx >= x_start AND gx < x_start + 40;
    expected_rows := expected_rows * v_directions;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_svf_terrain_results WHERE gx >= x_start AND gx < x_start + 40;

    IF already_done >= expected_rows AND expected_rows > 0 THEN
        IF strip_number % 10 = 0 THEN
            RAISE NOTICE '[Terrain SVF] Strip %/% skipped (already done).', strip_number, total_strips;
        END IF;
        COMMIT;
        RETURN;
    ELSIF already_done > 0 THEN
        DELETE FROM lcz.lcz_svf_terrain_results WHERE gx >= x_start AND gx < x_start + 40;
    END IF;

    WITH origins AS (
        SELECT g.gx, g.gy,
               t.z AS origin_terrain_z
        FROM lcz.lcz_grid g
        LEFT JOIN lcz.lcz_terrain_grid t
          ON t.gx = GREATEST(v_min_gx, LEAST(v_max_gx,
                      v_base_x + round((g.gx - v_base_x) / v_spacing) * v_spacing))
         AND t.gy = GREATEST(v_min_gy, LEAST(v_max_gy,
                      v_base_y + round((g.gy - v_base_y) / v_spacing) * v_spacing))
        WHERE g.gx >= x_start AND g.gx < x_start + 40
    ),
    steps AS (
        SELECT o.gx, o.gy, o.origin_terrain_z, dir.direction_id, step.s,
               o.gx + dir.dx * step.s AS sx,
               o.gy + dir.dy * step.s AS sy
        FROM origins o
        CROSS JOIN lcz.lcz_svf_ray_dictionary dir
        CROSS JOIN generate_series(v_svf_ray_step::numeric, v_svf_radius, v_svf_ray_step::numeric) AS step(s)
        WHERE dir.direction_id <= v_directions
    )
    INSERT INTO lcz.lcz_svf_terrain_results (gx, gy, direction_id, max_alpha)
    SELECT s.gx, s.gy, s.direction_id,
           MAX(
               CASE
                   WHEN t.z > s.origin_terrain_z
                            + (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name = 'svf_observer_height')
                   THEN ATAN2(
                            (t.z - s.origin_terrain_z
                                 - (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name = 'svf_observer_height')),
                            s.s)
                   ELSE 0
               END
           ) AS max_alpha

    FROM steps s
    LEFT JOIN lcz.lcz_terrain_grid t
      ON t.gx = GREATEST(v_min_gx, LEAST(v_max_gx,
                  v_base_x + round((s.sx - v_base_x) / v_spacing) * v_spacing))
     AND t.gy = GREATEST(v_min_gy, LEAST(v_max_gy,
                  v_base_y + round((s.sy - v_base_y) / v_spacing) * v_spacing))
    GROUP BY s.gx, s.gy, s.direction_id;

    IF strip_number % 10 = 0 THEN
        RAISE NOTICE '[Terrain SVF] Strip %/% completed.', strip_number, total_strips;
    END IF;

    COMMIT;
END $$;
-- Phase 5b: Process a single 40‑m strip
CREATE OR REPLACE PROCEDURE lcz.phase5_process_strip(
    x_start INTEGER,
    strip_number INTEGER,
    total_strips INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_svf_radius NUMERIC;
    v_svf_ray_step NUMERIC;
    v_srid INTEGER;
    v_directions INTEGER;
    expected_rows BIGINT;
    already_done BIGINT;
BEGIN
    SELECT param_value::numeric INTO v_svf_radius   FROM lcz.lcz_params WHERE param_name = 'svf_radius';
    SELECT param_value::numeric INTO v_svf_ray_step FROM lcz.lcz_params WHERE param_name = 'svf_ray_step';
    SELECT param_value::integer INTO v_srid         FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT param_value::integer INTO v_directions   FROM lcz.lcz_params WHERE param_name = 'svf_directions';

    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_grid WHERE gx>=x_start AND gx<x_start+40;
    expected_rows := expected_rows * v_directions;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_svf_ray_results WHERE gx>=x_start AND gx<x_start+40;

    IF already_done >= expected_rows AND expected_rows > 0 THEN
        IF strip_number % 10 = 0 THEN
            RAISE NOTICE '[SVF] Strip %/% skipped (already done).', strip_number, total_strips;
        END IF;
        COMMIT;
        RETURN;
    ELSIF already_done > 0 THEN
        DELETE FROM lcz.lcz_svf_ray_results WHERE gx>=x_start AND gx<x_start+40;
    END IF;

    INSERT INTO lcz.lcz_svf_ray_results (gx, gy, direction_id, max_alpha)
    WITH current_grid AS (
        SELECT r.gx, r.gy,
               ST_SetSRID(ST_MakePoint(r.gx, r.gy), v_srid) AS geom,
               (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name = 'svf_observer_height') AS obs_z
        FROM lcz.lcz_grid r
        WHERE r.gx >= x_start AND r.gx < x_start + 40
    )
    SELECT o.gx,o.gy,dir.direction_id,
           MAX(COALESCE(CASE WHEN b.relative_height>o.obs_z THEN ATAN2((b.relative_height-o.obs_z),step.s) ELSE 0 END,0)) AS max_alpha
    FROM current_grid o
    CROSS JOIN lcz.lcz_svf_ray_dictionary dir
    CROSS JOIN generate_series(v_svf_ray_step::numeric,v_svf_radius,v_svf_ray_step::numeric) AS step(s)
    LEFT JOIN lcz.lcz_svf_all_obstacles b ON b.footprint_2d && ST_Translate(o.geom,dir.dx*step.s,dir.dy*step.s)
        AND ST_Intersects(ST_Translate(o.geom,dir.dx*step.s,dir.dy*step.s),b.footprint_2d)
    WHERE dir.direction_id <= v_directions
    GROUP BY o.gx,o.gy,dir.direction_id;

    IF strip_number % 10 = 0 THEN
        RAISE NOTICE '[SVF] Strip %/% completed.', strip_number, total_strips;
    END IF;

    COMMIT;
END $$;

-- Phase 6: Aspect Ratio
CREATE OR REPLACE PROCEDURE lcz.phase6_ar()
LANGUAGE plpgsql AS $$
DECLARE v_class_grid_res INTEGER; v_ar_cell_area NUMERIC;
    v_xmin INTEGER; v_xmax INTEGER; v_ymin INTEGER; v_ymax INTEGER;
    v_srid INTEGER;
    already_done BIGINT; expected_rows BIGINT;
BEGIN
    SELECT param_value::integer INTO v_class_grid_res FROM lcz.lcz_params WHERE param_name = 'class_grid_resolution';
    SELECT param_value::numeric INTO v_ar_cell_area FROM lcz.lcz_params WHERE param_name = 'ar_cell_area';
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_ar_grid_100m;
    IF expected_rows = 0 THEN
        SELECT (floor(ST_XMin(geom)/v_class_grid_res)*v_class_grid_res)::int,(ceil(ST_XMax(geom)/v_class_grid_res)*v_class_grid_res)::int,(floor(ST_YMin(geom)/v_class_grid_res)*v_class_grid_res)::int,(ceil(ST_YMax(geom)/v_class_grid_res)*v_class_grid_res)::int INTO v_xmin,v_xmax,v_ymin,v_ymax FROM lcz.lcz_inner_boundary;
        TRUNCATE lcz.lcz_ar_grid_100m;
        EXECUTE format('INSERT INTO lcz.lcz_ar_grid_100m (gx, gy, geom) SELECT x,y,ST_SetSRID(ST_MakeEnvelope(x,y,x+%s,y+%s), %s) FROM generate_series(%s,%s,%s) AS x, generate_series(%s,%s,%s) AS y WHERE ST_Within(ST_SetSRID(ST_MakeEnvelope(x,y,x+%s,y+%s), %s),(SELECT geom FROM lcz.lcz_inner_boundary))',
            v_class_grid_res, v_class_grid_res, v_srid,
            v_xmin, v_xmax, v_class_grid_res, v_ymin, v_ymax, v_class_grid_res,
            v_class_grid_res, v_class_grid_res, v_srid);
        SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_ar_grid_100m;
    END IF;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_ar_map;
    IF already_done = expected_rows THEN
        RAISE NOTICE '[Phase 6] AR already complete — skipping.';
        INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
        VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 6 — Aspect Ratio', now(), now(), 0, 'skipped', expected_rows);
        COMMIT; RETURN;
    END IF;
    RAISE NOTICE '[Phase 6] AR — running...';
    TRUNCATE lcz.lcz_ar_facade, lcz.lcz_ar_bsf_100m, lcz.lcz_ar_height_100m, lcz.lcz_ar_map;
    INSERT INTO lcz.lcz_ar_facade (gx, gy, total_facade_area, wall_count)
    WITH wall_areas AS (
        SELECT f.id,
               ST_Centroid(ST_Force2D(g.geometry)) AS centroid_2d,
               p.val_string::numeric AS facade_area
        FROM feature f
        JOIN geometry_data g ON f.id = g.feature_id
        JOIN property p ON f.id = p.feature_id AND p.name = 'Flaeche'
        WHERE f.objectclass_id = 709
          AND ST_Intersects(ST_Force2D(g.geometry), (SELECT geom FROM lcz.lcz_inner_boundary))
    )
    SELECT gr.gx, gr.gy, SUM(w.facade_area), COUNT(*)
    FROM lcz.lcz_ar_grid_100m gr
    JOIN wall_areas w ON ST_Contains(gr.geom, w.centroid_2d)
    GROUP BY gr.gx, gr.gy;

    EXECUTE format('INSERT INTO lcz.lcz_ar_bsf_100m (gx, gy, mean_bsf) SELECT floor(gx/%s)::int*%s, floor(gy/%s)::int*%s, AVG(bsf_value) FROM lcz.lcz_bsf_mat_view GROUP BY 1,2',v_class_grid_res,v_class_grid_res,v_class_grid_res,v_class_grid_res);
    INSERT INTO lcz.lcz_ar_height_100m (gx, gy, mean_height) WITH cell_building AS (SELECT g.gx,g.gy,ST_Area(ST_Intersection(g.geom,b.geom)) AS intersect_area,b.building_height FROM lcz.lcz_ar_grid_100m g JOIN lcz.lcz_height_buildings b ON ST_Intersects(g.geom,b.geom) WHERE b.building_height>0) SELECT gx,gy,EXP(SUM(intersect_area*LN(building_height))/NULLIF(SUM(intersect_area),0)) FROM cell_building GROUP BY gx,gy HAVING SUM(intersect_area)>0;
    INSERT INTO lcz.lcz_ar_map (gx, gy, geom, mean_height, total_facade_area, wall_count, mean_bsf, ar_value) SELECT g.gx, g.gy, ST_SetSRID(ST_MakePoint(g.gx+v_class_grid_res/2,g.gy+v_class_grid_res/2), v_srid), h.mean_height, COALESCE(f.total_facade_area,0), COALESCE(f.wall_count,0), b.mean_bsf, CASE WHEN b.mean_bsf<=0 OR b.mean_bsf>=0.95 THEN NULL ELSE LEAST(0.5*COALESCE(f.total_facade_area,0)/v_ar_cell_area/NULLIF(1.0-b.mean_bsf,0),10.0)::numeric(8,3) END FROM lcz.lcz_ar_grid_100m g LEFT JOIN lcz.lcz_ar_height_100m h ON g.gx=h.gx AND g.gy=h.gy LEFT JOIN lcz.lcz_ar_facade f ON g.gx=f.gx AND g.gy=f.gy LEFT JOIN lcz.lcz_ar_bsf_100m b ON g.gx=b.gx AND g.gy=b.gy;
    REFRESH MATERIALIZED VIEW lcz.lcz_ar_mat_view;
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 6 — Aspect Ratio', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_ar_map));
    RAISE NOTICE '[Phase 6] AR: DONE ✓';
    COMMIT;
END $$;

-- Phase 7: Classification
CREATE OR REPLACE PROCEDURE lcz.phase7_classification()
LANGUAGE plpgsql AS $$
DECLARE v_class_grid_res INTEGER; v_ar_cell_area NUMERIC;
    v_srid INTEGER;
    already_done BIGINT; expected_rows BIGINT;
BEGIN
    SELECT param_value::integer INTO v_class_grid_res FROM lcz.lcz_params WHERE param_name = 'class_grid_resolution';
    SELECT param_value::numeric INTO v_ar_cell_area FROM lcz.lcz_params WHERE param_name = 'ar_cell_area';
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_ar_grid_100m;
    SELECT COUNT(*) INTO already_done FROM lcz.lcz_map;
    IF already_done = expected_rows THEN
        RAISE NOTICE '[Phase 7] Classification already complete — skipping.';
        INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
        VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 7 — Aggregation & Classification', now(), now(), 0, 'skipped', expected_rows);
        COMMIT; RETURN;
    END IF;

    RAISE NOTICE '[Phase 7] Classification — running...';

    TRUNCATE lcz.lcz_aggregate_svf_100m, lcz.lcz_aggregate_isf_100m, lcz.lcz_trc_trees, lcz.lcz_trc_elements,
             lcz.lcz_100m_params, lcz.lcz_map, lcz.lcz_map_polygons;

    EXECUTE format('INSERT INTO lcz.lcz_aggregate_svf_100m (gx, gy, svf_mean) SELECT floor(gx/%s)::int*%s, floor(gy/%s)::int*%s, AVG(svf_value) FROM lcz.lcz_svf_mat_view GROUP BY 1,2',v_class_grid_res,v_class_grid_res,v_class_grid_res,v_class_grid_res);
    EXECUTE format('INSERT INTO lcz.lcz_aggregate_isf_100m (gx, gy, isf_mean) SELECT floor(gx/%s)::int*%s, floor(gy/%s)::int*%s, AVG(isf_value) FROM lcz.lcz_isf_mat_view GROUP BY 1,2',v_class_grid_res,v_class_grid_res,v_class_grid_res,v_class_grid_res);
    INSERT INTO lcz.lcz_trc_trees (gx, gy, tree_count, mean_tree_height, total_tree_area)
    SELECT g.gx, g.gy,
           COUNT(*),
           AVG((p.val_array->0)::numeric),
           SUM(
               POWER((p.val_array->0)::numeric
                     * (SELECT param_value::numeric FROM lcz.lcz_params WHERE param_name = 'tree_crown_ratio'),
                     2) * pi()
           )
    FROM lcz.lcz_ar_grid_100m g
    JOIN feature f ON f.objectclass_id=1301 AND f.envelope IS NOT NULL AND ST_Within(ST_Force2D(ST_Centroid(f.envelope)),g.geom)
    JOIN property p ON p.feature_id=f.id AND p.name='lod2ImplicitRepresentation' AND p.val_array IS NOT NULL AND (p.val_array->0)::numeric>0
    GROUP BY g.gx,g.gy;

    INSERT INTO lcz.lcz_trc_elements (gx, gy, z_h, bsf, lambda_f, tree_count, mean_tree_height) SELECT g.gx, g.gy, (COALESCE(h.mean_height*b.mean_bsf*v_ar_cell_area,0)+COALESCE(t.mean_tree_height*t.total_tree_area,0))/NULLIF(COALESCE(b.mean_bsf*v_ar_cell_area,0)+COALESCE(t.total_tree_area,0),0), COALESCE(b.mean_bsf,0), COALESCE(f.total_facade_area,0)/4.0/v_ar_cell_area, COALESCE(t.tree_count,0), COALESCE(t.mean_tree_height,0) FROM lcz.lcz_ar_grid_100m g LEFT JOIN lcz.lcz_ar_height_100m h ON g.gx=h.gx AND g.gy=h.gy LEFT JOIN lcz.lcz_ar_bsf_100m b ON g.gx=b.gx AND g.gy=b.gy LEFT JOIN lcz.lcz_ar_facade f ON g.gx=f.gx AND g.gy=f.gy LEFT JOIN lcz.lcz_trc_trees t ON g.gx=t.gx AND g.gy=t.gy;
    INSERT INTO lcz.lcz_100m_params (gx, gy, geom, svf, bsf, isf, psf, height, ar) SELECT g.gx, g.gy, ST_SetSRID(ST_MakePoint(g.gx+v_class_grid_res/2,g.gy+v_class_grid_res/2), v_srid), COALESCE(s.svf_mean,0), COALESCE(b.mean_bsf,0), COALESCE(i.isf_mean,0), GREATEST(1.0-COALESCE(b.mean_bsf,0)-COALESCE(i.isf_mean,0),0.0), COALESCE(e.z_h,0), ar.ar_value FROM lcz.lcz_ar_grid_100m g LEFT JOIN lcz.lcz_aggregate_svf_100m s ON g.gx=s.gx AND g.gy=s.gy LEFT JOIN lcz.lcz_ar_bsf_100m b ON g.gx=b.gx AND g.gy=b.gy LEFT JOIN lcz.lcz_aggregate_isf_100m i ON g.gx=i.gx AND g.gy=i.gy LEFT JOIN lcz.lcz_trc_elements e ON g.gx=e.gx AND g.gy=e.gy LEFT JOIN lcz.lcz_ar_map ar ON g.gx=ar.gx AND g.gy=ar.gy;

    -- refresh
    REFRESH MATERIALIZED VIEW lcz.lcz_classification;

    INSERT INTO lcz.lcz_map (gx, gy, geom, lcz_class, lcz_name, distance_sq, svf, bsf, isf, psf, height, ar) SELECT c.gx, c.gy, ST_SetSRID(c.geom, v_srid), c.lcz_class, c.lcz_name, c.distance_sq, p.svf, p.bsf, p.isf, p.psf, p.height, p.ar FROM lcz.lcz_classification c JOIN lcz.lcz_100m_params p ON c.gx=p.gx AND c.gy=p.gy;
    EXECUTE format('INSERT INTO lcz.lcz_map_polygons (gx, gy, lcz_class, lcz_name, distance_sq, svf, bsf, isf, psf, height, ar, geom) SELECT gx, gy, lcz_class, lcz_name, distance_sq, svf, bsf, isf, psf, height, ar, ST_SetSRID(ST_MakeEnvelope(gx,gy,gx+%s,gy+%s), %s) FROM lcz.lcz_map',
        v_class_grid_res, v_class_grid_res, v_srid);
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 7 — Aggregation & Classification', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_map));
    RAISE NOTICE '[Phase 7] Classification: DONE ✓';
    COMMIT;
END $$;

-- Phase 10: Dissolve 
CREATE OR REPLACE PROCEDURE lcz.phase10_dissolve()
LANGUAGE plpgsql AS $$
DECLARE
    v_srid INTEGER;
    v_class_grid_res INTEGER;
BEGIN
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT param_value::integer INTO v_class_grid_res FROM lcz.lcz_params WHERE param_name = 'class_grid_resolution';

    RAISE NOTICE '[Phase 10] Rebuilding polygons from corrected map and dissolving...';

    -- 1. Rebuild the polygon table from the lcz_map
    TRUNCATE lcz.lcz_map_polygons;
    EXECUTE format('
        INSERT INTO lcz.lcz_map_polygons
            (gx, gy, lcz_class, lcz_name, distance_sq,
             svf, bsf, isf, psf, height, ar, geom)
        SELECT gx, gy, lcz_class, lcz_name, distance_sq,
               svf, bsf, isf, psf, height, ar,
               ST_SetSRID(ST_MakeEnvelope(gx, gy, gx + %s, gy + %s), %s)
        FROM lcz.lcz_map',
        v_class_grid_res, v_class_grid_res, v_srid);

    -- 2. Dissolve into final multipolygons
    TRUNCATE lcz.lcz_map_dissolved;
    INSERT INTO lcz.lcz_map_dissolved (lcz_class, lcz_name, geom)
    SELECT lcz_class, lcz_name, ST_Multi(ST_Union(geom))
    FROM lcz.lcz_map_polygons
    GROUP BY lcz_class, lcz_name;

    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata),
            'Phase 10 — Dissolve', now(), now(), 0, 'complete',
            (SELECT count(*) FROM lcz.lcz_map_dissolved));

    RAISE NOTICE '[Phase 10] Dissolve: DONE ✓';
    COMMIT;
END $$;

-- Phase 8: Forest cover correction
CREATE OR REPLACE PROCEDURE lcz.phase8_forest_correction()
LANGUAGE plpgsql AS $$
DECLARE
    v_forest_threshold NUMERIC;
    v_class_grid_res   INTEGER;
BEGIN
    SELECT param_value::numeric INTO v_forest_threshold
    FROM lcz.lcz_params WHERE param_name = 'forest_cover_threshold';

    SELECT param_value::integer INTO v_class_grid_res
    FROM lcz.lcz_params WHERE param_name = 'class_grid_resolution';

    IF NOT EXISTS (SELECT 1 FROM lcz.lcz_svf_tree_obstacles) THEN
        RAISE NOTICE '[Phase 8] No tree obstacles — forest correction skipped.';
        INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
        VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata),
                'Phase 8 — Forest Cover Correction', now(), now(), 0, 'skipped', 0);
        COMMIT;
        RETURN;
    END IF;

    RAISE NOTICE '[Phase 8] Forest cover correction — running...';

    WITH tree_cover AS (
        SELECT g.gx, g.gy,
               LEAST(
                   ST_Area(
                       ST_Union(
                           ST_Intersection(t.footprint_2d, g.geom)
                       )
                   ) / (v_class_grid_res::numeric ^ 2),
                   1.0
               ) AS tree_frac
        FROM lcz.lcz_ar_grid_100m g
        JOIN lcz.lcz_svf_tree_obstacles t ON ST_Intersects(t.footprint_2d, g.geom)
        GROUP BY g.gx, g.gy
    )
    UPDATE lcz.lcz_map m
    SET lcz_class = 11,
        lcz_name  = 'Dense trees'
    FROM tree_cover tc
    WHERE m.gx = tc.gx AND m.gy = tc.gy
      AND m.bsf = 0
      AND m.psf > 0.80
      AND tc.tree_frac > v_forest_threshold;

    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata),
            'Phase 8 — Forest Cover Correction', now(), now(), 0, 'complete',
            (SELECT count(*) FROM lcz.lcz_map WHERE lcz_class = 11));
    COMMIT;
END $$;

-- Phase 9 (residential correction): PSF gate + building footprint filter
CREATE OR REPLACE PROCEDURE lcz.phase9_residential_correction()
LANGUAGE plpgsql AS $$
DECLARE
    v_srid INTEGER;
    v_grid_res INTEGER;
    v_class_grid_res INTEGER;
BEGIN
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT param_value::integer INTO v_grid_res FROM lcz.lcz_params WHERE param_name = 'grid_resolution';
    SELECT param_value::integer INTO v_class_grid_res FROM lcz.lcz_params WHERE param_name = 'class_grid_resolution';

    
    -- 1. PSF gate: Heavy Industry with too much pervious surface → reclassify
    
    UPDATE lcz.lcz_map m
    SET lcz_class = CASE
            WHEN p.bsf < 0.20 THEN 9
            ELSE 6
        END,
        lcz_name = CASE
            WHEN p.bsf < 0.20 THEN 'Sparsely built'
            ELSE 'Open low-rise'
        END
    FROM lcz.lcz_100m_params p
    WHERE m.gx = p.gx AND m.gy = p.gy
      AND m.lcz_class = 10
      AND p.psf > 0.50
      AND p.bsf < 0.30;

    
    -- 2. Building footprint filter: remaining Heavy Industry with only small buildings
    
    WITH cell_footprint AS (
        SELECT p.gx, p.gy,
               AVG(ST_Area(ST_Intersection(b.geom,
                       ST_SetSRID(ST_MakeEnvelope(p.gx, p.gy, p.gx + v_class_grid_res, p.gy + v_class_grid_res), v_srid)))) AS avg_footprint,
               COUNT(DISTINCT b.building_id) AS building_count
        FROM lcz.lcz_100m_params p
        JOIN lcz.lcz_height_buildings b ON ST_Intersects(b.geom,
                ST_SetSRID(ST_MakeEnvelope(p.gx, p.gy, p.gx + v_class_grid_res, p.gy + v_class_grid_res), v_srid))
        GROUP BY p.gx, p.gy
    )
    UPDATE lcz.lcz_map m
    SET lcz_class = CASE
            WHEN p.bsf < 0.20 THEN 9
            ELSE 6
        END,
        lcz_name = CASE
            WHEN p.bsf < 0.20 THEN 'Sparsely built'
            ELSE 'Open low-rise'
        END
    FROM cell_footprint cf
    JOIN lcz.lcz_100m_params p ON cf.gx = p.gx AND cf.gy = p.gy
    WHERE m.gx = p.gx AND m.gy = p.gy
      AND m.lcz_class = 10
      AND cf.avg_footprint < 200
      AND cf.building_count > 0
      AND p.bsf < 0.30;

    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata),
            'Phase 9 — Residential Correction', now(), now(), 0, 'complete',
            (SELECT count(*) FROM lcz.lcz_map WHERE lcz_class IN (6,9)));
    COMMIT;
END $$;


-- Master procedure
CREATE OR REPLACE PROCEDURE lcz.run_all()
LANGUAGE plpgsql AS $$
DECLARE
    x_min INTEGER; x_max INTEGER; x_start INTEGER;
    total_strips INTEGER; strip_number INTEGER := 0;
    already_done BIGINT; expected_rows BIGINT;
    citydb_schema text;
    v_srid INTEGER;
    v_directions INTEGER;

BEGIN
    SET work_mem = '512MB';
    SET maintenance_work_mem = '1GB';
    SET max_parallel_workers_per_gather = 4;
    SET effective_cache_size = '8GB';
    SET jit = off;

    -- set the search path 
    SELECT table_schema INTO citydb_schema
    FROM information_schema.tables
    WHERE table_name = 'feature'
      AND table_schema NOT IN ('information_schema', 'pg_catalog', 'lcz')
    LIMIT 1;

    IF citydb_schema IS NOT NULL THEN
        EXECUTE format('SET search_path = %I, lcz, public;', citydb_schema);
    END IF;

    -- Fetch SRID for this session
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT param_value::integer INTO v_directions FROM lcz.lcz_params WHERE param_name = 'svf_directions';

    -- Required input data check
    CALL lcz.check_input_data();
    COMMIT;

    CALL lcz.phase0_grid();  COMMIT;
    CALL lcz.phase1_bsf();   COMMIT;
    CALL lcz.phase2_isf();   COMMIT;
    CALL lcz.phase3_psf();   COMMIT;
    CALL lcz.phase4_height(); COMMIT;


    -- SVF: build building/tree obstacles once, then strips individually
    CALL lcz.phase5_build_obstacles();
    SELECT floor(ST_XMin(geom))::INTEGER, ceil(ST_XMax(geom))::INTEGER INTO x_min,x_max FROM lcz.lcz_inner_boundary;
    total_strips := (x_max - x_min) / 40;
    FOR x_start IN x_min..x_max BY 40 LOOP
        strip_number := strip_number + 1;
        CALL lcz.phase5_process_strip(x_start, strip_number, total_strips);
    END LOOP;

    
    -- SVF terrain (optional)
    IF (SELECT param_value FROM lcz.lcz_params WHERE param_name = 'include_terrain_in_svf') = 'true' THEN
        CALL lcz.phase5_build_terrain_grid();  COMMIT;

        SELECT floor(ST_XMin(geom))::INTEGER, ceil(ST_XMax(geom))::INTEGER INTO x_min,x_max FROM lcz.lcz_inner_boundary;
        total_strips := (x_max - x_min) / 40;
        strip_number := 0;
        FOR x_start IN x_min..x_max BY 40 LOOP
            strip_number := strip_number + 1;
            CALL lcz.phase5_process_terrain_strip(x_start, strip_number, total_strips);
        END LOOP;
    ELSE
        TRUNCATE lcz.lcz_svf_terrain_results;
    END IF;

    -- Build final SVF map (combine building/tree obstacles and terrain)
    TRUNCATE lcz.lcz_svf_map;
    INSERT INTO lcz.lcz_svf_map (gx, gy, svf_value, geom)
    SELECT
        b.gx,
        b.gy,
        (1 - (SUM(POWER(SIN(GREATEST(b.max_alpha, COALESCE(t.max_alpha, 0))), 2)) / v_directions::numeric))::numeric(4,3),
        ST_SetSRID(ST_MakePoint(b.gx, b.gy), v_srid)
    FROM lcz.lcz_svf_ray_results b
    LEFT JOIN lcz.lcz_svf_terrain_results t
        ON b.gx = t.gx AND b.gy = t.gy AND b.direction_id = t.direction_id
    WHERE NOT EXISTS (
        SELECT 1 FROM lcz.lcz_svf_buildings bld
        WHERE ST_Intersects(
                  ST_SetSRID(ST_MakePoint(b.gx, b.gy), v_srid),
                  bld.footprint_2d
              )
    )
    GROUP BY b.gx, b.gy;

    REFRESH MATERIALIZED VIEW lcz.lcz_svf_mat_view;
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 5 — SVF', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_svf_map));
    RAISE NOTICE '[Phase 5] SVF: DONE ✓';

    -- Continue with remaining phases
    CALL lcz.phase6_ar();    COMMIT;
    CALL lcz.phase7_classification(); COMMIT;
    CALL lcz.phase8_forest_correction(); COMMIT;
    CALL lcz.phase9_residential_correction(); COMMIT;
    CALL lcz.phase10_dissolve(); COMMIT;

    UPDATE lcz.lcz_run_metadata
    SET end_time = now(), status = 'complete'
    WHERE run_id = (SELECT MAX(run_id) FROM lcz.lcz_run_metadata);

END $$;