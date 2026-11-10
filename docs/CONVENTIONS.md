# Conventions — app (waqti-app) and admin panel (waqti-admin)

One vocabulary for both products. Brand colours and radius *values* stay per product; names, tiers and scales are shared.
Enforced by `npm run lint:css` (stylelint 17.16.0, both repos), `src/lib/palette.test.ts` (app) and `tests/tokens.test.mjs` (panel).

## 1. Tokens — three tiers
| Tier | Pattern | Who may use it |
|---|---|---|
| Primitive | `--palette-<hue>-<darkness>`, `--font-size-2xs…2xl`, `--space-px, 0-5, 1 … 8`, `--radius-xs/sm/md/lg/xl/pill/round`, `--z-below/sticky/nav/fab/float/menu/modal/toast`, `--motion-fast/base/slow`, `--ease-*` | token files only |
| Semantic | `--color-<role>` (`text`, `text-muted`, `surface`, `accent`, `danger-text` …), `--shadow-*`, `--size-*`, `--layout-*` | any rule |
| Component | `--<component>-<property>` (`--hero-bg`, `--punch-size`, `--switch-knob-size`) | that component's file |

- Rules never hold a literal colour, font size, radius, z-index or spacing; `0`, `1px` hairlines and runtime geometry are the only exceptions.
- Dark mode redefines **semantic and component tokens only**, under `@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) }` and `:root[data-theme="dark"]` — the two blocks are identical.
- A value off the scale snaps to the nearest step; ties round down.

## 2. CSS architecture
- Layers, in this order: `@layer reset, tokens, base, layout, components, utilities;` No `!important`.
- One file per component (`src/styles/components/*.css`, `src/styles/screens/*.css` in the app; `styles/{tokens,base,layout,components,utilities}.css` in the panel).
- Naming is BEM: `.block`, `.block__element`, `.block--modifier`; state is `.is-*` (`is-active`, `is-fresh`); utilities are `.u-*`. Modifiers stay compound (`.btn.btn--primary`) so specificity does not change.
- JS and tests hook onto `data-*` attributes (`data-act`, `data-hook`, `data-role`), never onto styling classes.
- Logical properties only (`inline-start`, `margin-inline`, `text-align: end`); no physical left/right.
- No inline `style` attributes. The panel's menu position (computed per open) is the only runtime style write.

## 3. Components
- **App (React/TS):** `src/components` holds the typed primitives — `Button` (variant, size, block, icon; default `type="button"`), `IconButton`, `Chip`, `Card`, `Field`, `EmptyState`, `ConfirmDialog` — plus `Icon`, `Switch`, `AppBar`, `Banner`, `Modal`, `PasswordInput`, `TimeField`. Import from `src/components` (barrel). Logic lives in `src/hooks` (`useAttendance`, `useRequests`, `useNewRequest`); screens are thin and split under `src/screens/<screen>/`.
- **Panel (ESM JS):** `js/core/ui.js` factories — `button(label, {variant, size, block, icon})`, `badge(kind, text)`, `emptyState(text)`, `confirmDialog(message, {title, confirmLabel, danger}) → Promise<boolean>`. Never `window.confirm`. Server calls go through `js/core/api.js` `rpc(name, args)` (throws) and `withBusy(btn, fn)`; raw `sb.rpc` stays only where a caller reads the error to detect a missing database function. Pure rules live in `js/lib/*.js` with a node test each; modules are kebab-case ESM, no `window.*` globals; config is `js/config.js`.

## 4. Errors and copy
- A form shows its error inline (`p.error[role=alert]` under the form). A row action, or an answer that redraws the list, shows a toast.
- Toast text and empty states have no final full stop. Toasts are past tense for success («تم حذف المكان»), a reason for errors.
- Leave words, pinned in three places (panel `tests/leave-labels.test.mjs`, app `src/lib/leaveLabels.test.ts`, DB `supabase/tests/leave_labels_tests.sql`): سنوية، مرضية، اضطرارية، زواج، وضع، بدون راتب، خاصة.

## 5. Old → new token names
Generated from the migration scripts. Values that snapped to a step are listed with their new step.

### App — rename

| Old | New |
|---|---|
| `--bg` | `--color-bg` |
| `--surface` | `--color-surface` |
| `--sunken` | `--color-surface-sunken` |
| `--line` | `--color-border` |
| `--line-strong` | `--color-border-strong` |
| `--text` | `--color-text` |
| `--text-2` | `--color-text-muted` |
| `--faint` | `--color-text-faint` |
| `--ink` | `--color-accent` |
| `--ink-2` | `--color-accent-hover` |
| `--ink-fg` | `--color-accent-text` |
| `--ink-tint` | `--color-accent-tint` |
| `--focus` | `--color-focus` |
| `--in` | `--color-success` |
| `--in-hover` | `--color-success-hover` |
| `--in-text` | `--color-success-text` |
| `--in-tint` | `--color-success-tint` |
| `--in-wash` | `--color-success-wash` |
| `--in-glow` | `--color-success-glow` |
| `--in-ring` | `--color-success-ring` |
| `--out` | `--color-danger` |
| `--danger` | `--color-danger` |
| `--out-hover` | `--color-danger-hover` |
| `--out-text` | `--color-danger-text` |
| `--danger-text` | `--color-danger-text` |
| `--out-tint` | `--color-danger-tint` |
| `--danger-tint` | `--color-danger-tint` |
| `--out-tint-2` | `--color-danger-tint-strong` |
| `--danger-line` | `--color-danger-line` |
| `--sun` | `--color-warning` |
| `--on-sun` | `--color-on-warning` |
| `--warn` | `--color-warning-text` |
| `--warn-tint` | `--color-warning-tint` |
| `--warn-line` | `--color-warning-line` |
| `--disabled-fill` | `--color-disabled` |
| `--veil` | `--color-veil` |
| `--scrim` | `--color-scrim` |
| `--hero-bg` | `--hero-bg` |
| `--on-hero` | `--hero-text` |
| `--on-hero-2` | `--hero-text-muted` |
| `--on-hero-3` | `--hero-text-subtle` |
| `--hero-accent` | `--hero-accent` |
| `--hero-chip` | `--hero-chip` |
| `--hero-track` | `--hero-track` |
| `--punch-out` | `--punch-out-bg` |
| `--punch-out-hover` | `--punch-out-bg-hover` |
| `--select-arrow` | `--field-select-arrow` |
| `--shadow-in` | `--punch-in-shadow` |
| `--shadow-out` | `--punch-out-shadow` |
| `--shadow-hero` | `--hero-shadow` |
| `--shadow-fab` | `--fab-shadow` |
| `--shadow-card` | `--shadow-card` |
| `--shadow-lift` | `--shadow-lift` |
| `--shadow-soft` | `--shadow-soft` |
| `--shadow-pop` | `--shadow-pop` |
| `--shadow-modal` | `--shadow-modal` |
| `--font-body` | `--font-family-body` |
| `--font-display` | `--font-family-display` |
| `--fs-caption` | `--font-size-xs` |
| `--fs-small` | `--font-size-sm` |
| `--fs-body` | `--font-size-md` |
| `--fs-title` | `--font-size-lg` |
| `--fs-headline` | `--font-size-xl` |
| `--fs-display` | `--font-size-2xl` |
| `--fs-time` | `--time-size` |
| `--fs-clock` | `--clock-size` |
| `--s1` | `--space-1` |
| `--s2` | `--space-2` |
| `--s3` | `--space-3` |
| `--s4` | `--space-4` |
| `--s5` | `--space-5` |
| `--s6` | `--space-6` |
| `--s8` | `--space-8` |
| `--gutter` | `--layout-gutter` |
| `--r-sm` | `--radius-sm` |
| `--r-md` | `--radius-md` |
| `--r-lg` | `--radius-lg` |
| `--r-xl` | `--radius-xl` |
| `--h-control` | `--size-control` |
| `--h-small` | `--size-control-sm` |
| `--h-appbar` | `--size-appbar` |
| `--h-tabbar` | `--size-tabbar` |
| `--h-float` | `--size-float` |
| `--wheel-row` | `--wheel-row` |

### Panel — rename

| Old | New |
|---|---|
| `--primary-tint` | `--color-accent-tint` |
| `--primary-2` | `--color-accent-hover` |
| `--bg` | `--color-bg` |
| `--surface-2` | `--color-surface-sunken` |
| `--surface` | `--color-surface` |
| `--text` | `--color-text` |
| `--muted` | `--color-text-muted` |
| `--border-strong` | `--color-border-strong` |
| `--border` | `--color-border` |
| `--success-tint` | `--color-success-tint` |
| `--success-text` | `--color-success-text` |
| `--success` | `--color-success` |
| `--warning` | `--color-warning` |
| `--warn-tint` | `--color-warning-tint` |
| `--warn-text` | `--color-warning-text` |
| `--error` | `--color-danger` |
| `--bad-tint` | `--color-danger-tint` |
| `--bad-text` | `--color-danger-text` |
| `--off-tint` | `--color-neutral-tint` |
| `--off-text` | `--color-neutral-text` |
| `--radius-sm` | `--radius-sm` |
| `--radius` | `--radius-lg` |
| `--s1` | `--space-1` |
| `--s2` | `--space-2` |
| `--s3` | `--space-3` |
| `--s4` | `--space-4` |
| `--s5` | `--space-6` |
| `--s6` | `--space-8` |
| `--control-h-sm` | `--size-control-sm` |
| `--control-h` | `--size-control` |
| `--page-max` | `--layout-max` |
| `--shadow` | `--shadow-card` |
| `--mw-xs` | `--measure-xs` |
| `--mw-sm` | `--measure-sm` |
| `--mw-md` | `--measure-md` |
| `--mw-lg` | `--measure-lg` |

### Panel — font

| Old | New |
|---|---|
| `.72rem` | `var(--font-size-2xs)` |
| `.78rem` | `var(--font-size-xs)` |
| `.82rem` | `var(--font-size-sm)` |
| `.84rem` | `var(--font-size-sm)` |
| `.88rem` | `var(--font-size-sm)` |
| `.9rem` | `var(--font-size-sm)` |
| `.92rem` | `var(--font-size-sm)` |
| `1rem` | `var(--font-size-md)` |
| `1.05rem` | `var(--font-size-md)` |
| `1.15rem` | `var(--font-size-lg)` |
| `1.2rem` | `var(--font-size-lg)` |
| `1.25rem` | `var(--font-size-lg)` |
| `1.4rem` | `var(--font-size-xl)` |
| `1.6rem` | `var(--font-size-2xl)` |
| `1.8rem` | `var(--font-size-2xl)` |
| `2rem` | `var(--font-size-2xl)` |

### Panel — radius

| Old | New |
|---|---|
| `999px` | `var(--radius-pill)` |
| `50%` | `var(--radius-round)` |
| `8px` | `var(--radius-sm)` |
| `10px` | `var(--radius-sm)` |

### Panel — space

| Old | New |
|---|---|
| `1px` | `var(--space-px)` |
| `2px` | `var(--space-0-5)` |
| `3px` | `var(--space-1)` |
| `4px` | `var(--space-1)` |
| `5px` | `var(--space-1)` |
| `6px` | `var(--space-1-5)` |
| `8px` | `var(--space-2)` |
| `10px` | `var(--space-2-5)` |
| `12px` | `var(--space-3)` |
| `14px` | `var(--space-3-5)` |
| `16px` | `var(--space-4)` |
| `18px` | `var(--space-4)` |
| `20px` | `var(--space-5)` |
| `52px` | `calc(var(--size-control) + var(--space-3))` |
