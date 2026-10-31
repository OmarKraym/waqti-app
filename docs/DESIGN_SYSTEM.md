# Employee app — design system (v2, 2026-10-31)

Omar asked for a full redesign: consistent sizes, comfortable spacing, "a design worthy of a global company".
Brand colour `#004357` and IBM Plex Sans Arabic stay (they are the company's identity and match the admin
panel and app icon). Everything else is new.

## What was wrong (audit of v1)

1. **No shared frame.** Today had a top bar; Requests and Notifications had a big title and no bar; the
   forms had a third layout. Each tab started at a different height.
2. **14 font sizes** (.75 → 1.75 rem) and **6 radii** (6, 9, 10, 12, 14, 16 px), added phase by phase.
3. **Spacing had no rhythm:** 6, 10, 12, 14, 16 px gaps mixed on the same screen.
4. Requests: section titles were body-size, so a long page had no landmarks. Approve/reject were small
   buttons pushed to one side.
5. Notifications: a whole card for one sentence; warnings written in red body text.
6. The time card used 180 px for two values stacked vertically.

## Tokens

### Colour

| Token | Hex | Use |
|---|---|---|
| `--brand` | `#004357` | primary actions, check-in, confirmed |
| `--brand-deep` | `#00303E` | pressed |
| `--brand-tint` | `#E3EFF2` | selected, approved chip, focus ring |
| `--copper` | `#9A4A0E` | check-out (the pair of the brand colour) |
| `--copper-tint` | `#FBEEE3` | |
| `--canvas` | `#F4F6F7` | page |
| `--surface` | `#FFFFFF` | groups and cards |
| `--line` | `#E2E8EB` | hairlines |
| `--line-strong` | `#C9D3D8` | input borders, dashed slots |
| `--text` | `#13242C` | |
| `--text-2` | `#56666E` | secondary text (5.9:1 on white) |
| `--danger` / tint | `#B42318` / `#FDECEA` | |
| `--warn` / tint | `#8A5300` / `#FFF3D6` | |

Check-in is always brand teal, check-out always copper: in the time card, the button and the history.

### Type (IBM Plex Sans Arabic, tabular figures for every time)

| Step | Size / line | Use |
|---|---|---|
| caption | 12 / 16 | tab labels, chips |
| small | 14 / 20 | secondary lines, hints |
| body | 16 / 24 | text, inputs, buttons |
| title | 18 / 26, 600 | section titles, card titles |
| headline | 22 / 30, 700 | app bar titles |
| display | 28 / 36, 700 | the Today status |
| time | 34 / 40, 700 | times in the time card |

### Space, size, shape

- Spacing on a 4 px grid: 4, 8, 12, 16, 20, 24, 32. Page gutter 20 px (16 px at 360 px and below).
- Between sections 32 px; between cards 12 px; card padding 16 px.
- Controls 48 px high (inputs, buttons), small buttons 40 px, the punch button 64 px.
- Radii by level: 20 hero card, 16 cards and groups, 12 controls, full round for chips and badges.
- No shadows. Surfaces are separated by hairlines and the canvas colour.

## Frame

Every screen starts with the same 60 px app bar: title at the start, one action at the end. Sub-screens
(new request, overtime assignment) put a back arrow before the title. The bottom tab bar is 64 px with a
pill behind the active icon.

```
┌──────────────────────────────┐
│ [▣] شركة تجريبية        [⎋] │  app bar (Today: company; other tabs: tab name + action)
│                              │
│ أحمد سالم · 1024             │  small
│ لم تسجّل حضورك اليوم          │  display
│ الساعة الآن 13:10:56          │  small
│ ┌ السبت 31 أكتوبر ──────────┐ │
│ │ حضور        │ انصراف       │ │  two slots side by side
│ │ 08:02       │ ـــ:ـــ      │ │  time 34 px
│ │ ✓ مؤكَّد      │              │ │
│ └───────────────────────────┘ │
│ [████ تسجيل الحضور ████]     │  64 px
│ ⌖ يُتحقق من موقعك…            │
│ الأيام السابقة                │  title
│ ┌───────────────────────────┐ │  one group, hairline rows
└──────────────────────────────┘
```

## Principles

1. **Same frame on every screen.** A tab never moves the title or the main action.
2. **Status before action.** On Today the status is the largest text.
3. **Confirmed is visible.** A time confirmed by the server is solid with "مؤكَّد"; a time saved on the
   phone is dashed with "لم يُرسل بعد". The stamp lands with one short animation (none with reduced motion).
4. **Action cards look different.** Things waiting for you (approve, overtime you were given) have a
   brand border; your own history has a hairline.
5. **Two colours mean in and out**, nothing else is coloured unless it is a state.
