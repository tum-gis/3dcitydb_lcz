# 3DCityDB Local Climate Zone (LCZ) Docker Tool

This project provides a Docker-based workflow for importing CityGML data into 3DCityDB v5[^1] and calculating Local Climate Zones[^2] with 3DCityDB. The Docker Compose stack initializes the database, imports CityGML, runs the LCZ calculation, enriches the CityGML objects, and exports the result.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Input data](#input-data)
- [Pipeline](#pipeline)
- [Common commands](#common-commands)
- [Running parts of the pipeline manually](#running-parts-of-the-pipeline-manually)
- [SQL setup](#sql-setup)
- [Calculation parameters](#calculation-parameters)
- [Database access](#database-access)
- [Output](#output)
- [Troubleshooting](#troubleshooting)
- [Resetting the installation](#resetting-the-installation)

## Requirements

- Docker Engine or Docker Desktop
- Docker Compose
- CityGML input data with the following requirements:
   - projected coordinate reference system (CRS) like EPSG:25832
   - LOD2 buildings from Open Data Bayern [^3]
   - landuse and trees (optional) as produced by the FME workspace that you find in the resources folder from ALKIS TN [^4], Einzelbäume [^5] (optional) and DGM1 [^6].
   

Windows PowerShell examples assume this repository is the current directory:

```powershell
cd C:\temp\LCZ\3dcitydb_lcz_docker
```

Confirm Docker is available:

```powershell
docker --version
docker compose version
```

## Quick start

1. Copy the example environment file:

   ```powershell
   Copy-Item .env.example .env
   ```

2. Open `.env` and set a secure database password and the intended projected SRID:

   ```dotenv
   CITYDB_PASSWORD=replace-with-a-secure-password
   CITYDB_SRID=25832
   CITYDB_PORT=5432
   LCZ_FORCE_REINIT=false
   ```

3. Place CityGML files (see requirements) in [`input_data`](./input_data).

4. Start the complete pipeline:

   ```powershell
   docker compose up -d
   ```

5. Check the progress:

   ```powershell
   docker compose ps -a
   docker compose logs -f lcz-import
   docker compose logs -f lcz-run
   docker compose logs -f lcz-export
   ```

The generated result is written as a single CityGML file to [`output_data/LCZ_results.gml`](./output_data/LCZ_results.gml).

## Configuration

Configuration is read from `.env`.

| Variable | Default | Meaning |
|---|---:|---|
| `CITYDB_PASSWORD` | `changeMe` | Password for the PostgreSQL `postgres` user and the password used by import/export tools |
| `CITYDB_SRID` | `25832` | EPSG SRID used to initialize 3DCityDB; must be a projected CRS |
| `CITYDB_PORT` | `5432` | Host port mapped to PostgreSQL's port 5432 |
| `LCZ_FORCE_REINIT` | `false` | Set to `true` to rerun the LCZ setup SQL after editing the setup scripts |

Keep `.env` private; it contains the database password and should not be committed to Git.

The LCZ setup SQL stores the detected projected SRID in `lcz.lcz_params`. Geographic CRS values such as longitude/latitude CRSs are not supported by the calculation.

### Calculation parameters

The calculation parameters are stored in `lcz.lcz_params`. Their default values are defined in the `INSERT` block of [`sql/01_admin_setup.sql`](./sql/01_admin_setup.sql). After the database setup, inspect or change them through the SQL shell:

```powershell
docker compose exec citydb psql -U postgres -d postgres
```

List the current values:

```sql
SELECT param_name, param_value
FROM lcz.lcz_params
ORDER BY param_name;
```

Change a value with an `UPDATE`, for example, to include terrain in the SVF calculation:

```sql
UPDATE lcz.lcz_params
SET param_value = 'true'
WHERE param_name = 'include_terrain_in_svf';
```

The table below lists the available calculation parameters and their setup defaults. Distances are in metres, areas in square metres, and ratios are fractions between 0 and 1 unless noted otherwise.

| Parameter | Default | Purpose |
|---|---:|---|
| `boundary_buffer` | `60` | Inward buffer used to define the calculation area in meters. |
| `grid_resolution` | `10` | Side length of the calculation grid cells in meters. |
| `class_grid_resolution` | `100` | Side length of the grid cells used for LCZ classification in meters. |
| `tree_pit_radius` | `2.0` | Radius of tree-pit areas excluded from impervious-surface calculations in meters. |
| `landuse_default_imperv` | `0.40` | Fallback imperviousness ratio when no land-use mapping applies. |
| `svf_radius` | `60` | Maximum distance sampled along SVF rays in meters. |
| `svf_directions` | `8` | Number of directions sampled for SVF. |
| `svf_observer_height` | `2.0` | SVF observer height above ground in meters. |
| `svf_ray_step` | `2` | Distance between samples along each SVF ray in meters. |
| `include_trees_in_svf` | `true` | Specifiy whether trees are included as SVF obstacles. |
| `tree_crown_ratio` | `0.35` | Factor used to estimate tree-crown radius from tree height. |
| `svf_edge_buffer` | `60` | Search margin around the calculation area for SVF obstacles in meters. |
| `include_terrain_in_svf` | `false` | Specifies whether terrain is included as an SVF obstacle. |
| `terrain_grid_spacing` | `20` | Spacing of sampled terrain points when terrain is enabled in meters. |
| `ar_cell_area` | `10000` | Reference cell area used in the area-ratio calculation in meters sqared. |
| `forest_cover_threshold` | `0.80` | Tree-cover fraction threshold for the forest-cover correction. |
| `svf_weight` | `3.0` | Weight of SVF in the LCZ classification distance. |
| `bsf_weight` | `8.0` | Weight of building surface fraction (BSF). |
| `isf_weight` | `2.0` | Weight of impervious surface fraction (ISF). |
| `psf_weight` | `2.0` | Weight of pervious surface fraction (PSF). |
| `height_weight` | `6.0` | Weight of building height. |
| `ar_weight` | `4.0` | Weight of aspect ratio (AR). |
| `svf_norm_min` / `svf_norm_max` | `0.2` / `1.0` | Lower and upper SVF values used for normalization. |
| `bsf_norm_min` / `bsf_norm_max` | `0.0` / `0.9` | Lower and upper BSF values used for normalization. |
| `isf_norm_min` / `isf_norm_max` | `0.0` / `1.0` | Lower and upper ISF values used for normalization. |
| `psf_norm_min` / `psf_norm_max` | `0.0` / `1.0` | Lower and upper PSF values used for normalization. |
| `height_norm_min` / `height_norm_max` | `2.0` / `50.0` | Lower and upper building heights, in metres, used for normalization. |
| `ar_norm_min` / `ar_norm_max` | `0.1` / `5.0` | Lower and upper AR values used for normalization. |

`srid` is detected from the 3DCityDB installation and should not be set manually. Re-running the setup with `LCZ_FORCE_REINIT=true` recreates `lcz.lcz_params` and restores the defaults above.

## Input data

Place CityGML files in `input_data`:

```text
input_data/
  buildings.gml
  trees.gml
  landuse.gml
```

The importer searches recursively and imports every CityGML file it finds. The LCZ procedures expect active 3DCityDB features for at least:

- Buildings
- Ground surfaces
- Roof surfaces
- Wall surfaces
- Land-use features with generic attributes as created by the FME workspace stored in the "resources" folder
- Solitary vegetation objects as created by the FME workspace stored in the "resources" folder

Required geometries and properties are checked automatically before the calculation starts.

CityGML and 3DCityDB object data must be compatible with the configured SRID.

## Pipeline

Running `docker compose up -d` starts these services:

1. **`citydb`**
   - Starts PostgreSQL/PostGIS and 3DCityDB v5.
   - Persists database data in the `citydb-data` Docker volume.

2. **`lcz-init`**
   - Waits for `citydb` to be healthy.
   - Installs the `lcz` schema and procedures.
   - Runs once unless `LCZ_FORCE_REINIT=true`.

3. **`lcz-import`**
   - Imports all CityGML files from `input_data` into 3DCityDB.

4. **`lcz-run`**
   - Calls `lcz.run_all()`.
   - Creates LCZ export groups.
   - Enriches the city objects with LCZ attributes.

5. **`lcz-export`**
   - Exports the enriched 3DCityDB model to `output_data/LCZ_results.gml`.

`lcz-import`, `lcz-run`, and `lcz-export` exit after completing their tasks. `citydb` continues to run.

## Common commands

Start the complete pipeline:

```powershell
docker compose up -d
```

Start only the database and LCZ setup:

```powershell
docker compose up -d citydb lcz-init
```

Show container status:

```powershell
docker compose ps -a
```

Follow or inspect logs:

```powershell
docker compose logs -f citydb
docker compose logs -f lcz-init
docker compose logs -f lcz-import
docker compose logs -f lcz-run
docker compose logs -f lcz-export
```

Show the most recent log output:

```powershell
docker compose logs --tail=200 lcz-run
```

Stop containers without deleting database data:

```powershell
docker compose down
```

Restart only the LCZ pipeline after adding or replacing input data:

```powershell
docker compose rm -f lcz-import lcz-run lcz-export
docker compose up -d
```

## Running parts of the pipeline manually

With `citydb` running, open a SQL shell:

```powershell
docker compose exec citydb psql -U postgres -d postgres
```

Useful SQL commands:

```sql
-- Check the LCZ parameters
SELECT * FROM lcz.lcz_params;

-- Validate imported input data
CALL lcz.check_input_data();

-- Run the complete LCZ calculation
CALL lcz.run_all();

-- Create LCZ export groups
CALL lcz.citydb_export_groups();

-- Enrich city objects
CALL lcz.citydb_enrich_city_objects();
```

In a normal PowerShell command, the calculation can also be started from outside PostgreSQL:

```powershell
docker compose run --rm lcz-run psql -v ON_ERROR_STOP=1 -c "CALL lcz.run_all();"
```

The optional `citydb-tool` service can be used for additional manual import/export operations:

```powershell
docker compose --profile tools run --rm citydb-tool import citygml /data/example.gml
docker compose --profile tools run --rm citydb-tool export citygml -o /data/manual-export.gml
```

The `citydb-tool` service mounts [`data`](./data) at `/data`.

## SQL setup

The LCZ setup runs the SQL scripts listed in [`lcz-init/entrypoint.sh`](./lcz-init/entrypoint.sh), in this order:

1. [`01_admin_setup.sql`](./sql/01_admin_setup.sql)
2. [`02_install_procedures.sql`](./sql/02_install_procedures.sql)
3. [`03_citydb_groups.sql`](./sql/03_citydb_groups.sql)
4. [`04_citydb_enrich_city_objects.sql`](./sql/04_citydb_enrich_city_objects.sql)

To rerun the setup after changing these scripts, set `LCZ_FORCE_REINIT=true` and recreate the setup container. Set it back to `false` afterward:

```powershell
docker compose up -d --force-recreate lcz-init
docker compose logs -f lcz-init
```

## Database access

From the host, connect to PostgreSQL with a client such as pgAdmin or a PostgreSQL command-line tool:

- Host: `localhost`
- Port: value of `CITYDB_PORT`, default `5432`
- Database: `postgres`
- User: `postgres`
- Password: value of `CITYDB_PASSWORD`

Inside Docker, use:

```powershell
docker compose exec citydb psql -U postgres -d postgres
```

## Output

The exported file is created here:

```text
output_data/LCZ_results.gml
```

The database also contains LCZ tables and views in the `lcz` schema, including `lcz_map`, `lcz_map_polygons`, `lcz_classification`, and run metadata tables.

## Troubleshooting

### `citydb` repeatedly restarts

Inspect the database log:

```powershell
docker compose logs --tail=200 citydb
```

The original PostgreSQL data mount must be compatible with the installed PostgreSQL image. This Compose file mounts the persistent volume at `/var/lib/postgresql`, which is the PostgreSQL 18-compatible location.

Do not change this mount if the existing database volume contains data. Do not use `docker compose down -v` unless you intentionally want to delete the database.

### `No active Building features found`

This means that CityGML input was not imported or contains no active Building features.

Check:

```powershell
Get-ChildItem -Recurse .\input_data
docker compose logs --tail=100 lcz-import
```

Place valid CityGML files in `input_data`, then reimport the data and rerun the pipeline.

### LCZ setup is skipped

`lcz-init` skips setup when the `lcz` schema already exists and `LCZ_FORCE_REINIT=false`.

Set `LCZ_FORCE_REINIT=true`, recreate `lcz-init`, and set it back to `false` after setup:

```powershell
docker compose up -d --force-recreate lcz-init
docker compose logs -f lcz-init
```

### Port 5432 is already occupied

Change `CITYDB_PORT` in `.env`, for example:

```dotenv
CITYDB_PORT=55432
```

Then recreate the containers:

```powershell
docker compose down
docker compose up -d
```

### A service has exited

Inspect the status and exact error:

```powershell
docker compose ps -a
docker compose logs --tail=200 <service-name>
```

Typical service names are `lcz-import`, `lcz-run`, `lcz-export`, `lcz-init`, and `citydb`.

### Calculation fails because of missing properties or geometries

Run `CALL lcz.check_input_data();` to validate the input data. The check validates object classes, properties, geometries, and land-use mappings. Input data must contain the properties and active features expected by the LCZ procedures.

## Resetting the installation

To stop the stack while preserving the database:

```powershell
docker compose down
```

To delete the database and start with an empty 3DCityDB installation:

```powershell
docker compose down -v
docker compose up -d
```

Using `down -v` permanently removes imported CityGML data and the generated LCZ database contents. Create backups before resetting.

[^1]: <https://3dcitydb.net>
[^2]: <https://doi.org/10.1175/BAMS-D-11-00019.1>
[^3]: <https://geodaten.bayern.de/opengeodata/OpenDataDetail.html?pn=lod2>
[^4]: <https://geodaten.bayern.de/opengeodata/OpenDataDetail.html?pn=tatsaechlichenutzung>
[^5]: <https://geodaten.bayern.de/opengeodata/OpenDataDetail.html?pn=einzelbaeume>
[^6]: <https://geodaten.bayern.de/opengeodata/OpenDataDetail.html?pn=dgm1>