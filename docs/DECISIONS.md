# Waqti PWA — Decisions and Assumptions

Date: 2026-10-29. "Assumption" = temporary, must be confirmed (memorandum or Omar).

## Decisions

1. **New app, no Flutter code reused.** Requested by Omar. The Flutter app stays in place until
   this PWA is verified against the real database (prompt rule).
2. **Stack:** React 19 + TypeScript + Vite + `vite-plugin-pwa`, `@supabase/supabase-js`,
   self-hosted IBM Plex Sans Arabic. No router, no state library: three screens do not need them.
3. **Same look as the admin panel:** colors and radius copied from `waqti_admin/styles.css`
   (`--primary #004357`, etc.). Check-out uses an amber color so the two actions never look the same.
4. **Service worker caches the app shell only.** No API caching. ~~No offline queue~~ — offline
   punches were approved by Omar on 2026-10-30 (see Phase 3 below); they are queued by the app, not the service worker.
5. **Server is the only authority** for: the button action, the time, the location decision,
   duplicates. The client only reports what the device read.
6. **Idempotency key per tap** (`crypto.randomUUID()`), reused on retry after a lost reply.
7. **Three answers, three messages:** saved, rejected (with the reason), and *unconfirmed*
   (connection lost — we do not know). The app never shows "saved" or "failed" when it does not know.
8. **`expected_action`** is sent with every punch, so a stale screen (another device, old tab)
   can never record the wrong action.
9. **24-hour clock** in the company time zone, Western digits (`ar-LY`, `latn`).
10. **QR:** not included (removed from MVP).
11. **Biometrics:** not included. A PWA cannot use the Flutter `local_auth` plugin. Passkeys
    (WebAuthn) are possible later if the memorandum asks for them.
12. **Logout** ends the session on this device only (`scope: local`).

## Assumptions (to confirm)

- A1. One user belongs to one company (MVP).
- A2. Company time zone default `Africa/Tripoli`; `max_accuracy_m` default 100 m.
- ~~A3~~ Decided 2026-10-29: employees with `geofence_required = false` → `record` (save the location only).
- A4. Rate limit 5 punches / 60 s.
- A5. No confirmation dialog before a punch (one tap). The server-side `state_changed` and
  idempotency checks protect against mistakes and double taps. Easy to add if wanted.

## Phase 3 decisions (2026-10-29)

13. **Hosting:** GitHub Pages under `/waqti-app/` (free, HTTPS). Base path is a build setting (`BASE_PATH`).
14. **Older phones:** no dependency on `AbortSignal.any`, `AbortSignal.timeout` or `crypto.randomUUID`
    (iOS before 17.4 lacks some of them). Tested with those features removed.
15. **Server errors are mapped by their message first.** Account errors share SQLSTATE 42501 with real
    permission errors, so the code alone is not enough.
16. **iPhone install:** Safari has no install prompt, so a dismissible one-line hint explains
    "Share → Add to Home Screen".

## Offline punches (2026-10-30, approved by Omar — overrides the prompt's "no offline sync" rule)

17. **Acceptance rule:** only if the phone clock is consistent (signed server-time token + offset check +
    one-sided monotonic check). No admin review flag.
18. **Limit:** refused if it reaches the server more than 24 h after the punch.
19. **Location:** same rules as online; geofence + reject → refused at sync and shown to the employee.
20. **Queue:** in localStorage, per user, survives logout and app restarts; same request_id forever.
    Sent when the app is open and online (on start, on reconnect, every 30 s). No background sync
    (not available on iPhone; on Android it would need the login token inside the service worker).
21. **A lost reply while online** is now kept in the queue and re-sent automatically (was: a manual retry button).
22. **Opening the app offline** shows the last saved state, and keeps the employee signed in even if
    the 1-hour access token expired (the server still verifies a fresh token on every request).

### Known risks
- R1. A phone whose clock is corrected automatically while offline (e.g. wrong manual time fixed by
  the network later) is refused as `clock_changed`. Employees should keep "automatic time" on.
- R2. **Weekend gap:** a check-out made offline on Thursday evening and sent on Sunday morning is older
  than 24 h and is refused. The app warns the employee to open it with internet within 24 h.
- R3. Hand-crafted API requests can choose a time inside [last server contact, sync] (≤ 24 h).
- R4. Clearing the browser data or uninstalling the app before sync loses the queued punches.
