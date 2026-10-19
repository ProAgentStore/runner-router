# runner-router

A reusable, billing-aware runner router for GitHub Actions. Jobs run on GitHub-hosted runners while the org still has included Actions minutes, and switch to your self-hosted runners once those minutes are spent or an overage is billed.

It ships as two entry points that share one script (`scripts/route.sh`):

- a **reusable workflow**: `.github/workflows/router.yml`
- a **composite action**: `action.yml`

Both output `runner`, a JSON array you pass to `runs-on` with `fromJSON`. Both work from any org. By default they check the owner of the calling repo, so the same setup works in `HeartFull-online`, `proappstore-online`, or your personal account.

## How it decides

1. Reads the current calendar-month Actions usage from the billing API: `GET /organizations/{org}/settings/billing/usage/summary?product=actions`.
2. Sums `grossQuantity` for Actions **Minutes** items. This is minutes consumed, including the part covered by the plan.
3. Routes to **self-hosted** if either:
   - `netAmount` for Actions is greater than 0 (a billed overage), or
   - `used + safety-margin-minutes >= included-minutes`.
4. Otherwise routes to **hosted** (`hosted-label`, default `ubuntu-latest`).
5. **Fails safe to self-hosted** on any error: missing token, non-200 response, unexpected JSON, missing `jq`/`curl`, or invalid input. The reason is written to the job log, the step summary, and the `reason` output.

## Requirements

- **The router job must run on a self-hosted runner.** Once hosted minutes are gone, hosted jobs are blocked, so a hosted router would stop the pipeline exactly when you need it to switch. Any self-hosted runner works, since every self-hosted runner has the `self-hosted` label.
- The self-hosted runner needs `bash`, `curl`, and `jq`. Both entry points check for these and fall back to self-hosted if they are missing.
- The repo's checkout of this router needs network access to `github.com` (the reusable workflow checks out this repo at the exact SHA of the workflow file being called).

### Token and scopes

Store the token as an **org-level secret** (for example `ORG_BILLING_TOKEN`) and pass it as `billing-token`. The token must come from an **org administrator**.

- **Classic PAT:** `admin:org`. The endpoint accepts `admin:org` or `repo`, per the `X-Accepted-OAuth-Scopes` header. `admin:org` is the narrower choice.
- **Fine-grained PAT:** the billing usage docs do not name a fine-grained permission for this endpoint. If you use one, confirm it with a test call before relying on it.

Without a token the router still runs, but always routes to self-hosted.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `org` | calling repo owner | Org whose billing is checked |
| `billing-token` (secret, or input for the composite) | none | Token from above. Missing means fail-safe to self-hosted |
| `hosted-label` | `ubuntu-latest` | Label for GitHub-hosted runners |
| `self-hosted-labels` | `self-hosted,pags` | Comma-separated labels for self-hosted runners |
| `included-minutes` | `2000` | Minutes in your plan for the cycle. Set this to your plan's value (Free 2000, Team 3000, Enterprise 50000) |
| `safety-margin-minutes` | `0` | Switch this many minutes early, to cover billing lag |
| `router-label` (reusable only) | `self-hosted` | `runs-on` for the router job. Must be self-hosted |

The `pags` default label is ProAgentStore-specific. In other orgs, set `self-hosted-labels` to your own runner labels, or jobs will queue forever.

## Outputs

| Output | Reusable workflow | Composite action | Example |
| --- | --- | --- | --- |
| `runner` | `needs.<job>.outputs.runner` | `steps.<id>.outputs.runner` | `["ubuntu-latest"]` or `["self-hosted","pags"]` |
| `reason` | not exposed | `steps.<id>.outputs.reason` | `hosted: used=120 of 2000 included minutes` |

## Usage

### Reusable workflow

```yaml
jobs:
  route:
    uses: ProAgentStore/runner-router/.github/workflows/router.yml@v1
    with:
      included-minutes: 3000
      self-hosted-labels: self-hosted,pags
    secrets:
      billing-token: ${{ secrets.ORG_BILLING_TOKEN }}

  build:
    needs: route
    runs-on: ${{ fromJSON(needs.route.outputs.runner) }}
    steps:
      - uses: actions/checkout@v4
      - run: make build
```

### Composite action

The job that calls the action must itself run on self-hosted.

```yaml
jobs:
  route:
    runs-on: [self-hosted, pags]
    outputs:
      runner: ${{ steps.router.outputs.runner }}
    steps:
      - id: router
        uses: ProAgentStore/runner-router@v1
        with:
          included-minutes: 3000
          self-hosted-labels: self-hosted,pags
          billing-token: ${{ secrets.ORG_BILLING_TOKEN }}

  build:
    needs: route
    runs-on: ${{ fromJSON(needs.route.outputs.runner) }}
    steps:
      - uses: actions/checkout@v4
      - run: make build
```

A complete, manually triggered example is in [`.github/workflows/example.yml`](.github/workflows/example.yml).

## Self-test

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs:

- `shellcheck` on the scripts,
- `tests/route_test.sh`, an offline suite of 13 cases using recorded billing responses in `tests/fixtures/`, covering hosted, exhausted, margin, overage, and each fail-safe path,
- an end-to-end check of both entry points with no token, asserting they route to self-hosted.

The CI cannot test a live hosted decision, because it has no billing token. The offline suite covers that logic.

## Caveats

- Billing usage can lag behind real usage. Use `safety-margin-minutes` if you need headroom.
- Minutes are billed per calendar month (UTC), and the router reads only the current month.
- Usage is reported in billed minutes. Larger runners and macOS/Windows runners consume minutes at a multiplier, which the billing data already reflects.
- The billing usage endpoint is in public preview and may change.

## Credits

This project builds on prior art. The ideas below are credited; the code here was written independently.

- [shawnazar/overtime](https://github.com/shawnazar/overtime): billing-aware, hosted-first `runs-on` routing, the core idea of checking billing before choosing a runner.
- [hutch-fail/github-runner-then-fallback](https://github.com/hutch-fail/github-runner-then-fallback): a composite action that prefers GitHub-hosted runners while included minutes remain, then falls back.
- [mikehardy/runner-fallback-action](https://github.com/mikehardy/runner-fallback-action): choosing self-hosted runners based on whether they are available.
