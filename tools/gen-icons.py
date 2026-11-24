# Generate src/components/Icon.tsx from Material Symbols (Apache-2.0) outlined SVG paths.
import re, sys, pathlib
SRC = pathlib.Path(sys.argv[1]); OUT = pathlib.Path(sys.argv[2])
MAP = {
  # names used by the app before the redesign (kept, so every call site still compiles)
  "back": "arrow_forward", "plus": "add", "signOut": "logout", "pin": "location_on", "check": "check_circle",
  "phone": "mobile", "alert": "error", "bell": "notifications", "close": "close", "calendar": "calendar_month",
  "clock": "schedule", "doc": "description", "arrive": "login", "leave": "logout", "contrast": "contrast",
  "user": "person", "eye": "visibility", "eyeOff": "visibility_off", "fingerprint": "fingerprint",
  # new in the redesign
  "home": "home", "homeFill": "home-fill", "assignment": "assignment", "assignmentFill": "assignment-fill",
  "bellActive": "notifications_active", "supervisor": "supervisor_account", "inbox": "inbox", "tree": "account_tree",
  "chevron": "chevron_left", "language": "language", "tick": "check", "info": "info", "warning": "warning", "badge": "badge", "work": "work",
  "overtime": "more_time", "event": "event", "pending": "pending_actions", "lock": "lock", "mail": "mail", "doneCircle": "check_circle",
}
rows = []
for key, name in MAP.items():
    svg = (SRC / f"{name}.svg").read_text()
    paths = re.findall(r'<path d="([^"]+)"', svg)
    assert paths, name
    rows.append(f'  {key}: "{" ".join(paths)}", // {name}')
OUT.write_text("""// Material Symbols Outlined, weight 400 (Apache-2.0, google/material-design-icons), generated from @material-symbols/svg-400 0.49.0.
// Filled shapes on a 960 grid, fill = currentColor. Regenerate with tools/gen-icons.py; do not edit the paths by hand.
const PATHS = {
""" + "\n".join(rows) + """
} as const;

export type IconName = keyof typeof PATHS;

export function Icon({ name, className }: { name: IconName; className?: string }) {
  return (
    <svg className={`icon${className ? ` ${className}` : ""}`} viewBox="0 -960 960 960" aria-hidden="true" focusable="false">
      <path d={PATHS[name]} />
    </svg>
  );
}
""")
print("icons:", len(rows))
