#!/usr/bin/env bash
# Offline self-test for scripts/route.sh. Uses recorded billing responses, no network.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROUTE="$HERE/../scripts/route.sh"
FIX="$HERE/fixtures"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

# check <name> <expected runner JSON> <expected reason prefix> [VAR=value ...]
check() {
  local name=$1 want_runner=$2 want_reason=$3
  shift 3
  local out="$TMP/out.txt"
  : > "$out"
  env -i PATH="$PATH" GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY=/dev/null \
    ROUTER_ORG=ProAgentStore ROUTER_BILLING_TOKEN=test-token "$@" \
    bash "$ROUTE" >/dev/null 2>&1
  local got_runner got_reason
  got_runner=$(sed -n 's/^runner=//p' "$out")
  got_reason=$(sed -n 's/^reason=//p' "$out")
  if [ "$got_runner" = "$want_runner" ] && [[ "$got_reason" == "$want_reason"* ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: runner=[$got_runner] reason=[$got_reason]"
    fails=$((fails + 1))
  fi
}

HOSTED='["ubuntu-latest"]'
SELF='["self-hosted","pags"]'
SELF_ARGS=(ROUTER_SELF_HOSTED_LABELS="self-hosted,pags")

check "hosted while minutes remain" "$HOSTED" "hosted:" \
  "${SELF_ARGS[@]}" ROUTER_FIXTURE_BODY="$FIX/under-quota.json" ROUTER_INCLUDED_MINUTES=2000

check "self-hosted when included minutes spent" "$SELF" "included minutes spent" \
  "${SELF_ARGS[@]}" ROUTER_FIXTURE_BODY="$FIX/exhausted.json" ROUTER_INCLUDED_MINUTES=2000

check "safety margin triggers early switch" "$SELF" "included minutes spent" \
  "${SELF_ARGS[@]}" ROUTER_FIXTURE_BODY="$FIX/near-cap.json" ROUTER_INCLUDED_MINUTES=2000 ROUTER_SAFETY_MARGIN=200

check "netAmount > 0 is an overage signal" "$SELF" "overage" \
  "${SELF_ARGS[@]}" ROUTER_FIXTURE_BODY="$FIX/overage.json" ROUTER_INCLUDED_MINUTES=2000

check "API error fails safe to self-hosted" "$SELF" "fail-safe: billing API returned HTTP 403" \
  "${SELF_ARGS[@]}" ROUTER_FIXTURE_BODY="$FIX/under-quota.json" ROUTER_FIXTURE_STATUS=403

check "invalid token (401) fails safe to self-hosted" "$SELF" "fail-safe: billing API returned HTTP 401" \
  "${SELF_ARGS[@]}" ROUTER_BILLING_TOKEN=not-a-real-token ROUTER_FIXTURE_BODY="$FIX/under-quota.json" ROUTER_FIXTURE_STATUS=401

check "missing token fails safe" "$SELF" "fail-safe: no billing token" \
  "${SELF_ARGS[@]}" ROUTER_BILLING_TOKEN= ROUTER_FIXTURE_BODY="$FIX/under-quota.json"

check "non-JSON body fails safe" "$SELF" "fail-safe: billing response has no usageItems" \
  "${SELF_ARGS[@]}" ROUTER_FIXTURE_BODY="$FIX/not-json.txt"

check "missing usageItems fails safe" "$SELF" "fail-safe: billing response has no usageItems" \
  "${SELF_ARGS[@]}" ROUTER_FIXTURE_BODY="$FIX/no-usage-items.json"

check "non-numeric included-minutes fails safe" "$SELF" "fail-safe: included-minutes" \
  "${SELF_ARGS[@]}" ROUTER_FIXTURE_BODY="$FIX/under-quota.json" ROUTER_INCLUDED_MINUTES=abc

check "empty org fails safe" "$SELF" "fail-safe: invalid or empty org" \
  "${SELF_ARGS[@]}" ROUTER_ORG= ROUTER_FIXTURE_BODY="$FIX/under-quota.json"

check "custom labels are trimmed and JSON-encoded" '["pags","self-hosted"]' "fail-safe: no billing token" \
  ROUTER_SELF_HOSTED_LABELS=" pags, self-hosted " ROUTER_BILLING_TOKEN=

check "custom hosted label" '["ubuntu-24.04"]' "hosted:" \
  ROUTER_HOSTED_LABEL=ubuntu-24.04 ROUTER_FIXTURE_BODY="$FIX/under-quota.json"

if [ "$fails" -gt 0 ]; then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all tests passed"
