#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
#
# syncstorage-rs Home Assistant add-on entrypoint.
#
# Pulls MariaDB credentials from the Supervisor's mysql service binding,
# bootstraps the two databases the server expects, validates user config,
# exports the SYNC_* environment the upstream binary reads, and execs it.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Pull MariaDB credentials injected by the Supervisor (mysql service).
# ---------------------------------------------------------------------------
DB_HOST=$(bashio::services "mysql" "host")
DB_PORT=$(bashio::services "mysql" "port")
DB_USER=$(bashio::services "mysql" "username")
DB_PASS=$(bashio::services "mysql" "password")

bashio::log.info "Ensuring databases exist on ${DB_HOST}:${DB_PORT}"

# utf8mb4/unicode_ci matches what upstream's diesel migrations expect. The
# server itself runs the schema migrations on first start when
# tokenserver.run_migrations is true (set below).
mysql \
    -h "${DB_HOST}" \
    -P "${DB_PORT}" \
    -u "${DB_USER}" \
    -p"${DB_PASS}" <<'SQL'
CREATE DATABASE IF NOT EXISTS syncstorage_rs
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS tokenserver_rs
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

# ---------------------------------------------------------------------------
# Validate user-supplied config.
# ---------------------------------------------------------------------------
MASTER_SECRET=$(bashio::config 'master_secret')
PUBLIC_URL=$(bashio::config 'public_url')
FXA_OAUTH_SERVER_URL=$(bashio::config 'fxa_oauth_server_url')
FXA_EMAIL_DOMAIN=$(bashio::config 'fxa_email_domain')
ENABLE_QUOTA=$(bashio::config 'enable_quota')
MAX_TOTAL_RECORDS=$(bashio::config 'max_total_records')
LOG_LEVEL=$(bashio::config 'log_level')
HUMAN_LOGS=$(bashio::config 'human_logs')

if [[ -z "${MASTER_SECRET}" ]]; then
    bashio::exit.nok \
        "master_secret is empty. Generate a 64+ char random string with \
'openssl rand -hex 32' and set it in the add-on configuration."
fi

if (( ${#MASTER_SECRET} < 16 )); then
    bashio::exit.nok \
        "master_secret is shorter than 16 characters. Use 'openssl rand -hex 32'."
fi

if [[ -z "${PUBLIC_URL}" ]]; then
    bashio::exit.nok \
        "public_url is empty. Set it to the HTTPS URL Firefox will hit, \
e.g. https://sync.example.com"
fi

if [[ "${PUBLIC_URL}" != https://* ]]; then
    bashio::exit.nok \
        "public_url must use https://. Firefox refuses non-HTTPS sync URLs."
fi

# Strip a trailing slash if the user added one — upstream concatenates paths.
PUBLIC_URL="${PUBLIC_URL%/}"

# ---------------------------------------------------------------------------
# Export upstream's SYNC_* settings. The config crate maps these as
# `SYNC_FOO__BAR=baz` -> settings.foo.bar = "baz".
# ---------------------------------------------------------------------------
export SYNC_HOST="0.0.0.0"
export SYNC_PORT="8000"
export SYNC_HUMAN_LOGS="${HUMAN_LOGS}"
export SYNC_MASTER_SECRET="${MASTER_SECRET}"

# Syncstorage (data plane).
export SYNC_SYNCSTORAGE__DATABASE_URL="mysql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/syncstorage_rs"
export SYNC_SYNCSTORAGE__ENABLE_QUOTA="${ENABLE_QUOTA}"
export SYNC_SYNCSTORAGE__LIMITS__MAX_TOTAL_RECORDS="${MAX_TOTAL_RECORDS}"

# Tokenserver (auth plane). NODE_TYPE must match the syncstorage backend
# (mysql here). INIT_NODE_URL is the public URL Firefox is told to use.
export SYNC_TOKENSERVER__ENABLED="true"
export SYNC_TOKENSERVER__RUN_MIGRATIONS="true"
export SYNC_TOKENSERVER__DATABASE_URL="mysql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/tokenserver_rs"
export SYNC_TOKENSERVER__NODE_TYPE="mysql"
export SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN="${FXA_EMAIL_DOMAIN}"
export SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL="${FXA_OAUTH_SERVER_URL}"
export SYNC_TOKENSERVER__INIT_NODE_URL="${PUBLIC_URL}"

# When the OAuth JWK is not pre-cached locally (we don't cache it), upstream
# refuses to start unless this is set.
export SYNC_TOKENSERVER__ADDITIONAL_BLOCKING_THREADS_FOR_FXA_REQUESTS="10"

# Rust log routing. Upstream honours RUST_LOG via slog-envlogger.
export RUST_LOG="${LOG_LEVEL}"

bashio::log.info \
    "Starting syncstorage-rs on :8000 (public URL: ${PUBLIC_URL})"

exec /usr/local/bin/syncserver
