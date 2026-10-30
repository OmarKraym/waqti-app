# Employee app — design review and proposal (2026-10-30)

## Brief (as understood)

- **Product:** وقتي, the employee time clock on the phone.
- **Audience:** sales-centre and warehouse staff of small Libyan companies. One hand, often outdoors,
  sometimes with a weak connection.
- **Primary job:** punch in or out in two seconds, and be **sure** it counted.
- **Fixed by Omar's brand:** colour `#004357`, IBM Plex Sans Arabic, RTL. The admin panel is not touched.

## What is wrong with the current screen

1. **Four identical white cards** (greeting, clock, punch, history) with the same radius and shadow.
   Nothing says what matters most.
2. **The biggest text is the clock** (2.6 rem). The phone already shows the time. The employee's real
   question, "am I checked in?", is a small 1 rem line.
3. **The greeting takes a whole card** ("مرحبًا" label + name).
4. **The 220 px round button** pushes the history below the fold on a 360 px phone.
5. **Trust is not visible.** "Confirmed by the server", "saved on the phone only" and "needs review"
   are all the same small chip. This is now the most important thing to show, because of offline mode.
6. **History is a flat list of events** with the full date repeated on every row. People think in
   days: when I came, when I left, how long.
7. Emoji 📍 in the policy line; messages pile up inside the punch card.

## Concept: the day's time card (بطاقة الدوام)

The paper time card is the object of this world. Times the **server has confirmed are stamped**, like
a punch clock's ink stamp. Times only **saved on the phone are written in pencil** (dashed, grey), and
they turn into a stamp when the server accepts them. The metaphor carries the app's real rule:
*nothing counts until it is stamped*. This is the one bold element; everything else stays quiet.

### Tokens

| Name | Hex | Use |
|---|---|---|
| Ink | `#004357` | brand; check-in stamp; check-in button |
| Rust ink | `#9A4A0E` | check-out stamp and button (AA on white) |
| Pencil | `#64748B` | not sent yet (dashed) |
| Paper | `#FFFFFF` | the time card only |
| Desk | `#EDF2F1` | page background (cool, from the brand teal — not cream) |
| Alert | `#B42318` | refused punches |

**Type:** IBM Plex Sans Arabic only. Scale 13 / 15 / 17 / 22 / 28. Times use tabular figures.
The status headline (22–26 px, bold) is the largest text. Stamped times are 28 px.

### Layout (RTL, right-aligned)

```
┌──────────────────────────────┐
│ ▣ الشركة الرئيسية        خروج │  top bar (unchanged)
├──────────────────────────────┤
│ أحمد سالم  1024               │  name, small
│ أنت حاضر منذ 08:02            │  STATUS — largest text
│ الساعة الآن 13:41             │  server time, small
│                              │
│ ┏ الخميس 30 أكتوبر ━━━━━━━━━━┓ │  THE TIME CARD (only bordered element)
│ ┃ حضور          ╔08:02╗      ┃ │  stamp (ink, slightly rotated)
│ ┃ ───────────────────────── ┃ │
│ ┃ انصراف        ┄┄┄┄┄        ┃ │  empty slot
│ ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛ │
│ [█████ تسجيل الانصراف █████]  │  full-width, 64 px, thumb zone
│ يجب أن تكون داخل نطاق العمل   │  policy, small
│                              │
│ الأيام السابقة                │
│ الأربعاء 29   08:01  16:03  8 س 02 د │  one row per day
│ الثلاثاء 28   07:58  16:10  8 س 12 د │
└──────────────────────────────┘
```

### Principles

1. **Status before action.** The first thing read is "am I checked in?".
2. **Stamped = counted.** Only server-confirmed times get the stamp. Pencil never looks final.
3. **One bordered object.** The time card is the only box; the rest sits on the desk with plain dividers.
4. **One motion:** the stamp lands (short scale-in) when the server confirms; nothing else animates.
   Reduced-motion users get no animation.

### Checked against the generic default

- First draft also stamped the history rows. Removed: the stamp must stay rare to keep its meaning.
- First draft kept a big clock. Removed: it is the generic "big number + small label" treatment, and
  the status headline is more useful.
- No card kit, no emoji, no middle-dot meta strings, no labels above every block. The card's only
  heading is the date, which is real information.
