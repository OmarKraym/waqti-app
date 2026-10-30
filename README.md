# وقتي — تطبيق الموظفين (PWA)

Employee attendance app for Waqti. Arabic, RTL, mobile-first, installable.

## Status

- ✅ Login with a persistent session, forced first-login password change (existing `change-password` Edge Function).
- ✅ One attendance button, label from the server (check-in / check-out).
- ✅ Three location policies (geofence / record / none), with separate messages for out-of-range, no location and weak accuracy.
- ✅ Safe on bad networks: a lost reply is shown as *unconfirmed*, and retry can never record twice.
- ✅ Connected to production (Phase 2 applied 2026-10-29). Server contract: [`docs/API_CONTRACT.md`](docs/API_CONTRACT.md).
- ✅ Works on older phones (no `AbortSignal.any` / `crypto.randomUUID` needed). Phone test: [`docs/PHONE_TEST.md`](docs/PHONE_TEST.md).
- ✅ **Offline punches** (2026-10-30): saved on the phone, sent automatically when online, accepted only if
  the phone clock is consistent and within 24 h. See `docs/API_CONTRACT.md` §3 and `docs/DECISIONS.md`.

## Run

```bash
npm install
cp .env.example .env      # fill in the Supabase URL and the PUBLISHABLE key
npm run dev
```

Demo mode (fake server, no Supabase needed):

```bash
VITE_MOCK=1 npm run dev
```

Demo scenarios from the URL, for example `http://localhost:5173/?policy=geofence&outside=reject&pos=outside`:

| Parameter | Values |
|---|---|
| `policy` | `geofence` (default), `record`, `none` |
| `outside` | `flag` (default), `reject` |
| `pos` | `inside` (default), `outside`, `far-accuracy` |
| `net` | `flaky` — every 2nd punch loses its reply (tests the retry) |
| `must_change` | `1` — first login with forced password change |

## Scripts

| Command | What it does |
|---|---|
| `npm run dev` | Dev server |
| `npm run build` | Type-check + production build (`dist/`) |
| `npm test` | Unit tests (state machine, location) |
| `npm run typecheck` | TypeScript only |

## Deploy

Live: **https://omarkraym.github.io/waqti-app/** (GitHub Pages, branch `gh-pages`).

```bash
./scripts/deploy-gh-pages.sh          # tests, builds for /waqti-app/, pushes dist to gh-pages
```

Other hosts: any static host with **HTTPS** (location and install need HTTPS). Build with
`BASE_PATH=/your/path/ npm run build` (default `/`) and upload `dist/`.

## Security

- Only the **publishable** key is in the app. Never put the `service_role` key in a `VITE_` variable.
- All rules (who, when, where, duplicates) are enforced by the database. The app only displays them.

## Structure

```
src/
  lib/
    types.ts         server shapes
    api.ts           API interface
    supabaseApi.ts   real API (Supabase)
    mockApi.ts       fake API for demo mode
    attendance.ts    screen state machine (pure, tested)
    offlineQueue.ts  offline punches: queue, time anchor, sync (pure, tested)
    location.ts      one-shot location reading
    errors.ts        error codes + Arabic messages
  screens/           Login, ChangePassword, Home
docs/
  API_CONTRACT.md    what the server must provide (Phase 2)
  DECISIONS.md       decisions and open assumptions
```
