-- ================================================================
-- install_procedures.sql (schema-agnostic, CRS-agnostic)
-- ================================================================

-- Phase 0: Grid & Study Area
CREATE PROCEDURE lcz.phase0_grid()
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
    SELECT floor(ST_XMin(geom))::int, ceil(ST_XMax(geom))::int, floor(ST_YMin(geom))::int, ceil(ST_YMax(geom))::int
        INTO v_xmin, v_xmax, v_ymin, v_ymax FROM lcz.lcz_inner_boundary;
-- check if 3DCityDB contains the required data
	IF v_xmin IS NULL OR v_xmax IS NULL OR v_ymin IS NULL OR v_ymax IS NULL THEN
    UPDATE lcz.lcz_run_metadata SET status = 'failed', end_time = now() WHERE run_id = v_run_id;
    RAISE EXCEPTION 'No building (objectclass_id=710) or landuse features (objectclass_id=300) in 3DCityDB. Calculation stopped.';
	END IF;
    EXECUTE format('INSERT INTO lcz.lcz_grid (gx, gy) SELECT x, y FROM generate_series(%s,%s,%s) AS x, generate_series(%s,%s,%s) AS y WHERE ST_Within(ST_SetSRID(ST_MakePoint(x,y), %s), (SELECT geom FROM lcz.lcz_inner_boundary))',
        v_xmin, v_xmax, v_grid_res, v_ymin, v_ymax, v_grid_res, v_srid);
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES (v_run_id, 'Phase 0 — Study Area & Shared Grids', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_grid));
    UPDATE lcz.lcz_run_metadata SET study_area_geometry = (SELECT geom FROM lcz.lcz_inner_boundary LIMIT 1) WHERE run_id = v_run_id;
    RAISE NOTICE '[Phase 0] Grid: DONE ✓';
    COMMIT;
END $$;

-- Phase 1: BSF
CREATE PROCEDURE lcz.phase1_bsf()
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
-- Phase 2: ISF
CREATE PROCEDURE lcz.phase2_isf()
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
           COALESCE(ST_Difference(
                        ST_Difference(lu.geom,
                            (SELECT ST_Union(b.geom) FROM lcz.lcz_isf_buildings b WHERE ST_Intersects(lu.geom, b.geom))),
                        (SELECT ST_Union(t.geom) FROM lcz.lcz_isf_tree_pits t WHERE ST_Intersects(lu.geom, t.geom))),
                    lu.geom) AS geom,
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
CREATE PROCEDURE lcz.phase3_psf()
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
CREATE PROCEDURE lcz.phase4_height()
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
CREATE PROCEDURE lcz.phase5_build_obstacles()
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
        (SELECT ST_XMin(geom) FROM lcz.lcz_inner_boundary), (SELECT ST_YMin(geom) FROM lcz.lcz_inner_boundary),
        (SELECT ST_XMax(geom) FROM lcz.lcz_inner_boundary), (SELECT ST_YMax(geom) FROM lcz.lcz_inner_boundary),
        v_srid);

    -- Roof obstacles
    TRUNCATE TABLE lcz.lcz_svf_roof_obstacles;
    EXECUTE format('INSERT INTO lcz.lcz_svf_roof_obstacles (roof_id, footprint_2d, relative_height)
        SELECT f.id AS roof_id, ST_Force2D(ST_CollectionExtract(g.geometry,3)) AS footprint_2d,
               (ST_ZMax(g.geometry)-b.ground_z)::numeric(5,2) AS relative_height
        FROM feature f JOIN geometry_data g ON f.id=g.feature_id
        JOIN lcz.lcz_svf_buildings b ON ST_Intersects(ST_Force2D(ST_CollectionExtract(g.geometry,3)),b.footprint_2d)
        WHERE f.objectclass_id=712 AND g.geometry && ST_SetSRID(ST_MakeEnvelope(%s,%s,%s,%s), %s)',
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

-- Phase 5b: Process a single 40‑m strip and commit immediately
CREATE PROCEDURE lcz.phase5_process_strip(
    x_start INTEGER,
    strip_number INTEGER,
    total_strips INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_svf_radius NUMERIC;
    v_svf_ray_step NUMERIC;
    v_srid INTEGER;
    expected_rows BIGINT;
    already_done BIGINT;
BEGIN
    SELECT param_value::numeric INTO v_svf_radius   FROM lcz.lcz_params WHERE param_name = 'svf_radius';
    SELECT param_value::numeric INTO v_svf_ray_step FROM lcz.lcz_params WHERE param_name = 'svf_ray_step';
    SELECT param_value::integer INTO v_srid         FROM lcz.lcz_params WHERE param_name = 'srid';

    SELECT COUNT(*) INTO expected_rows FROM lcz.lcz_grid WHERE gx>=x_start AND gx<x_start+40;
    expected_rows := expected_rows * 8;
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
        SELECT r.gx,r.gy,ST_SetSRID(ST_MakePoint(r.gx,r.gy), v_srid) AS geom,COALESCE(MAX(o.relative_height),0.0) AS obs_z
        FROM lcz.lcz_grid r LEFT JOIN lcz.lcz_svf_all_obstacles o ON o.footprint_2d && ST_SetSRID(ST_MakePoint(r.gx,r.gy), v_srid)
            AND ST_Intersects(ST_SetSRID(ST_MakePoint(r.gx,r.gy), v_srid),o.footprint_2d)
        WHERE r.gx>=x_start AND r.gx<x_start+40 GROUP BY r.gx,r.gy
    )
    SELECT o.gx,o.gy,dir.direction_id,
           MAX(COALESCE(CASE WHEN b.relative_height>o.obs_z THEN ATAN2((b.relative_height-o.obs_z),step.s) ELSE 0 END,0)) AS max_alpha
    FROM current_grid o
    CROSS JOIN lcz.lcz_svf_ray_dictionary dir
    CROSS JOIN generate_series(v_svf_ray_step::numeric,v_svf_radius,v_svf_ray_step::numeric) AS step(s)
    LEFT JOIN lcz.lcz_svf_all_obstacles b ON b.footprint_2d && ST_Translate(o.geom,dir.dx*step.s,dir.dy*step.s)
        AND ST_Intersects(ST_Translate(o.geom,dir.dx*step.s,dir.dy*step.s),b.footprint_2d)
    GROUP BY o.gx,o.gy,dir.direction_id;

    IF strip_number % 10 = 0 THEN
        RAISE NOTICE '[SVF] Strip %/% completed.', strip_number, total_strips;
    END IF;

    COMMIT;
END $$;

-- Phase 6: Aspect Ratio
CREATE PROCEDURE lcz.phase6_ar()
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
    INSERT INTO lcz.lcz_ar_facade (gx, gy, total_facade_area, wall_count) WITH wall_areas AS (SELECT f.id,ST_Force2D(g.geometry) AS geom,p.val_string::numeric AS facade_area FROM feature f JOIN geometry_data g ON f.id=g.feature_id JOIN property p ON f.id=p.feature_id AND p.name='Flaeche' WHERE f.objectclass_id=709 AND ST_Intersects(ST_Force2D(g.geometry),(SELECT geom FROM lcz.lcz_inner_boundary))) SELECT gr.gx,gr.gy,SUM(w.facade_area),COUNT(*) FROM lcz.lcz_ar_grid_100m gr JOIN wall_areas w ON ST_Intersects(w.geom,gr.geom) GROUP BY gr.gx,gr.gy;
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
CREATE PROCEDURE lcz.phase7_classification()
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
    INSERT INTO lcz.lcz_trc_trees (gx, gy, tree_count, mean_tree_height, total_tree_area) SELECT g.gx, g.gy, COUNT(*), AVG((p.val_array->0)::numeric), SUM(ST_Area(ST_Force2D(f.envelope))) FROM lcz.lcz_ar_grid_100m g JOIN feature f ON f.objectclass_id=1301 AND f.envelope IS NOT NULL AND ST_Within(ST_Force2D(ST_Centroid(f.envelope)),g.geom) JOIN property p ON p.feature_id=f.id AND p.name='lod2ImplicitRepresentation' AND p.val_array IS NOT NULL AND (p.val_array->0)::numeric>0 GROUP BY g.gx,g.gy;
    INSERT INTO lcz.lcz_trc_elements (gx, gy, z_h, bsf, lambda_f, tree_count, mean_tree_height) SELECT g.gx, g.gy, (COALESCE(h.mean_height*b.mean_bsf*v_ar_cell_area,0)+COALESCE(t.mean_tree_height*t.total_tree_area,0))/NULLIF(COALESCE(b.mean_bsf*v_ar_cell_area,0)+COALESCE(t.total_tree_area,0),0), COALESCE(b.mean_bsf,0), COALESCE(f.total_facade_area,0)/4.0/v_ar_cell_area, COALESCE(t.tree_count,0), COALESCE(t.mean_tree_height,0) FROM lcz.lcz_ar_grid_100m g LEFT JOIN lcz.lcz_ar_height_100m h ON g.gx=h.gx AND g.gy=h.gy LEFT JOIN lcz.lcz_ar_bsf_100m b ON g.gx=b.gx AND g.gy=b.gy LEFT JOIN lcz.lcz_ar_facade f ON g.gx=f.gx AND g.gy=f.gy LEFT JOIN lcz.lcz_trc_trees t ON g.gx=t.gx AND g.gy=t.gy;
    INSERT INTO lcz.lcz_100m_params (gx, gy, geom, svf, bsf, isf, psf, height, ar) SELECT g.gx, g.gy, ST_SetSRID(ST_MakePoint(g.gx+v_class_grid_res/2,g.gy+v_class_grid_res/2), v_srid), COALESCE(s.svf_mean,0), COALESCE(b.mean_bsf,0), COALESCE(i.isf_mean,0), GREATEST(1.0-COALESCE(b.mean_bsf,0)-COALESCE(i.isf_mean,0),0.0), COALESCE(e.z_h,0), COALESCE(ar.ar_value,0) FROM lcz.lcz_ar_grid_100m g LEFT JOIN lcz.lcz_aggregate_svf_100m s ON g.gx=s.gx AND g.gy=s.gy LEFT JOIN lcz.lcz_ar_bsf_100m b ON g.gx=b.gx AND g.gy=b.gy LEFT JOIN lcz.lcz_aggregate_isf_100m i ON g.gx=i.gx AND g.gy=i.gy LEFT JOIN lcz.lcz_trc_elements e ON g.gx=e.gx AND g.gy=e.gy LEFT JOIN lcz.lcz_ar_map ar ON g.gx=ar.gx AND g.gy=ar.gy;

    -- Only REFRESH, no CREATE/DROP
    REFRESH MATERIALIZED VIEW lcz.lcz_classification;

    INSERT INTO lcz.lcz_map (gx, gy, geom, lcz_class, lcz_name, distance_sq, svf, bsf, isf, psf, height, ar) SELECT c.gx, c.gy, ST_SetSRID(c.geom, v_srid), c.lcz_class, c.lcz_name, c.distance_sq, p.svf, p.bsf, p.isf, p.psf, p.height, p.ar FROM lcz.lcz_classification c JOIN lcz.lcz_100m_params p ON c.gx=p.gx AND c.gy=p.gy;
    EXECUTE format('INSERT INTO lcz.lcz_map_polygons (gx, gy, lcz_class, lcz_name, distance_sq, svf, bsf, isf, psf, height, ar, geom) SELECT gx, gy, lcz_class, lcz_name, distance_sq, svf, bsf, isf, psf, height, ar, ST_SetSRID(ST_MakeEnvelope(gx,gy,gx+%s,gy+%s), %s) FROM lcz.lcz_map',
        v_class_grid_res, v_class_grid_res, v_srid);
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 7 — Aggregation & Classification', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_map));
    RAISE NOTICE '[Phase 7] Classification: DONE ✓';
    COMMIT;
END $$;

-- Phase 11: Dissolve 
CREATE PROCEDURE lcz.phase11_dissolve()
LANGUAGE plpgsql AS $$
DECLARE
    v_srid INTEGER;
    v_class_grid_res INTEGER;
BEGIN
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT param_value::integer INTO v_class_grid_res FROM lcz.lcz_params WHERE param_name = 'class_grid_resolution';

    RAISE NOTICE '[Phase 11] Rebuilding polygons from corrected map and dissolving...';

    -- 1. Rebuild the polygon table from the (now corrected) lcz_map
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
            'Phase 11 — Dissolve', now(), now(), 0, 'complete',
            (SELECT count(*) FROM lcz.lcz_map_dissolved));

    RAISE NOTICE '[Phase 11] Dissolve: DONE ✓';
    COMMIT;
END $$;

-- Phase 8: Forest cover correction
CREATE PROCEDURE lcz.phase8_forest_correction()
LANGUAGE plpgsql AS $$
DECLARE
    v_forest_threshold NUMERIC;
BEGIN
    SELECT param_value::numeric INTO v_forest_threshold
    FROM lcz.lcz_params
    WHERE param_name = 'forest_cover_threshold';

    WITH tree_cover AS (
        SELECT g.gx, g.gy,
               SUM(ST_Area(ST_Intersection(t.footprint_2d, g.geom))) / 10000.0 AS tree_frac
        FROM lcz.lcz_ar_grid_100m g
        JOIN lcz.lcz_svf_tree_obstacles t ON ST_Intersects(t.footprint_2d, g.geom)
        GROUP BY g.gx, g.gy
    )
    UPDATE lcz.lcz_map m
    SET lcz_class = 11,
        lcz_name = 'Dense trees'
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

-- Phase 10: Agricultural / vegetated flat land correction
CREATE PROCEDURE lcz.phase10_agricultural_correction()
LANGUAGE plpgsql AS $$
DECLARE
    v_srid INTEGER;
BEGIN
    SELECT param_value::integer INTO v_srid
    FROM lcz.lcz_params WHERE param_name = 'srid';

    UPDATE lcz.lcz_map m
    SET lcz_class = 14, lcz_name = 'Low plants'
    WHERE lcz_class = 17
      AND m.bsf = 0
      AND NOT EXISTS (
          SELECT 1
          FROM feature f
          JOIN property p ON f.id = p.feature_id AND p.name = 'class' AND p.val_string = '4000'
          JOIN geometry_data gd ON f.id = gd.feature_id
          WHERE f.objectclass_id = 300
            AND ST_Intersects(ST_Force2D(gd.geometry),
                              ST_SetSRID(ST_MakeEnvelope(m.gx, m.gy, m.gx+100, m.gy+100), v_srid))
      )
      AND EXISTS (
          SELECT 1
          FROM feature f
          JOIN property p ON f.id = p.feature_id AND p.name = 'class' AND p.val_string = '3000'
          JOIN geometry_data gd ON f.id = gd.feature_id
          WHERE f.objectclass_id = 300
            AND ST_Intersects(ST_Force2D(gd.geometry),
                              ST_SetSRID(ST_MakeEnvelope(m.gx, m.gy, m.gx+100, m.gy+100), v_srid))
      );

    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata),
            'Phase 10 — Agricultural Correction', now(), now(), 0, 'complete',
            (SELECT count(*) FROM lcz.lcz_map WHERE lcz_class = 14));
    COMMIT;
END $$;

-- Phase 9 (residential correction): PSF gate + building footprint filter
CREATE PROCEDURE lcz.phase9_residential_correction()
LANGUAGE plpgsql AS $$
DECLARE
    v_srid INTEGER;
    v_grid_res INTEGER;
BEGIN
    SELECT param_value::integer INTO v_srid FROM lcz.lcz_params WHERE param_name = 'srid';
    SELECT param_value::integer INTO v_grid_res FROM lcz.lcz_params WHERE param_name = 'grid_resolution';

    -----------------------------------------------------------------------
    -- 1. PSF gate: Heavy Industry with too much pervious surface → reclassify
    -----------------------------------------------------------------------
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

    -----------------------------------------------------------------------
    -- 2. Building footprint filter: remaining Heavy Industry with only small buildings
    -----------------------------------------------------------------------
    WITH cell_footprint AS (
        SELECT p.gx, p.gy,
               AVG(ST_Area(ST_Intersection(b.geom,
                       ST_SetSRID(ST_MakeEnvelope(p.gx, p.gy, p.gx+100, p.gy+100), v_srid)))) AS avg_footprint,
               COUNT(DISTINCT b.building_id) AS building_count
        FROM lcz.lcz_100m_params p
        JOIN lcz.lcz_height_buildings b ON ST_Intersects(b.geom,
                ST_SetSRID(ST_MakeEnvelope(p.gx, p.gy, p.gx+100, p.gy+100), v_srid))
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

-- Master procedure – automatically sets the search path
CREATE PROCEDURE lcz.run_all()
LANGUAGE plpgsql AS $$
DECLARE
    x_min INTEGER; x_max INTEGER; x_start INTEGER;
    total_strips INTEGER; strip_number INTEGER := 0;
    already_done BIGINT; expected_rows BIGINT;
    citydb_schema text;
    v_srid INTEGER;
BEGIN
    -- Automatically set the search path for this session
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

    CALL lcz.phase0_grid();  COMMIT;
    CALL lcz.phase1_bsf();   COMMIT;
    CALL lcz.phase2_isf();   COMMIT;
    CALL lcz.phase3_psf();   COMMIT;
    CALL lcz.phase4_height(); COMMIT;

    -- SVF: build obstacles once, then strips individually
    CALL lcz.phase5_build_obstacles();
    SELECT floor(ST_XMin(geom))::INTEGER, ceil(ST_XMax(geom))::INTEGER INTO x_min,x_max FROM lcz.lcz_inner_boundary;
    total_strips := (x_max - x_min) / 40;
    FOR x_start IN x_min..x_max BY 40 LOOP
        strip_number := strip_number + 1;
        CALL lcz.phase5_process_strip(x_start, strip_number, total_strips);
    END LOOP;

    -- Build SVF map and finalise
    TRUNCATE lcz.lcz_svf_map;
    INSERT INTO lcz.lcz_svf_map (gx, gy, svf_value, geom)
    SELECT gx,gy,(1-(SUM(POWER(SIN(max_alpha),2))/8.0))::numeric(4,3), ST_SetSRID(ST_MakePoint(gx,gy), v_srid)
    FROM lcz.lcz_svf_ray_results GROUP BY gx,gy;
    REFRESH MATERIALIZED VIEW lcz.lcz_svf_mat_view;
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time, duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata), 'Phase 5 — SVF', now(), now(), 0, 'complete', (SELECT count(*) FROM lcz.lcz_svf_map));
    RAISE NOTICE '[Phase 5] SVF: DONE ✓';

    -- Continue with remaining phases
    CALL lcz.phase6_ar();    COMMIT;
    CALL lcz.phase7_classification(); COMMIT;
    CALL lcz.phase8_forest_correction(); COMMIT;
    CALL lcz.phase9_residential_correction(); COMMIT;
    CALL lcz.phase10_agricultural_correction(); COMMIT;
    CALL lcz.phase11_dissolve(); COMMIT;

    UPDATE lcz.lcz_run_metadata
    SET end_time = now(), status = 'complete'
    WHERE run_id = (SELECT MAX(run_id) FROM lcz.lcz_run_metadata);
END $$;