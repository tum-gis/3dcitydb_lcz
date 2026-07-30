#!/bin/sh
# ================================================================
# Entrypoint for the lcz-init service.
# Runs the LCZ setup SQL scripts once, in explicit order, against the
# citydb service. Safe to re-run: if the lcz schema already exists,
# setup is skipped unless FORCE_REINIT=true.
#
# Order is controlled explicitly here (not by filename sorting), so
# the SQL files do not need numeric prefixes to run in the right
# sequence — though keeping them numbered is still good for readability.
# ================================================================
set -e

echo "[lcz-init] Waiting for citydb to accept connections..."
until pg_isready -q; do
    sleep 2
done

echo "[lcz-init] Checking whether the lcz schema already exists..."
SCHEMA_EXISTS=$(psql -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'lcz'")

if [ "$SCHEMA_EXISTS" = "1" ] && [ "$FORCE_REINIT" != "true" ]; then
    echo "[lcz-init] Schema 'lcz' already exists — skipping setup."
    echo "[lcz-init] Set FORCE_REINIT=true (in .env) to force a re-run."
    exit 0
fi

if [ "$SCHEMA_EXISTS" = "1" ]; then
    echo "[lcz-init] FORCE_REINIT=true — re-running setup over the existing schema."
fi

echo "[lcz-init] Running LCZ setup scripts..."
for f in /sql/01_admin_setup.sql \
         /sql/02_install_procedures.sql \
         /sql/03_citydb_groups.sql \
         /sql/04_citydb_enrich_city_objects.sql; do
    if [ ! -f "$f" ]; then
        echo "[lcz-init] ERROR: expected file not found: $f"
        exit 1
    fi
    echo "[lcz-init] -> $f"
    psql -v ON_ERROR_STOP=1 -f "$f"
done

echo "[lcz-init] DONE — LCZ schema and procedures are installed."
