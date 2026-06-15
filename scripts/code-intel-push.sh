#!/usr/bin/env bash
# Push locally-built code-intel rows for this repo into the hosted Heroku
# Postgres (pgvector) that backs the acctseed-mcp MCP server.
#
# Streams only rows for REPO from the local Docker pgvector container into
# Heroku, replacing any existing rows for that repo (idempotent). Run after
# `npm run code-intel:index && npm run code-intel:enrich`.
#
# Overridable via env:
#   HEROKU_APP    Heroku app backing the MCP server   (default: acctseed-mcp)
#   PG_CONTAINER  local Docker pgvector container name (default: code-intel-db-1)
#   REPO          repo label to push                  (default: REPO_NAME in code-intel/.env, else ASRamp)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HEROKU_APP="${HEROKU_APP:-acctseed-mcp}"
PG_CONTAINER="${PG_CONTAINER:-code-intel-db-1}"
REPO="${REPO:-$(grep -E '^REPO_NAME=' "$ROOT/code-intel/.env" 2>/dev/null | cut -d= -f2 || true)}"
REPO="${REPO:-ASRamp}"

COLS="chunk_id,branch,repo,namespace,class_name,superclass,method_name,return_type,parameters,annotations,sobject_refs,calls,called_by,tooling_verified,test_classes,chunk_type,last_commit,chunk_text,embedding"

# Preflight
docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
  || { echo "ERROR: local pgvector container '$PG_CONTAINER' is not running (docker compose up -d in code-intel/)." >&2; exit 1; }
HEROKU_DB="$(heroku config:get DATABASE_URL --app "$HEROKU_APP")"
[ -n "$HEROKU_DB" ] || { echo "ERROR: could not read DATABASE_URL from Heroku app '$HEROKU_APP' (heroku login?)." >&2; exit 1; }

echo "Pushing repo='$REPO' from container '$PG_CONTAINER' -> Heroku app '$HEROKU_APP'..."
docker exec -e HEROKU_DB="$HEROKU_DB" -e COLS="$COLS" -e REPO="$REPO" "$PG_CONTAINER" bash -c '
  set -euo pipefail
  echo "Deleting existing rows for repo=$REPO on Heroku..."
  psql "$HEROKU_DB?sslmode=require" -c "DELETE FROM code_chunks WHERE repo = '\''$REPO'\'';"
  echo "Streaming rows..."
  psql -U codeintel -d code_intel -c "\copy (SELECT $COLS FROM code_chunks WHERE repo = '\''$REPO'\'') TO STDOUT" \
    | psql "$HEROKU_DB?sslmode=require" -c "\copy code_chunks ($COLS) FROM STDIN"
'
echo "Verifying..."
docker exec -e HEROKU_DB="$HEROKU_DB" "$PG_CONTAINER" \
  psql "$HEROKU_DB?sslmode=require" -c \
  "SELECT repo, count(*) chunks, count(embedding) embedded FROM code_chunks GROUP BY repo ORDER BY repo;"
echo "Done."