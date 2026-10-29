#!/usr/bin/env bash
# Builds the app for https://<user>.github.io/waqti-app/ and pushes the result to the gh-pages branch.
# Needs: .env with VITE_SUPABASE_URL and VITE_SUPABASE_KEY (publishable key only), git push access.
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE="${1:-origin}"
BASE_PATH="${BASE_PATH:-/waqti-app/}"

grep -q '^VITE_MOCK=1' .env 2>/dev/null && { echo "Refusing to deploy: VITE_MOCK=1 in .env"; exit 1; }
grep -qi 'service_role' .env 2>/dev/null && { echo "Refusing to deploy: service_role found in .env"; exit 1; }

npm test
BASE_PATH="$BASE_PATH" npm run build
touch dist/.nojekyll

TMP="$(mktemp -d)"
cp -r dist/. "$TMP"
cd "$TMP"
git init -q -b gh-pages
git add -A
git -c user.name="waqti-deploy" -c user.email="deploy@waqti.local" commit -qm "Deploy $(date -u +%Y-%m-%dT%H:%MZ)"
git push -f "$(cd - >/dev/null && git remote get-url "$REMOTE")" gh-pages
echo "Deployed. GitHub Pages: Settings -> Pages -> Branch: gh-pages / (root)"
