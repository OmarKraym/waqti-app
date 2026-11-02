# API-layer load test (local only)

What it is: 60 employees call the punch functions at the same moment through a small server that imitates one PostgREST
call (JWT check, limited pool of database connections, `begin`, `set local role authenticated`, claims, function, `commit`).
What it is not: PostgREST itself, Supabase Auth, Edge Functions, or the network. It cannot show Supabase's per-IP Auth limits.

    cd supabase/local/loadtest && npm install
    su postgres -c "bash $PWD/prepare.sh"      # once (builds waqti_load_tpl)
    su postgres -c "bash $PWD/run.sh 10"       # POOL=10; try 2, 3, 60
    su postgres -c "bash $PWD/run.sh 1 25"     # control: must show 503 failures, proving the test can fail

Waves: app opens, check-in rush, check-out double tap (same request id), check-in twice per person (different ids: exactly
one wins), and chains of four calls per employee. After each wave the database is counted.
