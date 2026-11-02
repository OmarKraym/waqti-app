#!/usr/bin/env bash
# usage: run.sh POOL [ACQ_MS]
#   Fresh database from the template, an emulated API server (NOT PostgREST) with POOL database connections,
#   and 60 employees calling it at the same moment. Local only. Needs `npm install` in this folder and prepare.sh first.
set -uo pipefail
export POOL=${1:-10} ACQ_MS=${2:-10000} DB=waqti_load PORT=3999 JWT_SECRET=$(head -c 32 /dev/urandom | base64) LOADDIR=${LOADDIR:-/tmp/loadapi}
psql -X -q -c "drop database if exists $DB" -c "create database $DB template waqti_load_tpl" >/dev/null
cd "$(dirname "$0")"
node server.mjs >"$LOADDIR/server.log" 2>&1 &
SP=$!
for i in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:$PORT/rpc/x && break; sleep 0.1; done
node drive.mjs
kill $SP 2>/dev/null; wait $SP 2>/dev/null
