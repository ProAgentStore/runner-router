#!/usr/bin/env bash
# Billing-aware runs-on router. Public repos always get GitHub-hosted (free, unlimited
# minutes; self-hosted runners must never serve them). Private repos get GitHub-hosted
# while the org still has included Actions minutes, self-hosted once they are spent.
# Any error on a private repo -> self-hosted.
#
# Env in:   ROUTER_REPO_PRIVATE ("false" = public: no billing check, token never read),
#           ROUTER_ORG, ROUTER_BILLING_TOKEN, ROUTER_HOSTED_LABEL,
#           ROUTER_SELF_HOSTED_LABELS, ROUTER_INCLUDED_MINUTES, ROUTER_SAFETY_MARGIN
# Env out:  $GITHUB_OUTPUT gets runner=<JSON array> and reason=<text>
# Test env: ROUTER_FIXTURE_BODY (recorded API response), ROUTER_FIXTURE_STATUS (default 200)
set -uo pipefail

OUT="${GITHUB_OUTPUT:-/dev/stdout}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# "pags, self-hosted" -> ["pags","self-hosted"]. Pure bash so the fail-safe path needs no jq.
to_json_array() {
  set -f
  local IFS=',' label out=""
  for label in $1; do
    label="${label#"${label%%[![:space:]]*}"}"
    label="${label%"${label##*[![:space:]]}"}"
    [ -n "$label" ] && out+="\"$label\","
  done
  set +f
  printf '[%s]' "${out%,}"
}

case "${ROUTER_REPO_PRIVATE:-}" in
  false) VISIBILITY=public ;;
  true) VISIBILITY=private ;;
  *) VISIBILITY="unknown (billing-checked as private)" ;;
esac

emit() { # $1 = runner JSON array, $2 = reason
  echo "runner=$1" >> "$OUT"
  echo "reason=$2" >> "$OUT"
  echo "[runner-router] visibility=$VISIBILITY runs-on=$1 ($2)" >&2
  echo "- runner-router: visibility=$VISIBILITY, \`$1\`: $2" >> "$SUMMARY"
  exit 0
}

HOSTED_LABEL="${ROUTER_HOSTED_LABEL:-ubuntu-latest}"

# Public repo: hosted, always. Decided before the token is read and before any
# fail-safe, because every fail-safe path routes to self-hosted.
if [ "${ROUTER_REPO_PRIVATE:-}" = false ]; then
  PUBLIC_JSON=$(to_json_array "$HOSTED_LABEL")
  [ "$PUBLIC_JSON" = "[]" ] && PUBLIC_JSON='["ubuntu-latest"]'
  emit "$PUBLIC_JSON" "public repo: GitHub-hosted, no billing check"
fi

ORG="${ROUTER_ORG:-}"
TOKEN="${ROUTER_BILLING_TOKEN:-}"
SELF_LABELS="${ROUTER_SELF_HOSTED_LABELS:-self-hosted}"
INCLUDED="${ROUTER_INCLUDED_MINUTES:-2000}"
MARGIN="${ROUTER_SAFETY_MARGIN:-0}"

HOSTED_JSON=$(to_json_array "$HOSTED_LABEL")
SELF_JSON=$(to_json_array "$SELF_LABELS")
[ "$SELF_JSON" = "[]" ] && SELF_JSON='["self-hosted"]'

fail_safe() { emit "$SELF_JSON" "fail-safe: $1"; }

[ "$HOSTED_JSON" = "[]" ] && fail_safe "hosted-label is empty"
[[ "$INCLUDED" =~ ^[0-9]+$ ]] || fail_safe "included-minutes must be a whole number, got '$INCLUDED'"
[[ "$MARGIN" =~ ^[0-9]+$ ]] || fail_safe "safety-margin-minutes must be a whole number, got '$MARGIN'"
[[ "$ORG" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || fail_safe "invalid or empty org '$ORG'"
[ -n "$TOKEN" ] || fail_safe "no billing token; pass the billing-token secret"
command -v jq >/dev/null 2>&1 || fail_safe "jq is not installed on this runner"
command -v curl >/dev/null 2>&1 || fail_safe "curl is not installed on this runner"

# Current calendar-month usage (the API defaults to the current year and month).
BODY=$(mktemp) || fail_safe "mktemp failed"
trap 'rm -f "$BODY"' EXIT
if [ -n "${ROUTER_FIXTURE_BODY:-}" ]; then
  cp "$ROUTER_FIXTURE_BODY" "$BODY"
  STATUS="${ROUTER_FIXTURE_STATUS:-200}"
else
  STATUS=$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/organizations/$ORG/settings/billing/usage/summary?product=actions") || STATUS=000
fi
[ "$STATUS" = 200 ] || fail_safe "billing API returned HTTP $STATUS"

jq -e '.usageItems | type == "array"' "$BODY" >/dev/null 2>&1 || fail_safe "billing response has no usageItems array"
USED=$(jq -r '[.usageItems[] | select(((.product // "") | ascii_downcase) == "actions" and ((.unitType // "") | ascii_downcase) == "minutes") | (.grossQuantity // 0)] | add // 0' "$BODY") \
  || fail_safe "could not read minutes from billing response"
NET=$(jq -r '[.usageItems[] | select(((.product // "") | ascii_downcase) == "actions") | (.netAmount // 0)] | add // 0' "$BODY") \
  || fail_safe "could not read netAmount from billing response"

OVERAGE=$(jq -n --argjson n "$NET" '$n > 0') || fail_safe "could not compare netAmount"
EXHAUSTED=$(jq -n --argjson u "$USED" --argjson m "$MARGIN" --argjson i "$INCLUDED" '($u + $m) >= $i') \
  || fail_safe "could not compare minutes"

[ "$OVERAGE" = true ] && emit "$SELF_JSON" "overage: netAmount=$NET used=$USED included=$INCLUDED"
[ "$EXHAUSTED" = true ] && emit "$SELF_JSON" "included minutes spent: used=$USED margin=$MARGIN included=$INCLUDED"
emit "$HOSTED_JSON" "hosted: used=$USED of $INCLUDED included minutes"
