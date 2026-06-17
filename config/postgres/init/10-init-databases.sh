#!/bin/bash
# =============================================================================
#  Init PostgreSQL — exécuté UNE SEULE FOIS à la création du cluster
#  Active l'extension pg_stat_statements (monitoring des requêtes).
#  (La base Odoo est créée par Odoo lui-même au premier démarrage.
#   Keycloak est un service externe avec sa propre base — rien à créer ici.)
# =============================================================================
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    -- Extension de monitoring des requêtes
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOSQL

echo "✅ Initialisation PostgreSQL (extensions) terminée."
