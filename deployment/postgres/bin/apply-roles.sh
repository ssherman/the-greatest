#!/usr/bin/env bash
# deployment/postgres/bin/apply-roles.sh
# Creates the three login roles, their databases and rights, and the extensions tgb expects. Spec §5.2.
# Safe to repeat: roles and databases are created only if absent, every grant is idempotent, and the
# only thing a re-run changes is the passwords (ALTER ROLE), which is how a rotation takes effect.
#
# Passwords come from the environment and travel to psql on stdin; nothing secret reaches a command
# line. The session first turns off every place a statement is recorded, because an ALTER ROLE ...
# PASSWORD statement carries the password as text: pg_stat_statements would keep it (and tgb_app, a
# pg_monitor member, could read it), and a failing statement is logged in full.
#
#   POSTGRES_THE_GREATEST_PASSWORD  POSTGRES_TGB_APP_PASSWORD  POSTGRES_TGB_READER_PASSWORD
#   POSTGRES_SUPERUSER_PASSWORD     not used here, but compose interpolates it for every `docker compose`
#                                   call, so it must be set in the environment too
#   COMPOSE_FILE  compose file of the running server (default: ../compose.yml)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for v in POSTGRES_THE_GREATEST_PASSWORD POSTGRES_TGB_APP_PASSWORD POSTGRES_TGB_READER_PASSWORD; do
  if [ -z "${!v:-}" ]; then echo "apply-roles: $v is missing" >&2; exit 2; fi
done
compose_file="${COMPOSE_FILE:-$here/../compose.yml}"

# A SQL string literal: quotes doubled. Backslashes are literal because standard_conforming_strings
# is on (the default); the script sets it explicitly below so it never depends on a server setting.
lit() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

role() {   # role NAME PASSWORD
  printf "SELECT 'CREATE ROLE %s' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') \\\\gexec\n" "$1" "$1"
  printf "ALTER ROLE %s WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %s;\n" "$1" "$(lit "$2")"
}
database() {   # database NAME OWNER
  printf "SELECT 'CREATE DATABASE %s OWNER %s' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '%s') \\\\gexec\n" "$1" "$2" "$1"
  printf "ALTER DATABASE %s OWNER TO %s;\n" "$1" "$2"
  printf "REVOKE ALL ON DATABASE %s FROM PUBLIC;\n" "$1"
}

sql() {
  cat <<'SQL'
SET standard_conforming_strings = on;
SET pg_stat_statements.track = 'none';
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET log_min_duration_statement = -1;
SET client_min_messages = warning;
SQL
  role the_greatest "$POSTGRES_THE_GREATEST_PASSWORD"
  role tgb_app "$POSTGRES_TGB_APP_PASSWORD"
  role tgb_reader "$POSTGRES_TGB_READER_PASSWORD"
  database the_greatest the_greatest
  database tgb tgb_app
  cat <<'SQL'
-- The maintenance databases are not for the app logins.
REVOKE ALL ON DATABASE postgres FROM PUBLIC;
REVOKE ALL ON DATABASE template1 FROM PUBLIC;
GRANT pg_monitor TO tgb_app;
GRANT CONNECT ON DATABASE tgb TO tgb_reader;

\connect tgb
SET client_min_messages = warning;
ALTER SCHEMA public OWNER TO tgb_app;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
GRANT USAGE ON SCHEMA public TO tgb_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO tgb_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE tgb_app IN SCHEMA public GRANT SELECT ON TABLES TO tgb_reader;
SQL
}

sql | docker compose -f "$compose_file" exec -T postgres psql -U postgres -X -q -v ON_ERROR_STOP=1
echo "apply-roles: done"
