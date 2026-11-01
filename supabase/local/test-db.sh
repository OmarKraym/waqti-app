#!/usr/bin/env bash
# Local database tests (never against production).
# Builds a throwaway Postgres 16 database that imitates Supabase (local/shim.sql), loads the production baseline
# (baseline/), applies every migration (except phase 5b, which needs pg_cron), adds synthetic data (local/seed.sql)
# and runs each file in tests/ on a fresh copy.
#   PGHOST/PGPORT/PGUSER point to a local server where you may create databases. Needs PostGIS.
#   Some tests pick dates relative to today and assume a Sat-Thu week; run the server with a fixed clock
#   (e.g. libfaketime, FAKETIME='@2026-10-31 10:00:00') if a test fails only because of the weekday.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=waqti_test
PSQL="psql -X -v ON_ERROR_STOP=1 -q"
reset_db() {
  psql -X -qc "drop database if exists $DB" -c "create database $DB" >/dev/null
  $PSQL -d $DB -f local/shim.sql
  python3 - <<'PY'
s = open('baseline/00_tables.sql').read(); i = s.find('CREATE TRIGGER')
open('/tmp/waqti_a.sql', 'w').write("set search_path = public, extensions;\n" + s[:i])
open('/tmp/waqti_c.sql', 'w').write("set search_path = public, extensions;\n" + s[i:])
PY
  $PSQL -d $DB -1 -f /tmp/waqti_a.sql
  PGOPTIONS="-c check_function_bodies=off" $PSQL -d $DB -1 -f baseline/01_functions.sql
  $PSQL -d $DB -1 -f /tmp/waqti_c.sql
  $PSQL -d $DB -1 -f local/seed.sql
  for m in $(ls migrations/*.sql | grep -v ROLLBACK | grep -v phase5b); do $PSQL -d $DB -1 -f "$m"; done
}
total=0; failed=0
for t in tests/*.sql; do
  reset_db
  r=$(psql -X -q -d $DB -v admin_email=admin@example.com -f "$t" 2>&1 | grep -oE "RESULT passed=[0-9]+ failed=[0-9]+|FAIL [0-9]+:.*" || true)
  echo "$(basename "$t"): ${r:-NO RESULT}"
  p=$(echo "$r" | sed -nE 's/.*passed=([0-9]+).*/\1/p' | head -1); f=$(echo "$r" | sed -nE 's/.*failed=([0-9]+).*/\1/p' | head -1)
  [ "${p:-0}" -eq 0 ] && f=$(( ${f:-0} + 1 ))   # a file that passed nothing (stopped on an error) is a failure
  total=$((total + ${p:-0})); failed=$((failed + ${f:-1}))
done
echo "TOTAL passed=$total failed=$failed"
[ "$failed" -eq 0 ]
