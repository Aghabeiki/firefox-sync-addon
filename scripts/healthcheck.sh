#!/usr/bin/env bash
# shellcheck shell=bash
#
# Probe a deployed syncstorage-rs add-on through its public reverse-proxy URL
# and report a verdict. Intended for users who have just installed the add-on
# and want a one-shot sanity check.
#
# Usage:
#     scripts/healthcheck.sh https://sync.example.com
#
# Exit code 0 if all probes pass, non-zero otherwise.
#
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <public-url>" >&2
    echo "       e.g. $0 https://firefox.aghabeiki.net" >&2
    exit 2
fi

URL="${1%/}"  # strip trailing slash

if [[ "${URL}" != https://* ]]; then
    echo "error: URL must use https:// (Firefox refuses non-HTTPS sync URLs)" >&2
    exit 2
fi

PASS=0
FAIL=0

probe() {
    local label="$1"
    local path="$2"
    local expected_status="$3"

    local status
    status=$(curl -sS -o /tmp/healthcheck.body -w "%{http_code}" "${URL}${path}" || echo "000")

    if [[ "${status}" == "${expected_status}" ]]; then
        echo "  PASS  ${label}: HTTP ${status}"
        if [[ -s /tmp/healthcheck.body ]]; then
            sed 's/^/        /' /tmp/healthcheck.body | head -5
        fi
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL  ${label}: expected HTTP ${expected_status}, got ${status}"
        if [[ -s /tmp/healthcheck.body ]]; then
            sed 's/^/        /' /tmp/healthcheck.body | head -5
        fi
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "Probing ${URL}"
echo

probe "/__lbheartbeat__ (process up)"     "/__lbheartbeat__"  "200"
probe "/__heartbeat__   (DB + FxA)"       "/__heartbeat__"    "200"
probe "/__version__     (upstream meta)"  "/__version__"      "200"

echo
echo "Heartbeat detail:"
HEARTBEAT_JSON=$(curl -fsS "${URL}/__heartbeat__" 2>/dev/null || true)
if command -v jq >/dev/null 2>&1; then
    echo "${HEARTBEAT_JSON}" | jq . 2>/dev/null || echo "${HEARTBEAT_JSON}"
else
    echo "${HEARTBEAT_JSON}"
fi

echo
case "${HEARTBEAT_JSON}" in
    *'"database":"Ok"'*'"status":"Ok"'*|*'"status":"Ok"'*'"database":"Ok"'*)
        DB_STATUS="ok"
        ;;
    *)
        DB_STATUS="not-ok"
        ;;
esac

echo "Verdict:"
echo "  ${PASS}/3 endpoints passed"
echo "  database: ${DB_STATUS}"

if [[ "${FAIL}" -ne 0 || "${DB_STATUS}" != "ok" ]]; then
    echo
    echo "FAIL. Check the add-on log in Home Assistant:"
    echo "  Settings > Add-ons > Syncstorage-rs > Log"
    exit 1
fi

echo
echo "OK. Server is healthy from the public internet."
echo
echo "Next: in Firefox about:config, set"
echo "  identity.sync.tokenserver.uri = ${URL}/1.0/sync/1.5"
echo "and restart Firefox."

rm -f /tmp/healthcheck.body
