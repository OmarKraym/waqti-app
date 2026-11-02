#!/usr/bin/env bash
# Builds a TEMPLATE database (waqti_load_tpl) for the API-layer load test. Local Postgres only, never production.
# Run as a user that may create databases (e.g. su postgres -c "bash prepare.sh").
set -euo pipefail
W=${LOADDIR:-/tmp/loadapi}; mkdir -p "$W"
cd "$(dirname "$0")/../.."
DB=waqti_load_tpl
sed -n '/^reset_db() {/,/^}/p' local/test-db.sh > "$W/reset_fn.sh"
source "$W/reset_fn.sh"
PSQL="psql -X -v ON_ERROR_STOP=1 -q"
psql -X -qc "alter database $DB is_template false" 2>/dev/null || true   # a template cannot be dropped
reset_db
psql -X -q -d $DB <<'SQL'
update public.employees set location_policy = 'none' where is_active;
update public.companies set punch_windows_enabled = false;
SQL
psql -X -qAt -d $DB -c "select id from employees where employee_number between '001' and '060' order by employee_number" > "$W/ids.txt"
wc -l < "$W/ids.txt" | xargs echo "employees prepared:"
psql -X -qc "alter database $DB is_template true"
