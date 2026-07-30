-- ================================================================
-- 03_citydb_groups.sql
-- Exports the LCZ zones (lcz.lcz_map_dissolved) into the 3DCityDB
-- (v5) as CityObjectGroup features:
--   * one CityObjectGroup feature per row in lcz_map_dissolved
--   * lcz_class / lcz_name as generic attributes
--   * every CityObject that intersects the polygon assigned as
--     groupMember, therefore one CityObject may be assigned to several groups 
--
-- Object naming follows the standard LCZ classification (Stewart &
-- Oke) as stored in lcz.lcz_reference / lcz_map_dissolved, e.g.:
--   LCZ_10_Heavy_industry, LCZ_12_Scattered_trees, LCZ_01_Compact_high_rise


-- ----------------------------------------------------------------
-- Staging table: helper table to express the groupMember assignment
-- set-based (instead of a row-by-row loop) via a data-modifying CTE.
-- ----------------------------------------------------------------
DROP TABLE IF EXISTS lcz.lcz_export_members CASCADE;
CREATE TABLE lcz.lcz_export_members (
    member_seq BIGSERIAL PRIMARY KEY,
    member_id  BIGINT NOT NULL
);

-- ----------------------------------------------------------------
-- Cleanup procedure: removes all previously exported LCZ groups
-- ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE lcz.citydb_remove_groups()
LANGUAGE plpgsql AS $$
DECLARE
    citydb_schema TEXT;
    v_deleted     INTEGER;
BEGIN
    SELECT table_schema INTO citydb_schema
    FROM information_schema.tables
    WHERE table_name = 'feature'
      AND table_schema NOT IN ('information_schema', 'pg_catalog', 'lcz')
    LIMIT 1;
    IF citydb_schema IS NULL THEN
        RAISE EXCEPTION 'No 3DCityDB schema with a feature table found.';
    END IF;
    EXECUTE format('SET search_path = %I, lcz, public;', citydb_schema);

    -- Child properties (e.g. the groupMember/FeatureProperty rows
    -- hanging off the Role rows of the LCZ groups via parent_id)
    DELETE FROM property
    WHERE parent_id IN (
        SELECT p.id FROM property p
        JOIN feature f ON p.feature_id = f.id
        WHERE f.objectid LIKE 'LCZ\_%' ESCAPE '\'
    );

    -- Parent properties of the groups themselves (Role rows, generic
    -- attributes, geometry property)
    DELETE FROM property
    WHERE feature_id IN (
        SELECT id FROM feature WHERE objectid LIKE 'LCZ\_%' ESCAPE '\'
    );

    -- Geometries of the groups
    DELETE FROM geometry_data
    WHERE feature_id IN (
        SELECT id FROM feature WHERE objectid LIKE 'LCZ\_%' ESCAPE '\'
    );

    -- The group features themselves
    DELETE FROM feature WHERE objectid LIKE 'LCZ\_%' ESCAPE '\';
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RAISE NOTICE '[LCZ export] Removed % previous LCZ group(s).', v_deleted;
END $$;

-- ----------------------------------------------------------------
-- Export procedure
-- ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE lcz.citydb_export_groups()
LANGUAGE plpgsql AS $$
DECLARE
    citydb_schema   TEXT;
    v_srid          INTEGER;

    v_oc_group      INTEGER;   -- objectclass.id of CityObjectGroup

    v_ns_gen        INTEGER;   -- namespace.id  'gen'  (generics)
    v_ns_grp        INTEGER;   -- namespace.id  'grp'  (cityobjectgroup)
    v_ns_depr       INTEGER;   -- namespace.id  'depr' (deprecated)

    v_dt_int        INTEGER;   -- datatype.id  core:Integer
    v_dt_string     INTEGER;   -- datatype.id  core:String
    v_dt_featprop   INTEGER;   -- datatype.id  core:FeatureProperty
    v_dt_geomprop   INTEGER;   -- datatype.id  core:GeometryProperty
    v_dt_role       INTEGER;   -- datatype.id  grp:Role

    r               RECORD;
    v_fid           BIGINT;
    v_geom_id       BIGINT;
    v_objectid      TEXT;
    v_members       INTEGER;
    v_groups        INTEGER := 0;
    v_total_members INTEGER := 0;
BEGIN
    -- ------------------------------------------------------------
    -- Session setup
    -- ------------------------------------------------------------
    SELECT table_schema INTO citydb_schema
    FROM information_schema.tables
    WHERE table_name = 'feature'
      AND table_schema NOT IN ('information_schema', 'pg_catalog', 'lcz')
    LIMIT 1;
    IF citydb_schema IS NULL THEN
        RAISE EXCEPTION 'No 3DCityDB schema with a feature table found.';
    END IF;
    EXECUTE format('SET search_path = %I, lcz, public;', citydb_schema);

    SELECT param_value::integer INTO v_srid
    FROM lcz.lcz_params WHERE param_name = 'srid';
    IF v_srid IS NULL THEN
        RAISE EXCEPTION 'No SRID found in lcz.lcz_params — run 01_admin_setup.sql first.';
    END IF;

    IF (SELECT COUNT(*) FROM lcz.lcz_map_dissolved) = 0 THEN
        RAISE EXCEPTION 'lcz.lcz_map_dissolved is empty — run the pipeline (phase11_dissolve) first.';
    END IF;

    -- ------------------------------------------------------------
    -- Resolve metadata IDs dynamically
    -- ------------------------------------------------------------
    SELECT id INTO v_oc_group FROM objectclass WHERE classname = 'CityObjectGroup';

    SELECT id INTO v_ns_gen  FROM namespace WHERE alias = 'gen';
    SELECT id INTO v_ns_grp  FROM namespace WHERE alias = 'grp';
    SELECT id INTO v_ns_depr FROM namespace WHERE alias = 'depr';

    SELECT d.id INTO v_dt_int
    FROM datatype d JOIN namespace n ON d.namespace_id = n.id
    WHERE n.alias = 'core' AND d.typename = 'Integer';

    SELECT d.id INTO v_dt_string
    FROM datatype d JOIN namespace n ON d.namespace_id = n.id
    WHERE n.alias = 'core' AND d.typename = 'String';

    SELECT d.id INTO v_dt_featprop
    FROM datatype d JOIN namespace n ON d.namespace_id = n.id
    WHERE n.alias = 'core' AND d.typename = 'FeatureProperty';

    SELECT d.id INTO v_dt_geomprop
    FROM datatype d JOIN namespace n ON d.namespace_id = n.id
    WHERE n.alias = 'core' AND d.typename = 'GeometryProperty';

    SELECT d.id INTO v_dt_role
    FROM datatype d JOIN namespace n ON d.namespace_id = n.id
    WHERE n.alias = 'grp' AND d.typename = 'Role';

    IF v_oc_group IS NULL OR v_ns_gen IS NULL OR v_ns_grp IS NULL OR v_ns_depr IS NULL
       OR v_dt_int IS NULL OR v_dt_string IS NULL OR v_dt_featprop IS NULL
       OR v_dt_geomprop IS NULL OR v_dt_role IS NULL THEN
        RAISE EXCEPTION 'Could not resolve all required metadata (objectclass/namespace/datatype). Check: SELECT * FROM %I.objectclass WHERE classname=''CityObjectGroup''; SELECT * FROM %I.namespace; SELECT * FROM %I.datatype;', citydb_schema, citydb_schema, citydb_schema;
    END IF;

    -- ------------------------------------------------------------
    -- Idempotency: remove any previously exported LCZ groups first
    -- ------------------------------------------------------------
    CALL lcz.citydb_remove_groups();

    RAISE NOTICE '[LCZ export] Creating CityObjectGroups from lcz_map_dissolved...';

    -- ------------------------------------------------------------
    -- One feature + geometry + attributes + members per LCZ class
    -- ------------------------------------------------------------
    FOR r IN
        SELECT lcz_class, lcz_name,
               ST_SetSRID(geom, v_srid) AS geom
        FROM lcz.lcz_map_dissolved
        ORDER BY lcz_class
    LOOP
        -- Object naming follows the standard LCZ classification,
        -- e.g. LCZ_10_Heavy_industry, LCZ_12_Scattered_trees
        v_objectid := 'LCZ_' || lpad(r.lcz_class::text, 2, '0') || '_' ||
                      regexp_replace(trim(r.lcz_name), '[^A-Za-z0-9]+', '_', 'g');

        -- 1. The CityObjectGroup feature itself
        INSERT INTO feature (objectclass_id, objectid, envelope,
                             creation_date, last_modification_date)
        VALUES (v_oc_group,
                v_objectid,
                ST_Force3D(ST_Envelope(r.geom)),
                now(), now())
        RETURNING id INTO v_fid;

        -- 2. Geometry: raw data in geometry_data ...
        INSERT INTO geometry_data (geometry, feature_id)
        VALUES (ST_Force3D(r.geom), v_fid)
        RETURNING id INTO v_geom_id;

        -- ... plus the actual link as a property (core:GeometryProperty,
        --     in the "deprecated" namespace since CityGML 3.0 — that is
        --     how it is defined in the schema, but it remains fully
        --     functional for storage/query/visualization)
        INSERT INTO property (feature_id, name, namespace_id, datatype_id, val_geometry_id)
        VALUES (v_fid, 'geometry', v_ns_depr, v_dt_geomprop, v_geom_id);

        -- 3. Generic attributes from lcz_map_dissolved
        INSERT INTO property (feature_id, name, namespace_id, datatype_id, val_int)
        VALUES (v_fid, 'lcz_class', v_ns_gen, v_dt_int, r.lcz_class);

        INSERT INTO property (feature_id, name, namespace_id, datatype_id, val_string)
        VALUES (v_fid, 'lcz_name', v_ns_gen, v_dt_string, r.lcz_name);

        -- 4. Member candidates: every CityObject intersecting the
        --    polygon (envelope pre-filter + exact intersects test)
        TRUNCATE lcz.lcz_export_members;
        INSERT INTO lcz.lcz_export_members (member_id)
        SELECT f.id
        FROM feature f
        WHERE f.objectclass_id <> v_oc_group          -- exclude groups as members
          AND f.termination_date IS NULL              -- exclude terminated features
          AND f.envelope IS NOT NULL
          AND f.envelope && r.geom
          AND ST_Intersects(ST_Force2D(f.envelope), r.geom);
        GET DIAGNOSTICS v_members = ROW_COUNT;

        -- 5. groupMember assignment: one Role parent row per member
        --    (feature_id = the group), plus one FeatureProperty child
        --    row. IMPORTANT: feature_id on the child row ALSO stays the
        --    group (confirmed against a working native import — see
        --    conversation notes) — it is NOT the target reference. The
        --    actual xlink target goes into val_feature_id, alongside
        --    val_relation_type = 0 ("relates"). Getting this backwards
        --    (putting the target into feature_id) is exactly why the
        --    exporter silently produced no groupMember output before.
        WITH ins_role AS (
            INSERT INTO property (feature_id, name, namespace_id, datatype_id, val_int)
            SELECT v_fid, 'groupMember', v_ns_grp, v_dt_role, member_seq
            FROM lcz.lcz_export_members
            RETURNING id, val_int AS member_seq
        )
        INSERT INTO property (parent_id, feature_id, name, namespace_id, datatype_id, val_feature_id, val_relation_type)
        SELECT ir.id, v_fid, 'groupMember', v_ns_grp, v_dt_featprop, m.member_id, 0
        FROM ins_role ir
        JOIN lcz.lcz_export_members m ON m.member_seq = ir.member_seq;

        -- Remove the scratch value (member_seq) from val_int again —
        -- the Role parent row has no value of its own per the schema
        UPDATE property
        SET val_int = NULL
        WHERE feature_id = v_fid AND name = 'groupMember' AND datatype_id = v_dt_role;

        v_groups        := v_groups + 1;
        v_total_members := v_total_members + v_members;
        RAISE NOTICE '[LCZ export] Group % (%): % member(s).',
                     v_objectid, r.lcz_name, v_members;
    END LOOP;

    TRUNCATE lcz.lcz_export_members;

    -- ------------------------------------------------------------
    -- Run tracking, consistent with the other pipeline phases
    -- ------------------------------------------------------------
    INSERT INTO lcz.lcz_run_steps (run_id, step_name, start_time, end_time,
                                   duration_seconds, status, rows_affected)
    VALUES ((SELECT MAX(run_id) FROM lcz.lcz_run_metadata),
            'Export — CityObjectGroups', now(), now(), 0, 'complete', v_groups);

    RAISE NOTICE '[LCZ export] DONE — % group(s), % member assignment(s).',
                 v_groups, v_total_members;
    COMMIT;
END $$;
