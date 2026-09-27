#!/usr/bin/env bash
# Deploy the save-sync Worker and (re)apply its secrets from the repo's .env
# (0600, gitignored; the single local home of every secret). Safe to re-run.
#
# .env must contain: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID,
#   R2_SECRET_ACCESS_KEY, ALLOWED_EMAIL, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET,
#   CRYPT_PASSWORD, CRYPT_SALT
# The crypt key is NEVER generated here: a new key would make every existing
# cloud save unreadable. It's created once and kept in .env (+ your password manager).
set -euo pipefail
cd "$(dirname "$0")"
ENVF="../.env"
[ -f "$ENVF" ] || { echo "missing $ENVF"; exit 1; }
set -a; . "$ENVF"; set +a
for v in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY \
         ALLOWED_EMAIL CRYPT_PASSWORD CRYPT_SALT; do
  [ -n "${!v:-}" ] || { echo "missing $v in .env"; exit 1; }
done
W="npx --yes wrangler@4"
if grep -q REPLACE_ON_FIRST_DEPLOY wrangler.toml; then
  out="$($W kv namespace create SESSIONS 2>&1)" || { echo "$out"; exit 1; }
  id="$(printf '%s\n' "$out" | grep -oE '[0-9a-f]{32}' | head -1)"
  [ -n "$id" ] || { echo "$out"; echo "could not read KV id"; exit 1; }
  sed -i "s/REPLACE_ON_FIRST_DEPLOY/$id/" wrangler.toml
  echo "[✓] KV namespace SESSIONS = $id"
fi
$W deploy
# secrets: from .env via stdin, never on a command line
/usr/bin/python3 - <<'PY' | $W secret bulk
import json, os
keys = ["R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "ALLOWED_EMAIL", "CRYPT_PASSWORD", "CRYPT_SALT",
        "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET"]
out = {k: os.environ[k] for k in keys if os.environ.get(k)}
out["R2_ACCOUNT_ID"] = os.environ["CLOUDFLARE_ACCOUNT_ID"]
print(json.dumps(out))
PY
