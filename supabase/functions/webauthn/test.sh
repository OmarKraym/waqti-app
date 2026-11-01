#!/usr/bin/env bash
# Runs core.test.mjs and index.test.mjs in Node 22 (no Deno needed).
# Installs @simplewebauthn/server@13.2.3 once into $WEBAUTHN_TEST_DIR (default: a folder next to this script,
# git-ignored), copies core.ts / index.ts there with the Deno-only imports swapped for Node ones, and runs both.
set -euo pipefail
F="$(cd "$(dirname "$0")" && pwd)"
T="${WEBAUTHN_TEST_DIR:-$F/.test-deps}"
mkdir -p "$T"
[ -d "$T/node_modules/@simplewebauthn/server" ] || (cd "$T" && npm init -y >/dev/null && npm i --no-audit --no-fund @simplewebauthn/server@13.2.3 >/dev/null)
sed 's#"./deps.ts"#"@simplewebauthn/server"#' "$F/core.ts" > "$T/core.ts"
sed 's#"npm:@supabase/supabase-js@2"#"./fake-supabase.mjs"#' "$F/index.ts" > "$T/index.ts"
cat > "$T/fake-supabase.mjs" <<'JS'
// Stand-in for npm:@supabase/supabase-js@2: routes rpc() to globalThis.__fake with the key's role.
export function createClient(_url, key, opts = {}) {
  const auth = opts.global?.headers?.Authorization ?? "";
  const role = key === "service" ? "service" : "user";
  return {
    auth: { getUser: async () => globalThis.__fake.getUser(auth), admin: { generateLink: async (a) => globalThis.__fake.generateLink(role, a) } },
    rpc: (fn, args) => globalThis.__fake.rpc(role, fn, args),
  };
}
JS
node --experimental-strip-types --no-warnings "$F/core.test.mjs" "$T/core.ts"
node --experimental-strip-types --no-warnings "$F/index.test.mjs" "$T"
