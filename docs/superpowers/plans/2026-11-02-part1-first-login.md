# Part 1 — First login: password, then fingerprint, then home — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After the temporary password is replaced, an employee whose company requires the fingerprint must register this phone before seeing anything else; email is always pre-filled; works the same on Android and iPhone.

**Architecture:** A pure function `nextGate` decides the screen (`password` → `device` → `home`). A new `GateAfterPassword` component sits in `App.tsx` between `ChangePassword` and `Main`, reads the attendance state once (policy + device), and shows `DeviceSetup` full-screen when needed. No database change.

**Tech Stack:** React + Vite + TS, vitest, Playwright harness (mock mode, `VITE_MOCK=1`, port 5199), `@simplewebauthn/browser`.

**Spec:** `docs/superpowers/specs/2026-11-02-onboarding-review-admins-handling-design.md` (Part 1)

## Global Constraints

- Arabic RTL only; no new dependency.
- Storage access never throws (wrap in try/catch, like `localSettings.ts`).
- Policy decides: fingerprint step only when `biometric.policy === "required"`.
- Fail closed for the fingerprint gate: if the state cannot be read, show a retry screen, never `Main`.
- Never use `hidden`/`display:none` for the username input of password forms.
- Do not touch production, do not deploy; commit to branch `ui/bright-palette-dark-mode` with the trailers from the session reminder.

## Review Focus

- State read fails (offline/slow) at the gate → retry screen with "إعادة المحاولة" and "تسجيل الخروج"; never reaches home.
- Employee cancels the fingerprint prompt → stays on the setup screen with the message, can retry or sign out (never trapped).
- Registration "succeeds" but the refreshed state still says no device → error message, no loop into home.
- Phone without a platform authenticator → explanatory message and a "متابعة" button; punches are flagged "بدون بصمة" by the server as today.
- Storage blocked (private mode) → last email just isn't remembered; login still works. Stored email is trimmed and lower-cased; an invalid/odd stored value is ignored.

---

### Task 1: Gate decision + remembered email (pure logic)

**Files:**
- Create: `src/lib/firstRun.ts`, `src/lib/firstRun.test.ts`
- Modify: `src/lib/localSettings.ts` (add email helpers), `src/lib/localSettings.test.ts`

**Interfaces:**
- Produces: `export type Gate = "device" | "unsupported" | "home";`
- Produces: `export function nextGate(b: BiometricState | undefined, supported: boolean): Gate` — `home` when `b` is missing, policy ≠ `required`, or `has_device`; `device` when required, no device, supported; `unsupported` when required, no device, not supported.
- Produces: `export function iosBrowserTab(ua: string, standalone: boolean | undefined): boolean` — true for iPhone/iPad/iPod user agents when `standalone === false`.
- Produces (in `localSettings.ts`): `readLastEmail(store?): string | null`, `saveLastEmail(email: string, store?): void` — key `waqti-last-email`, value trimmed + lower-cased, ignored unless it matches `/^[^\s@]+@[^\s@]+$/` and is ≤ 254 chars.

- [ ] **Step 1: Write failing tests** — `firstRun.test.ts`: `nextGate` table (policy off → home; required+device → home; required+no device+supported → device; required+no device+unsupported → unsupported; undefined → home); `iosBrowserTab` (iPhone UA + standalone false → true; iPhone + true → false; Android UA + false → false; undefined → false). `localSettings.test.ts`: save `"  Ahmed@Example.COM "` then read → `"ahmed@example.com"`; garbage value (`"x"`, 300-char string) → `null`; a store whose `setItem` throws does not throw.
- [ ] **Step 2: Run** `npx vitest run src/lib/firstRun.test.ts src/lib/localSettings.test.ts` — expect FAIL (missing exports).
- [ ] **Step 3: Implement** the four functions with the signatures above.
- [ ] **Step 4: Run** the same command — expect PASS.
- [ ] **Step 5: Commit** `feat: first-run gate decision and remembered email`.

### Task 2: Login and password forms (autofill for Android and iPhone)

**Files:**
- Modify: `src/screens/Login.tsx`, `src/screens/ChangePassword.tsx`

**Interfaces:**
- Consumes: `readLastEmail`, `saveLastEmail` (Task 1).

- [ ] **Step 1: Login** — initial `email` state = `readLastEmail() ?? ""`; email input gets `name="email"`, `id="email"`, `autoCapitalize="none"`, `autoCorrect="off"`, `spellCheck={false}`; password input gets `name="password"`; after a successful `api.signIn` call `saveLastEmail(email)`. If the email was pre-filled, focus the password input on mount (`autoFocus` on password only in that case).
- [ ] **Step 2: ChangePassword** — replace the `hidden` username input with a visually hidden one: `className="sr-only"`, `name="email"`, `id="email"`, `autoComplete="username"`, `tabIndex={-1}`, `aria-hidden="true"`, `readOnly`, value = session email; password inputs get `name="new-password"` / `name="confirm-password"`; call `saveLastEmail(email)` when `email` is set (on mount).
- [ ] **Step 3: Verify** with a Playwright script (`scratchpad/harness/firstlogin-check.mjs`): `?must_change=1` → the username input exists, is not `display:none`, has `autocomplete=username` and the session email; after signing in once and reloading to the login screen the email field is pre-filled.
- [ ] **Step 4: Run** `npx tsc --noEmit -p .` and `npx vitest run` — expect clean.
- [ ] **Step 5: Commit** `feat: password-manager friendly sign-in and password forms; remember last email`.

### Task 3: Fingerprint gate after the password

**Files:**
- Create: `src/screens/GateAfterPassword.tsx`
- Modify: `src/App.tsx`, `src/screens/DeviceSetup.tsx` (props: `onSignOut?: () => void`, `iosTabHint?: boolean`; keeps working inside Home), `src/lib/mockApi.ts`, `src/styles.css`

**Interfaces:**
- Consumes: `nextGate`, `iosBrowserTab` (Task 1); `supportsPlatformAuthenticator` (existing); `api.getAttendanceState()`.
- Produces: `export function GateAfterPassword({ user }: { user: SessionUser }): JSX.Element` — states `loading | error | device | unsupported | ready`; renders `Main` only in `ready`.
- Mock: query `?bio=new` → state `biometric = { policy: "required", has_device: false }`; the mock registration flow flips `has_device` to true on success (same endpoints `registerDevice` calls today).

- [ ] **Step 1: Failing check first** — Playwright `firstlogin-check.mjs`, scenario A (`?must_change=1&bio=new`, Chromium virtual authenticator via CDP `WebAuthn.enable` + `addVirtualAuthenticator` with `protocol: ctap2, transport: internal, hasUserVerification: true, isUserVerified: true`): sign in → password screen → save password → **fingerprint screen** (no tabs, no punch button) → register → home. Expect FAIL before the implementation (goes straight to home).
- [ ] **Step 2: Implement** `GateAfterPassword`; in `App.tsx` render it instead of `<Main user={gate.user} />`. `unsupported` shows the explanation and a "متابعة" button; `error` shows "إعادة المحاولة" + "تسجيل الخروج"; `device` shows `DeviceSetup` plus a quiet "تسجيل الخروج" button; after `onDone` re-read the state and go to `ready` only if `has_device` is now true, else show the error banner.
- [ ] **Step 3: Implement the mock** `?bio=new` as described.
- [ ] **Step 4: Scenarios B–E in the same script:** B `?bio=1` (has device) → straight to home; C no `bio` param (policy off) → straight to home; D `?bio=new` with the virtual authenticator removed (unsupported) → message → "متابعة" → home; E `?bio=new&net=flaky` first state read fails → retry screen, never home. Run the script — expect all ✓.
- [ ] **Step 5: Run** `npx tsc --noEmit -p .`, `npx vitest run`, and the older harness scripts that touch login/home (`app-check.mjs`) — expect clean.
- [ ] **Step 6: Commit** `feat: fingerprint registration gate right after the first password`.

### Task 4: iOS hint, phone-test checklist, delivery notes

**Files:**
- Modify: `src/screens/GateAfterPassword.tsx`, `docs/PHONE_TEST.md`

- [ ] **Step 1:** In the `unsupported` state show the hint "إن لم تعمل البصمة، أضف التطبيق إلى الشاشة الرئيسية وافتحه منها" only when `iosBrowserTab(navigator.userAgent, (navigator as { standalone?: boolean }).standalone)` is true.
- [ ] **Step 2:** Add a "Part 1 — first login" section to `docs/PHONE_TEST.md`: steps for one Android phone and one iPhone (temporary password → new password → password-manager save prompt shows the right email → fingerprint registration → close and reopen → fingerprint login), and the expected result for each; mark clearly that these were **not** run by the assistant.
- [ ] **Step 3: Run** the full gate: `npx tsc --noEmit -p .`, `npx vitest run`, all harness scripts; expect clean.
- [ ] **Step 4: Commit and push** to `ui/bright-palette-dark-mode`; do **not** deploy. Report to Omar and ask for "نعم" to deploy (no database change in this part).
