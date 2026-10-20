# runner-router

A reusable, billing-aware runner router for GitHub Actions. Jobs in **public** repos always run on GitHub-hosted runners. Jobs in **private** repos run on GitHub-hosted runners while the org still has included Actions minutes, and switch to your self-hosted runners once those minutes are spent or an overage is billed.

## The rules

- **Public repos always build on GitHub-hosted runners** (`hosted-label`, default `ubuntu-latest`). GitHub gives public repos unlimited free hosted minutes, so there is nothing to route. The router job itself runs hosted, no billing check is made, and the billing token is never read. A public repo must never use a self-hosted runner: anyone can open a pull request against it, and that would run their code on your machine.
- **Private repos go through the billing check.** Hosted while included minutes remain, self-hosted once they are spent, and self-hosted on any error.
- **No org-level secrets.** On GitHub's free plan an org secret is available to public repos too. The billing token is a **repo-level secret on each private repo only**.
- **The self-hosted runner group stays private-only.** Leave *Allow public repositories* off. The router never sends a public repo there.

Only an explicit `github.event.repository.private == true` counts as private. If an event carries no repository payload, the router treats the repo as public and routes hosted, so a visibility it cannot read never lands on a self-hosted runner.

It ships as two entry points that share one script (`scripts/route.sh`):

- a **reusable workflow**: `.github/workflows/router.yml`
- a **composite action**: `action.yml`

Both output `runner`, a JSON array you pass to `runs-on` with `fromJSON`. Both work from any org. By default they check the owner of the calling repo, so the same setup works in `HeartFull-online`, `proappstore-online`, or your personal account.

## Adopting it (ProAgentStore orgs and anyone else)

1. **On each private repo, create the repo-level secret `RUNNER_BILLING_TOKEN`**: a token from an org administrator that can read the org's Actions billing (scopes under [Token and scopes](#token-and-scopes)). Never make it an org secret. Public repos need no secret. Without it a private repo still runs, and always routes to self-hosted.
2. **Have self-hosted runners for the overflow.** ProAgentStore's are the `pags` runners its CLI installs on an agent's pinned machine (`actions_runner_setup`). They carry the `self-hosted` and `pags` labels, which are this router's defaults.
3. **Keep the runners' group private-only.** A self-hosted runner group does not serve public repos by default. Leave it that way: the router routes public repos to hosted.
4. **Add a router job and route each job through it.** The snippet is the same for public and private repos:

```yaml
jobs:
  router:
    uses: ProAgentStore/runner-router/.github/workflows/router.yml@v1
    with:
      included-minutes: 2000        # your plan's included Actions minutes
      safety-margin-minutes: 100    # switch a little early, to cover billing lag
    secrets:
      billing-token: ${{ secrets.RUNNER_BILLING_TOKEN }}

  build:
    needs: router
    runs-on: ${{ fromJSON(needs.router.outputs.runner) }}
    steps:
      - uses: actions/checkout@v4
      - run: make build
```

Every job that should fail over takes `needs: router` and `runs-on: ${{ fromJSON(needs.router.outputs.runner) }}`. Pin `@v1` (or a commit SHA); `v1` moves only for compatible fixes.

## How it decides

0. **Public repo:** routes to **hosted** and stops. Nothing below runs.
1. Reads the current calendar-month Actions usage from the billing API: `GET /organizations/{org}/settings/billing/usage/summary?product=actions`.
2. Sums `grossQuantity` for Actions **Minutes** items. This is minutes consumed, including the part covered by the plan.
3. Routes to **self-hosted** if either:
   - `netAmount` for Actions is greater than 0 (a billed overage), or
   - `used + safety-margin-minutes >= included-minutes`.
4. Otherwise routes to **hosted** (`hosted-label`, default `ubuntu-latest`).
5. **Fails safe to self-hosted** on any error: missing token, non-200 response, unexpected JSON, missing `jq`/`curl`, or invalid input. The reason is written to the job log, the step summary, and the `reason` output.

## Requirements

- **On private repos the router job must run on a self-hosted runner.** Once hosted minutes are gone, hosted jobs are blocked, so a hosted router would stop the pipeline exactly when you need it to switch. Any self-hosted runner works, since every self-hosted runner has the `self-hosted` label. The reusable workflow does this for you (`router-label`) and runs the router job on `hosted-label` for public repos.
- The self-hosted runner needs `bash`, `curl`, and `jq`. Both entry points check for these and fall back to self-hosted if they are missing.
- The repo's checkout of this router needs network access to `github.com` (the reusable workflow checks out this repo at the exact SHA of the workflow file being called).

### Token and scopes

Store the token as the **repo-level secret `RUNNER_BILLING_TOKEN`** on each private repo, and pass it as `billing-token`. Never store it as an org secret: on the free plan public repos can read org secrets. The token must come from an **org administrator**.

- **Classic PAT:** `admin:org`. The endpoint accepts `admin:org` or `repo`, per the `X-Accepted-OAuth-Scopes` header. `admin:org` is the narrower choice.
- **Fine-grained PAT:** the billing usage docs do not name a fine-grained permission for this endpoint. If you use one, confirm it with a test call before relying on it.

Without a token a private repo's router still runs, but always routes to self-hosted. Public repos never read it.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `org` | calling repo owner | Org whose billing is checked |
| `billing-token` (secret, or input for the composite) | none | Token from above, private repos only. Missing means fail-safe to self-hosted. Never read for public repos |
| `hosted-label` | `ubuntu-latest` | Label for GitHub-hosted runners |
| `self-hosted-labels` | `self-hosted,pags` | Comma-separated labels for self-hosted runners |
| `included-minutes` | `2000` | Minutes in your plan for the cycle. Set this to your plan's value (Free 2000, Team 3000, Enterprise 50000) |
| `safety-margin-minutes` | `0` | Switch this many minutes early, to cover billing lag |
| `router-label` (reusable only) | `self-hosted` | `runs-on` for the router job on private repos. Must be self-hosted. Public repos use `hosted-label` |

The `pags` default label is ProAgentStore-specific. In other orgs, set `self-hosted-labels` to your own runner labels, or jobs will queue forever.

## Outputs

| Output | Reusable workflow | Composite action | Example |
| --- | --- | --- | --- |
| `runner` | `needs.<job>.outputs.runner` | `steps.<id>.outputs.runner` | `["ubuntu-latest"]` or `["self-hosted","pags"]` |
| `reason` | not exposed | `steps.<id>.outputs.reason` | `hosted: used=120 of 2000 included minutes`, `public repo: GitHub-hosted, no billing check` |

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
      billing-token: ${{ secrets.RUNNER_BILLING_TOKEN }}

  build:
    needs: route
    runs-on: ${{ fromJSON(needs.route.outputs.runner) }}
    steps:
      - uses: actions/checkout@v4
      - run: make build
```

### Composite action

On a private repo, the job that calls the action must itself run on self-hosted. On a public repo it must not: run it on `ubuntu-latest`, and the action returns the hosted label.

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
          billing-token: ${{ secrets.RUNNER_BILLING_TOKEN }}

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
- `tests/route_test.sh`, an offline suite of 20 cases using recorded billing responses in `tests/fixtures/`, covering the public-repo rule, hosted, exhausted, margin, overage, and each fail-safe path,
- an end-to-end check of both entry points, asserting that this public repo routes to hosted.

The CI cannot test a live private-repo decision, because it is public and has no billing token. The offline suite covers that logic.

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
