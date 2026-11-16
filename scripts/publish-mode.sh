#!/usr/bin/env bash
# Publishes each org's runner mode to mode.json (#3), so private repos can route without
# holding a billing token. Authenticates as the billing GitHub App, and for every org the
# App is installed on runs the same decision route.sh makes for a private repo.
# An org whose check fails is left out of the file, so its repos fail safe to
# self-hosted, and the script exits 1 so the run shows red.
#
# Env in:  BILLING_APP_ID, BILLING_APP_PRIVATE_KEY (PEM),
#          ROUTER_INCLUDED_MINUTES (default 2000), ROUTER_SAFETY_MARGIN (default 100),
#          MODE_FILE (default mode.json)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
: "${BILLING_APP_ID:?BILLING_APP_ID is not set (see README: Billing GitHub App)}"
: "${BILLING_APP_PRIVATE_KEY:?BILLING_APP_PRIVATE_KEY is not set (see README: Billing GitHub App)}"
MODE_FILE="${MODE_FILE:-mode.json}"
INCLUDED="${ROUTER_INCLUDED_MINUTES:-2000}"
MARGIN="${ROUTER_SAFETY_MARGIN:-100}"

api() {
  curl -fsS --max-time 30 -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

KEY=$(mktemp)
OUT=$(mktemp)
trap 'rm -f "$KEY" "$OUT"' EXIT
chmod 600 "$KEY"
printf '%s\n' "$BILLING_APP_PRIVATE_KEY" > "$KEY"

# App JWT (RS256), valid 10 minutes, backdated 60s for clock drift.
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$BILLING_APP_ID" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$KEY" | b64url)
JWT="$header.$payload.$signature"

installations=$(api -H "Authorization: Bearer $JWT" "https://api.github.com/app/installations?per_page=100")

orgs='{}'
failed=0
while read -r id login; do
  # Installation token cut down to the one permission the billing endpoint needs.
  token=$(api -X POST -H "Authorization: Bearer $JWT" \
    -d '{"permissions":{"organization_administration":"read"}}' \
    "https://api.github.com/app/installations/$id/access_tokens" | jq -r '.token // empty') || token=""
  if [ -z "$token" ]; then
    echo "::error::$login: could not get an installation token"
    failed=1
    continue
  fi
  echo "::add-mask::$token"

  : > "$OUT"
  env -i PATH="$PATH" GITHUB_OUTPUT="$OUT" ROUTER_REPO_PRIVATE=true ROUTER_ORG="$login" \
    ROUTER_BILLING_TOKEN="$token" ROUTER_HOSTED_LABEL=ubuntu-latest ROUTER_SELF_HOSTED_LABELS=self-hosted \
    ROUTER_INCLUDED_MINUTES="$INCLUDED" ROUTER_SAFETY_MARGIN="$MARGIN" \
    bash "$HERE/route.sh"
  reason=$(sed -n 's/^reason=//p' "$OUT")
  case "$reason" in
    fail-safe:*) echo "::error::$login: $reason"; failed=1; continue ;;
    hosted:*) mode=hosted ;;
    *) mode=self-hosted ;;
  esac
  orgs=$(jq -c --arg o "$login" --arg m "$mode" '. + {($o): $m}' <<< "$orgs")
done < <(jq -r '.[] | select(.account.type == "Organization") | "\(.id) \(.account.login)"' <<< "$installations")

jq -n --arg d "$(date -u +%F)" --argjson o "$orgs" '{checked_on: $d, orgs: $o}' > "$MODE_FILE"
cat "$MODE_FILE"
exit "$failed"
