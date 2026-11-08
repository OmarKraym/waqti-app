#!/usr/bin/env bash
# Concurrency check of the monthly permission limit (phase 19c). Local only, never against production.
# Builds a throwaway database (same steps as test-db.sh), makes the late-arrival type "1 per month", then two real
# sessions try to add a pending request for the SAME employee at the SAME time. The first one keeps its transaction open
# for 2 seconds after the insert, so the second one starts while the first is not committed yet.
#   case 1  through employee_submit_request (the real path) : expect  1 success, 1 permission_limit
#   case 2  a plain INSERT, bypassing that function         : expect  1 success, 1 permission_limit  (needs the 19c trigger)
# DROP_TRIGGER=1 drops the trigger first (the "mutant"): case 2 then ends with 2 successes and the script fails.
#   PGHOST/PGPORT/PGUSER point to a local server where you may create databases. Needs PostGIS.
#   Run:  bash local/concurrency-limit.sh      mutant:  DROP_TRIGGER=1 bash local/concurrency-limit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DB=waqti_conc
PSQL="psql -X -v ON_ERROR_STOP=1 -q"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

psql -X -qc "drop database if exists $DB" -c "create database $DB" >/dev/null
$PSQL -d $DB -f local/shim.sql
python3 - <<'PY'
s = open('baseline/00_tables.sql').read(); i = s.find('CREATE TRIGGER')
open('/tmp/waqti_conc_a.sql', 'w').write("set search_path = public, extensions;\n" + s[:i])
open('/tmp/waqti_conc_c.sql', 'w').write("set search_path = public, extensions;\n" + s[i:])
PY
$PSQL -d $DB -1 -f /tmp/waqti_conc_a.sql
PGOPTIONS="-c check_function_bodies=off" $PSQL -d $DB -1 -f baseline/01_functions.sql
$PSQL -d $DB -1 -f /tmp/waqti_conc_c.sql
$PSQL -d $DB -1 -f local/seed.sql
for m in $(ls migrations/*.sql | grep -v ROLLBACK | grep -v phase5b); do $PSQL -d $DB -1 -f "$m" >/dev/null 2>&1 || { echo "migration failed: $m"; exit 2; }; done

# one employee, a working day today, a late-arrival type that allows 1 per month and only today
read -r EMP COMP TZ TYPE < <($PSQL -d $DB -At -F ' ' <<'SQL'
select e.id, e.company_id, c.timezone, t.id
from public.employees e
join public.companies c on c.id = e.company_id
join public.permission_types t on t.company_id = e.company_id and t.mode = 'late_arrival'
where e.is_active and e.id <> (select id from auth.users where email = 'admin@example.com')
order by e.employee_number, t.sort_order limit 1;
SQL
)
$PSQL -d $DB <<SQL
delete from public.employee_work_schedules where employee_id = '$EMP';
insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select '$EMP', g, true, time '08:00', time '16:00', '$COMP' from generate_series(0, 6) g;
update public.permission_types set max_per_month = 1, max_minutes = null, days_back = 0, days_ahead = 0, is_active = true where id = '$TYPE';
SQL
if [ "${DROP_TRIGGER:-0}" = "1" ]; then
  $PSQL -d $DB -c "drop trigger requests_limit_guard on public.requests"
  echo "MUTANT: the guard trigger was dropped"
fi

TODAY="(date_trunc('day', now() at time zone '$TZ'))"      # local midnight (timestamp)

# $1 = case name, $2 = session label (a|b), $3 = seconds to keep the transaction open after the insert
session_fn() {
  $PSQL -d $DB <<SQL >"$OUT/$1.$2.out" 2>&1
begin;
select set_config('request.jwt.claims', json_build_object('sub', '$EMP', 'role', 'authenticated')::text, true);
set local role authenticated;
select public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null, null,
  ($TODAY + interval '9 hours') at time zone '$TZ', null, false, '$TYPE');
select pg_sleep($3);
commit;
SQL
  echo $? >"$OUT/$1.$2.rc"
}
session_insert() {
  $PSQL -d $DB <<SQL >"$OUT/$1.$2.out" 2>&1
begin;
insert into public.requests (employee_id, request_type, status, start_at, end_at, company_id, permission_type_id, minutes)
values ('$EMP', 'permission', 'pending', ($TODAY + interval '8 hours') at time zone '$TZ', ($TODAY + interval '9 hours') at time zone '$TZ',
        '$COMP', '$TYPE', 60);
select pg_sleep($3);
commit;
SQL
  echo $? >"$OUT/$1.$2.rc"
}

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
verdict() {   # $1 = case name: prints "N success, M permission_limit" and the wait of the second session
  local ok=0 lim=0 other=0 s
  for s in a b; do
    if grep -q permission_limit "$OUT/$1.$s.out"; then lim=$((lim + 1))
    elif [ "$(cat "$OUT/$1.$s.rc")" = "0" ]; then ok=$((ok + 1))
    else other=$((other + 1)); echo "  unexpected error in session $s: $(head -c 300 "$OUT/$1.$s.out")" >&2; fi
  done
  local r="$ok success, $lim permission_limit"; [ "$other" -gt 0 ] && r="$r, $other other error"
  echo "$r"
}
race() {   # $1 = case name, $2 = function name running one session
  $PSQL -d $DB -c "delete from public.requests where employee_id = '$EMP'"
  "$2" "$1" a 2 &
  sleep 0.7
  local t0; t0=$(now_ms)
  "$2" "$1" b 0
  WAIT_MS=$(( $(now_ms) - t0 ))
  wait
}

fail=0
race fn session_fn;      r1=$(verdict fn);     w1=$WAIT_MS
race ins session_insert; r2=$(verdict ins);    w2=$WAIT_MS
want="1 success, 1 permission_limit"
printf 'through employee_submit_request : %-32s (second session ran %s ms)  ' "$r1" "$w1"; [ "$r1" = "$want" ] && echo OK || { echo "FAIL (expected: $want)"; fail=1; }
printf 'plain INSERT, no function       : %-32s (second session ran %s ms)  ' "$r2" "$w2"; [ "$r2" = "$want" ] && echo OK || { echo "FAIL (expected: $want)"; fail=1; }
exit $fail
