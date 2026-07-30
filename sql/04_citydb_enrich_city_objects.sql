-- ================================================================
-- 04_citydb_enrich_city_objects.sql
-- Enriches every top-level CityGML object that intersects an LCZ zone
-- (lcz.lcz_map_dissolved) with its LCZ classification.
-
-- Handling objects that intersect MULTIPLE LCZ zones (e.g. a LandUse
-- polygon, a road, a river, or a large vegetation patch that spans
-- several of the dissolved, citywide LCZ zones): rather than picking a
-- single, potentially misleading "the" class, every intersecting zone
-- is recorded as a separate, numbered set of attributes, ranked by the
-- object's share (in %) that falls within that zone (largest first):
--
--   lcz_zone_count                — number of intersecting zones
--   lcz_class_1 / lcz_name_1 / lcz_share_pct_1   — dominant zone (largest share)
--   lcz_class_2 / lcz_name_2 / lcz_share_pct_2   — next zone, if any
--   ...
--
-- The share is expressed as a PERCENTAGE of the feature's own size,
-- measured with the metric appropriate to its geometry:
--   * polygonal features (e.g. LandUse, building footprints): area share
--   * linear features    (e.g. roads modeled as LineStrings): length share
--   * point / degenerate geometries: cannot be meaningfully split, so
--     100% is assigned to each zone they fall in (normally just one)
-- The geometry dimension is detected automatically per feature.
--
-- Overlaps below 0.01% (typically sliver polygon artifacts exactly on a zone
-- boundary) are dropped before ranking.
--

-- ----------------------------------------------------------------
-- Staging tables
-- ----------------------------------------------------------------
DROP TABLE IF EXISTS lcz.lcz_member_zone_candidates CASCADE;
CREATE TABLE lcz.lcz_member_zone_candidates (
    feature_id BIGINT NOT NULL,
    lcz_class  INTEGER NOT NULL
);

DROP TABLE IF EXISTS lcz.lcz_member_zone_overlap CASCADE;
CREATE TABLE lcz.lcz_member_zone_overlap (
    feature_id  BIGINT NOT NULL,
    lcz_class   INTEGER NOT NULL,
    lcz_name    TEXT NOT NULL,
    overlap_pct DOUBLE PRECISION NOT NULL,
    zone_rank   INTEGER
);

-- ----------------------------------------------------------------
-- Cleanup procedure: removes all previously written lcz_* attributes.
-- Also cleans up attribute names from an earlier version of this
-- procedure (svf/bsf/isf/psf/height/ar/dist_sq incl. _min/_max), so
-- running this on a database that used that version still leaves a
-- clean slate.
-- ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE lcz.citydb_remove_enrichment()
LANGUAGE plpgsql AS $$
DECLARE
    citydb_schema TEXT;
    v_ns_gen      INTEGER;
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

    SELECT id INTO v_ns_gen FROM namespace WHERE alias = 'gen';
    IF v_ns_gen IS NULL THEN
        RAISE EXCEPTION 'Namespace ''gen'' not found.';
    END IF;

    DELETE FROM property
    WHERE namespace_id = v_ns_gen
      AND (
            name = 'lcz_zone_count'
         OR name IN ('lcz_svf', 'lcz_bsf', 'lcz_isf', 'lcz_psf', 'lcz_height', 'lcz_ar', 'lcz_dist_sq')
         OR name LIKE 'lcz\_class\_%'      ESCAPE '\'
         OR name LIKE 'lcz\_name\_%'       ESCAPE '\'
         OR name LIKE 'lcz\_share\_pct\_%' ESCAPE '\'
         OR name LIKE 'lcz\_%\_min'        ESCAPE '\'
         OR name LIKE 'lcz\_%\_max'        ESCAPE '\'
      );
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RAISE NOTICE '[LCZ enrichment] Removed % previous attribute propert(y/ies).', v_deleted;
END $$;

-- ----------------------------------------------------------------
-- Enrichment procedure
-- ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE lcz.citydb_enrich_city_objects()
LANGUAGE plpgsql AS $$
DECLARE
    citydb_schema  TEXT;
    v_srid         INTEGER;
    v_oc_group     INTEGER;   -- objectclass.id of CityObjectGroup (excluded)
    v_oc_exclude   INTEGER[]; -- objectclass.id(s) of sub-features (excluded, see below)
    v_ns_gen       INTEGER;   -- namespace.id  'gen'  (generics)
    v_dt_int       INTEGER;   -- datatype.id  core:Integer
    v_dt_string    INTEGER;   -- datatype.id  core:String
    v_dt_double    INTEGER;   -- datatype.id  core:Double
    v_n_candidates INTEGER;
    v_n_tagged     INTEGER;
    v_n_multizone  INTEGER;
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

    SELECT id INTO v_oc_group FROM objectclass WHERE classname = 'CityObjectGroup';
    SELECT id INTO v_ns_gen  FROM namespace WHERE alias = 'gen';

    -- Sub-features (boundary surfaces, openings, installations/furniture)
    -- are not standalone real-world objects and must not be enriched
    -- independently of their parent feature. Resolved dynamically by
    -- classname so this degrades gracefully if a given module (e.g.
    -- water, bridge, tunnel) is not present in this instance — classes
    -- that don't exist simply contribute nothing to the array.
    SELECT array_agg(id) INTO v_oc_exclude
    FROM objectclass
    WHERE classname IN (
        -- boundary surfaces (Building/Bridge/Tunnel solids)
        'WallSurface', 'RoofSurface', 'GroundSurface', 'ClosureSurface',
        'OuterCeilingSurface', 'OuterFloorSurface',
        'InteriorWallSurface', 'CeilingSurface', 'InteriorFloorSurface',
        -- boundary surfaces (WaterBody)
        'WaterSurface', 'WaterGroundSurface', 'WaterClosureSurface',
        -- openings
        'Door', 'Window',
        -- installations / furniture
        'BuildingInstallation', 'BuildingFurniture',
        'BridgeInstallation', 'BridgeFurniture', 'BridgeConstructionElement',
        'TunnelInstallation', 'TunnelFurniture'
    );

    SELECT d.id INTO v_dt_int
    FROM datatype d JOIN namespace n ON d.namespace_id = n.id
    WHERE n.alias = 'core' AND d.typename = 'Integer';

    SELECT d.id INTO v_dt_string
    FROM datatype d JOIN namespace n ON d.namespace_id = n.id
    WHERE n.alias = 'core' AND d.typename = 'String';

    SELECT d.id INTO v_dt_double
    FROM datatype d JOIN namespace n ON d.namespace_id = n.id
    WHERE n.alias = 'core' AND d.typename = 'Double';

    IF v_oc_group IS NULL OR v_ns_gen IS NULL
       OR v_dt_int IS NULL OR v_dt_string IS NULL OR v_dt_double IS NULL THEN
        RAISE EXCEPTION 'Could not resolve all required metadata (objectclass/namespace/datatype).';
    END IF;

    -- ------------------------------------------------------------
    -- Idempotency: remove any previously written attributes first
    -- ------------------------------------------------------------
    CALL lcz.citydb_remove_enrichment();

    TRUNCATE lcz.lcz_member_zone_candidates;
    TRUNCATE lcz.lcz_member_zone_overlap;

    -- ------------------------------------------------------------
    -- Step 1: cheap envelope-based pre-filter — which (feature, zone)
    -- pairs are even worth a precise geometry check?
    -- ------------------------------------------------------------
    RAISE NOTICE '[LCZ enrichment] Finding candidate features per zone (envelope pre-filter)...';

    INSERT INTO lcz.lcz_member_zone_candidates (feature_id, lcz_class)
    SELECT DISTINCT f.id, z.lcz_class
    FROM feature f
    JOIN lcz.lcz_map_dissolved z
      ON f.envelope && ST_SetSRID(z.geom, v_srid)
    WHERE f.objectclass_id <> v_oc_group     -- do not enrich our own LCZ groups
      AND (v_oc_exclude IS NULL OR f.objectclass_id <> ALL(v_oc_exclude))  -- skip sub-features
      AND f.termination_date IS NULL
      AND f.envelope IS NOT NULL
      AND ST_Intersects(ST_Force2D(f.envelope), ST_SetSRID(z.geom, v_srid));

    GET DIAGNOSTICS v_n_candidates = ROW_COUNT;
    RAISE NOTICE '[LCZ enrichment] % candidate (feature, zone) pairs found.', v_n_candidates;

    -- ------------------------------------------------------------
    -- Step 2: precise overlap share (%) per (feature, zone), based on
    -- each feature's actual (unioned, 2D) geometry. The metric (area vs.
    -- length) is chosen per feature according to its geometry dimension,
    -- so both polygonal and linear features are handled correctly.
    --
    -- PolyhedralSurface/TIN geometries (common for LOD2+ building
    -- solids) are not understood by ST_Union/GEOS directly ("Unknown
    -- geometry type: 13/16"). ST_Dump decomposes ANY geometry into its
    -- base faces first (a no-op for plain Polygon/MultiPolygon,
    -- face-extraction for PolyhedralSurface/TIN), which sidesteps the
    -- issue uniformly. ST_MakeValid guards against degenerate
    -- 2D-projected wall faces (near-vertical faces can collapse to
    -- zero-area slivers once Z is dropped); those contribute ~0
    -- area/length and do not distort the footprint, which for solids
    -- ends up dominated by the roof/ground faces — a reasonable proxy
    -- for the feature's footprint.
    -- ------------------------------------------------------------
    RAISE NOTICE '[LCZ enrichment] Computing precise overlap shares (this can take a while)...';

    WITH footprints AS (
        SELECT g.feature_id, ST_Union(ST_MakeValid(ST_Force2D(d.geom))) AS footprint
        FROM geometry_data g,
             LATERAL ST_Dump(g.geometry) AS d
        WHERE g.feature_id IN (SELECT DISTINCT feature_id FROM lcz.lcz_member_zone_candidates)
        GROUP BY g.feature_id
    ),
    footprint_stats AS (
        SELECT feature_id, footprint,
               ST_Dimension(footprint) AS dim,
               CASE ST_Dimension(footprint)
                   WHEN 2 THEN ST_Area(footprint)
                   WHEN 1 THEN ST_Length(footprint)
                   ELSE 0
               END AS total_size
        FROM footprints
    )
    INSERT INTO lcz.lcz_member_zone_overlap (feature_id, lcz_class, lcz_name, overlap_pct)
    SELECT c.feature_id, c.lcz_class, z.lcz_name,
           CASE
               WHEN fs.dim = 2 AND fs.total_size > 0 THEN
                   100.0 * ST_Area(ST_Intersection(fs.footprint, ST_SetSRID(z.geom, v_srid))) / fs.total_size
               WHEN fs.dim = 1 AND fs.total_size > 0 THEN
                   100.0 * ST_Length(ST_Intersection(fs.footprint, ST_SetSRID(z.geom, v_srid))) / fs.total_size
               ELSE 100.0  -- points / degenerate geometries: not splittable
           END AS overlap_pct
    FROM lcz.lcz_member_zone_candidates c
    JOIN lcz.lcz_map_dissolved z ON z.lcz_class = c.lcz_class
    JOIN footprint_stats fs ON fs.feature_id = c.feature_id;

    -- Drop negligible slivers (rounding artifacts exactly on a zone
    -- boundary) — but never drop a feature's only remaining row.
    DELETE FROM lcz.lcz_member_zone_overlap
    WHERE overlap_pct < 0.01
      AND feature_id IN (
          SELECT feature_id FROM lcz.lcz_member_zone_overlap
          GROUP BY feature_id HAVING COUNT(*) > 1
      );

    -- Rank zones per feature by share, descending (largest = rank 1)
    UPDATE lcz.lcz_member_zone_overlap o
    SET zone_rank = r.rnk
    FROM (
        SELECT feature_id, lcz_class,
               ROW_NUMBER() OVER (PARTITION BY feature_id ORDER BY overlap_pct DESC) AS rnk
        FROM lcz.lcz_member_zone_overlap
    ) r
    WHERE o.feature_id = r.feature_id AND o.lcz_class = r.lcz_class;

    SELECT COUNT(DISTINCT feature_id) INTO v_n_tagged FROM lcz.lcz_member_zone_overlap;
    SELECT COUNT(*) INTO v_n_multizone
    FROM (SELECT feature_id FROM lcz.lcz_member_zone_overlap
          GROUP BY feature_id HAVING COUNT(*) > 1) sub;

    RAISE NOTICE '[LCZ enrichment] % feature(s) will be enriched, % of them span more than one zone.',
                 v_n_tagged, v_n_multizone;

    -- ------------------------------------------------------------
    -- Step 3: write the classification attributes (flat, root-level,
    -- ranked/numbered by dominant class first)
    -- ------------------------------------------------------------
    INSERT INTO property (feature_id, name, namespace_id, datatype_id, val_int)
    SELECT feature_id, 'lcz_zone_count', v_ns_gen, v_dt_int, COUNT(*)
    FROM lcz.lcz_member_zone_overlap
    GROUP BY feature_id;

    INSERT INTO property (feature_id, name, namespace_id, datatype_id, val_int)
    SELECT feature_id, 'lcz_class_' || zone_rank, v_ns_gen, v_dt_int, lcz_class
    FROM lcz.lcz_member_zone_overlap;

    INSERT INTO property (feature_id, name, namespace_id, datatype_id, val_string)
    SELECT feature_id, 'lcz_name_' || zone_rank, v_ns_gen, v_dt_string, lcz_name
    FROM lcz.lcz_member_zone_overlap;

    INSERT INTO property (feature_id, name, namespace_id, datatype_id, val_double)
    SELECT feature_id, 'lcz_share_pct_' || zone_rank, v_ns_gen, v_dt_double,
           round(overlap_pct::numeric, 1)
    FROM lcz.lcz_member_zone_overlap;

    TRUNCATE lcz.lcz_member_zone_candidates;
    TRUNCATE lcz.lcz_member_zone_overlap;

    RAISE NOTICE '[LCZ enrichment] DONE — % feature(s) enriched (% spanning multiple zones).',
                 v_n_tagged, v_n_multizone;
    COMMIT;
END $$;
