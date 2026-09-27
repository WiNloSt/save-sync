#!/usr/bin/env bash
# Deploy the save-sync Worker. Needs ~/.config/save-sync/deploy.env (0600, never in git):
#   CLOUDFLARE_API_TOKEN=…   (save-sync-deploy: Workers Scripts Edit, Workers KV Edit, Account Settings Read)
#   CLOUDFLARE_ACCOUNT_ID=…
# Secrets are set separately (worker/set-secrets.sh) so a code deploy never touches them.
set -euo pipefail
cd "$(dirname "$0")"
ENVF="$HOME/.config/save-sync/deploy.env"
[ -f "$ENVF" ] || { echo "missing $ENVF"; exit 1; }
set -a; . "$ENVF"; set +a
W="npx --yes wrangler@4"
if grep -q REPLACE_ON_FIRST_DEPLOY wrangler.toml; then
  out="$($W kv namespace create SESSIONS 2>&1)" || { echo "$out"; exit 1; }
  id="$(printf '%s\n' "$out" | grep -oE '[0-9a-f]{32}' | head -1)"
  [ -n "$id" ] || { echo "$out"; echo "could not read KV id"; exit 1; }
  sed -i "s/REPLACE_ON_FIRST_DEPLOY/$id/" wrangler.toml
  echo "[✓] KV namespace SESSIONS = $id"
fi
$W deploy
