# runner-router

A reusable, billing-aware runner router for GitHub Actions. Jobs in **public** repos always run on GitHub-hosted runners. Jobs in **private** repos run on GitHub-hosted runners while the org still has included Actions minutes, and switch to your self-hosted runners once those minutes are spent or an overage is billed.

## The rules

- **Public repos always build on GitHub-hosted runners** (`hosted-label`, default `ubuntu-latest`). GitHub gives public repos unlimited free hosted minutes, so there is nothing to route. The router job itself runs hosted, no billing check is made, and the billing token is never read. A public repo must never use a self-hosted runner: anyone can open a pull request against it, and that would run their code on your machine.
- **Private repos go through the billing check.** Hosted while included minutes remain, self-hosted once they are spent, and self-hosted on any error.
- **No billing credential in any app repo.** Billing is checked once, centrally, by this repo's `publish-mode` workflow, which publishes each org's mode to [`mode.json`](mode.json). Private repos' routers read that file. The only credential is the billing GitHub App's key, a secret in this repo (see [Billing GitHub App](#billing-github-app)).
- **The self-hosted runner group stays private-only.** Leave *Allow public repositories* off. The router never sends a public repo there.

Only an explicit `github.event.repository.private == true` counts as private. If an event carries no repository payload, the router treats the repo as public and routes hosted, so a visibility it cannot read never lands on a self-hosted runner.

It ships as two entry points that share one script (`scripts/route.sh`):

- a **reusable workflow**: `.github/workflows/router.yml`
- a **composite action**: `action.yml`

Both output `runner`, a JSON array you pass to `runs-on` with `fromJSON`. Both work from any org. By default they check the owner of the calling repo, so the same setup works in `HeartFull-online`, `proappstore-online`, or your personal account.

## Policy and requirements

Owner decisions (platform#1329, runner-router#3). Change them here, not in callers.

- **Everything goes through the router.** Public repos always build on GitHub-hosted runners. Private repos use the org's included hosted minutes first, then self-hosted. The router must never need a self-hosted runner to start for a public repo.
- **Repos may be made public temporarily** for free hosted builds, when minutes run out or self-hosted runners are congested, and made private again later. Routing needs no change either way: visibility is read on every run, and no app repo holds a billing secret that would go public with it.
- **Scan before making a repo public.** Going public publishes the whole git history (including files deleted since), issues, pull requests and Actions logs. Bots harvest newly public repos within minutes, and making the repo private again does not undo what was copied. Before every flip, run `gitleaks git --redact` over the full history, rotate anything it finds (through `ops put`, tracked in serge-ivo/ops), and only then change the visibility.
- **One org per app is fine.** Billing is per org, and a new org needs only the billing App installed. Nothing changes in its repos.
- **Self-hosted runners serve private repos only** (the runner group's *Allow public repositories* stays off).

## Adopting it (ProAgentStore orgs and anyone else)

1. **Install the [billing GitHub App](#billing-github-app) on the org.** Within ten minutes the org appears in `mode.json`. Repos need no secret. Until then a private repo still runs, and routes to self-hosted.
2. **Have self-hosted runners for the overflow.** ProAgentStore's are the `pags` runners its CLI installs on an agent's pinned machine (`actions_runner_setup`). They carry the `self-hosted` and `pags` labels, which are this router's defaults.
3. **Keep the runners' group private-only.** A self-hosted runner group does not serve public repos by default. Leave it that way: the router routes public repos to hosted.
4. **Add a router job and route each job through it.** The snippet is the same for public and private repos:

```yaml
jobs:
  router:
    uses: ProAgentStore/runner-router/.github/workflows/router.yml@v1

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
1. **No `billing-token` (the normal case):** reads `mode.json` from `https://raw.githubusercontent.com/ProAgentStore/runner-router/main/mode.json` and routes the org `hosted` or `self-hosted` as published. It fails safe to self-hosted if the file can't be read, its `checked_on` date is more than a day old, or the org isn't listed. The steps below are what `publish-mode` runs for each org, and what the router runs itself when a caller does pass a token.
2. Reads the current calendar-month Actions usage from the billing API: `GET /organizations/{org}/settings/billing/usage/summary?product=actions`.
3. Sums `grossQuantity` for Actions **Minutes** items. This is minutes consumed, including the part covered by the plan.
4. Routes to **self-hosted** if either:
   - `netAmount` for Actions is greater than 0 (a billed overage), or
   - `used + safety-margin-minutes >= included-minutes`.
5. Otherwise routes to **hosted** (`hosted-label`, default `ubuntu-latest`, pinnable — see below).
6. **Fails safe to self-hosted** on any error: non-200 response, unexpected JSON, missing `jq`/`curl`, or invalid input.

Every decision is logged in the router job's log and step summary as one line with the repo's visibility, the minutes used and included (private repos), and the chosen runner:

```
[runner-router] visibility=public runs-on=["ubuntu-latest"] (public repo: GitHub-hosted, no billing check)
[runner-router] visibility=private runs-on=["ubuntu-latest"] (hosted: published mode for proappstore-online, checked 2026-11-16)
[runner-router] visibility=private runs-on=["ubuntu-latest"] (hosted: used=120 of 2000 included minutes)
[runner-router] visibility=private runs-on=["self-hosted","pags"] (included minutes spent: used=1850 margin=200 included=2000)
[runner-router] visibility=private runs-on=["self-hosted","pags"] (fail-safe: no billing token, and HeartFull-online is not in the published mode)
```

The text in parentheses is also the composite action's `reason` output.

## Pinning a GitHub-hosted OS version

GitHub moves `ubuntu-latest` (and `windows-latest`, `macos-latest`) to a new underlying image on
its own schedule. On 2026-10-21 it repointed `ubuntu-latest` from 24.04 to 26.04, which broke a
caller whose build depended on an exact 24.04 package. `hosted-label` defaults to `ubuntu-latest`,
but you can pin an exact image two ways:

1. **The `hosted-label` input**, set per call:

   ```yaml
   jobs:
     router:
       uses: ProAgentStore/runner-router/.github/workflows/router.yml@v1
       with:
         hosted-label: ubuntu-24.04
   ```

2. **A per-repo config file**, `.github/runner-router.json` in the calling repo, consulted only
   when the call site leaves `hosted-label` at its default — so you set the pin once instead of on
   every job that calls the router:

   ```json
   { "hosted-label": "ubuntu-24.04" }
   ```

   The router reads this file from the calling repo over the GitHub API using the job's own
   ambient token (no checkout, no extra secret); a missing file is normal, not an error.

An explicit `hosted-label` input always wins over the config file. A label the router does not
recognize — a typo, or an image GitHub has retired — falls back to `ubuntu-latest` rather than
queuing a job for a runner it can never get; the decision log names the unrecognized label and the
fallback. Recognized images: `ubuntu-latest`/`26.04`/`24.04`/`22.04`, `windows-latest`/`2025`/`2022`,
`macos-latest`/`15`/`14`/`13` (and the `-large`/`-xlarge` macOS variants). Self-hosted label routing
is unaffected either way.

## Requirements

- **On private repos the router job must run on a self-hosted runner.** Once hosted minutes are gone, hosted jobs are blocked, so a hosted router would stop the pipeline exactly when you need it to switch. Any self-hosted runner works, since every self-hosted runner has the `self-hosted` label. The reusable workflow does this for you (`router-label`) and runs the router job on `hosted-label` for public repos.
- The self-hosted runner needs `bash`, `curl`, and `jq`. Both entry points check for these and fall back to self-hosted if they are missing.
- The self-hosted runner needs network access to `raw.githubusercontent.com` to read `mode.json`.
- The repo's checkout of this router needs network access to `github.com` (the reusable workflow checks out this repo at the exact SHA of the workflow file being called).

### Billing GitHub App

`publish-mode` authenticates as one GitHub App, owned by `ProAgentStore`, and checks every org the App is installed on. One-time setup by the owner:

1. **Create the App** (ProAgentStore → Settings → Developer settings → GitHub Apps → New): no webhook, no callback URL, *Where can this app be installed*: **Any account**, permissions: **Organization → Administration: Read-only** and nothing else.
2. **Generate a private key** on the App's page.
3. **Store both as secrets on this repo** with `ops put` (never paste them anywhere else): `BILLING_APP_ID` (the App ID) and `BILLING_APP_PRIVATE_KEY` (the `.pem` contents). Track the change in serge-ivo/ops.
4. **Install the App** on each org whose private repos route through the router (*All repositories* is fine: the App reads billing only). Every new org: install it, nothing else.
5. Run `publish-mode` once by hand (Actions → publish-mode → Run workflow) and check that `mode.json` lists the org.

Each run asks for an installation token cut down to `organization_administration: read`, so a leaked run token can read billing and nothing more. GitHub's scheduled runs can start 10–30 minutes late under load, so the published mode can lag. `safety-margin-minutes` (100 in `publish-mode`) covers that.

### Passing a token directly (optional)

A caller can still pass `billing-token` (a repo-level secret), and the router then checks billing itself instead of reading `mode.json`. Nothing in ProAgentStore's orgs needs this. Never store such a token as an org secret: on the free plan public repos can read org secrets. The token must come from an **org administrator**.

- **Classic PAT:** `admin:org`. The endpoint accepts `admin:org` or `repo`, per the `X-Accepted-OAuth-Scopes` header. `admin:org` is the narrower choice.
- **Fine-grained PAT:** the billing usage docs do not name a fine-grained permission for this endpoint. If you use one, confirm it with a test call before relying on it.

Without a token a private repo's router still runs, but always routes to self-hosted. Public repos never read it.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `org` | calling repo owner | Org whose billing is checked |
| `billing-token` (secret, or input for the composite) | none | Optional. Private repos only: check billing directly instead of reading `mode.json`. Never read for public repos |
| `hosted-label` | `ubuntu-latest` | Label for GitHub-hosted runners. Pin an exact image (e.g. `ubuntu-24.04`); see [Pinning a GitHub-hosted OS version](#pinning-a-github-hosted-os-version) |
| `self-hosted-labels` | `self-hosted,pags` | Comma-separated labels for self-hosted runners |
| `included-minutes` | `2000` | With `billing-token` only. Minutes in your plan for the cycle (Free 2000, Team 3000, Enterprise 50000). The published mode uses `publish-mode`'s value |
| `safety-margin-minutes` | `0` | With `billing-token` only. Switch this many minutes early, to cover billing lag. The published mode uses `publish-mode`'s value (100) |
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
      self-hosted-labels: self-hosted,pags

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
          self-hosted-labels: self-hosted,pags

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
- `tests/route_test.sh`, an offline suite of 53 cases using recorded billing responses in `tests/fixtures/`, covering the public-repo rule, routing from the published `mode.json` (hosted, self-hosted, stale, unreadable, org missing, token precedence), hosted, exhausted, margin, overage, each fail-safe path, the decision log line, OS-version pinning (default, explicit, per-repo config, precedence, and an unrecognized image falling back), and the four acceptance-criteria tests for platform#1329,
- an end-to-end check of both entry points, asserting that this public repo routes to hosted.

The CI cannot test a live private-repo decision, because it is public. The offline suite covers that logic, and every `publish-mode` run exercises the billing check live.

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
