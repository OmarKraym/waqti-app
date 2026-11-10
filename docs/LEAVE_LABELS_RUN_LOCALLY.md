# Leave-type labels: «اضطرارية» and «وضع» everywhere

The admin panel is the source of truth for the leave-type words: **emergency = «اضطرارية»**, **maternity = «وضع»**.
The app and the notification text in the database said «طارئة» and «أمومة». This change makes all three say the same.

| Where | Before | After |
|---|---|---|
| App `LEAVE_LABEL` (`src/lib/requests.ts`): request titles, balances, the leave select, the profile summary | طارئة / أمومة | اضطرارية / وضع |
| App error `maternity_female_only` (`src/lib/errors.ts`) | إجازة الأمومة غير متاحة لهذا الحساب. | إجازة الوضع غير متاحة لهذا الحساب. |
| Database `private.request_summary` (push and in-app notification text) | إجازة طارئة / إجازة أمومة | إجازة اضطرارية / إجازة وضع |

Notifications that were already stored keep the words they were written with. Stored rows are not rewritten.

## Migration
`supabase/migrations/20261112090000_leave_labels.sql`, rollback `…_ROLLBACK.sql`. It replaces **only** `private.request_summary(uuid)`,
and only those two words: same signature, `security definer`, `stable`, `search_path = ''`, and the same revokes (no client may execute it).
No table, column, grant or other function changes. The file has no backslash.

| `private.request_summary(uuid)` | `md5(prosrc)` |
|---|---|
| before (phase 24, also on production since 2026-11-10) | `6a25385c316c32caebc4eb4bfdd83d22` |
| after this migration | `666fe4ebf818ea32addd61def160dd13` |
| after the rollback | `6a25385c316c32caebc4eb4bfdd83d22` (proven locally) |

## Tests
- Database: `supabase/tests/leave_labels_tests.sql` (9 checks): the summary of each of the six built-in leave types starts with
  «إجازة <word>» from the pinned map, the old words are gone from the function, and its security settings and grants are unchanged.
  Before the migration: 3 failures (emergency, maternity, old words present). After: 9/9. After the rollback: the same 3 failures.
  `cd supabase && PGDATABASE=postgres TESTS=tests/leave_labels_tests.sql bash local/test-db.sh`
- App: `src/lib/leaveLabels.test.ts` pins the whole map, the two titles and the error text.
- Panel: `tests/leave-labels.test.mjs` pins `LEAVE_LABEL` (`js/lib/leave-text.js`) and the Excel report's `LEAVE_TEXT` to the same map.

## Applying it (needs Omar's «نعم»)
Independent of any other change: the app and the migration can go in either order (each one is only a word in a text).
1. Check production still shows `6a25385c316c32caebc4eb4bfdd83d22` for `private.request_summary(uuid)`.
2. `apply_migration` with the exact file text.
3. Check `666fe4ebf818ea32addd61def160dd13`, `prosecdef = true`, `provolatile = 's'`, `proconfig = {search_path=""}`,
   and `has_function_privilege('authenticated', 'private.request_summary(uuid)', 'execute') = false`.
