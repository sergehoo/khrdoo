#!/bin/bash
# =============================================================================
#  Init PostgreSQL — rôle de monitoring pour postgres-exporter (lecture seule)
# =============================================================================
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    DO \$\$
    BEGIN
       IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_EXPORTER_USER}') THEN
          CREATE ROLE "${PG_EXPORTER_USER}" LOGIN PASSWORD '${PG_EXPORTER_PASSWORD}';
       END IF;
    END
    \$\$;

    -- Droits minimaux pour la collecte de métriques (PostgreSQL >= 10)
    GRANT pg_monitor TO "${PG_EXPORTER_USER}";
    GRANT CONNECT ON DATABASE postgres TO "${PG_EXPORTER_USER}";
EOSQL

echo "✅ Rôle de monitoring '${PG_EXPORTER_USER}' configuré."
