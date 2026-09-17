# Misoto22/ci

Reusable GitHub Actions workflows, composite actions and fleet scripts shared by
every `Misoto22` project. YAML, shell and documentation only — **no secret ever
lives in this repository**.

## Why it is public

A public repository cannot call a reusable workflow that lives in a private one.
`folio`, `kioku-ui`, `skills`, `touchstone`, `servo-map` and
`eoi-points-calculator` are public, so the central CI repository has to be
public too. Nothing here is sensitive: credentials are delivered to each
consumer repository as repository secrets and variables, never referenced from
this repository's own settings.

## Pinning

Every third-party action in this repository is pinned to a full 40-character
commit SHA with a trailing `# vX.Y.Z` comment. Dependabot rewrites both the SHA
and the comment when they sit on the same line, which is why they always do.
Consumers should pin this repository the same way:

```yaml
uses: Misoto22/ci/.github/workflows/python-ci.yml@<40-char-sha> # v0.1.0
```

Resolve the SHA of a release tag with:

```bash
gh api repos/Misoto22/ci/git/ref/tags/v0.1.0 --jq '.object.sha'
```

A branch reference (`@main`) works but defeats the point; use it only while
developing a change here.

## Check names

GitHub renders a job that comes from a reusable workflow as
**`<caller job id> / <called job name>`**. There is no way to flatten it. So a
caller written as

```yaml
jobs:
  pr-title:
    uses: Misoto22/ci/.github/workflows/pr-title.yml@<sha> # v0.1.0
```

produces the status-check context **`pr-title / pr-title`**, and that whole
string — not a bare `pr-title` — is what belongs in a ruleset's
`required_status_checks`. The called job names in this repository are
`release-please`, `pr-title`, `python-ci`, `node-ci`, `swift-package-ci`,
`ghcr-retag` and `docker-publish`.

## Secrets contract

A personal GitHub account has **no account-level Actions secrets or variables**
(those exist only for organizations), and a called workflow only sees what the
caller passes it by name. So every consumer repository carries its own copy of:

| Name | Kind | Value |
|---|---|---|
| `APP_PRIVATE_KEY` | repository **secret** | full PEM of the `misoto22-release-bot` GitHub App private key |
| `APP_CLIENT_ID` | repository **variable** | the App's client ID (`Iv23li…`) |

`scripts/fanout-release-bot.sh` puts both on every repository in
`fleet/repos.txt`, reading them from 1Password
(`01 Personal Development` → `GitHub Release Bot App`). It is idempotent, so it
is also the key-rotation procedure.

The App itself is `misoto22-release-bot`, installed on the account with
**All repositories** so it covers repositories created later. Its permissions
are Metadata read, Contents read/write, Pull requests read/write and Issues
read/write — deliberately **not** Workflows, because a release PR must never be
able to edit `.github/workflows/`.

**Read the key from the `private_key_b64` field, never `private_key`.**
1Password re-wraps a multi-line password value in literal double quotes, so the
raw field does not round-trip to a PEM GitHub will accept: measured on
2026-09-17 it renders 1680 bytes against the PEM's 1678, and the two differ by
checksum. `private_key_b64` holds the same PEM base64-encoded on one line.
The fan-out script decodes it and refuses to write anything unless the result is
a `-----BEGIN … -----END` block with no stray quotes.

Never use `secrets: inherit`. Its behaviour on a personal account is
undocumented; pass secrets by name.

## Reusable workflows

### `release.yml` — release-please behind a GitHub App token

```yaml
name: Release

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  release:
    uses: Misoto22/ci/.github/workflows/release.yml@<sha> # v0.1.0
    permissions:
      contents: write
      pull-requests: write
      issues: write
    with:
      app-client-id: ${{ vars.APP_CLIENT_ID }}
      # config-file:   release-please-config.json     (default)
      # manifest-file: .release-please-manifest.json  (default)
      # target-branch: main                           (default)
    secrets:
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

Outputs: `release_created`, `releases_created`, `tag_name`, `version`, `major`,
`minor`, `patch`, `prs_created`, `paths_released`, `pr`.

**Why an App token and not `GITHUB_TOKEN`.** Tags, releases and commits created
with the default `GITHUB_TOKEN` deliberately trigger no further workflow runs.
A fleet whose publish steps hang off `on: release: published` — PyPI, npm, the
GHCR retag, TestFlight — would therefore silently never publish. A token minted
from the `misoto22-release-bot` App is a different identity, so the events it
raises do start downstream workflows. The token is minted per job, scoped to the
calling repository, valid for one hour and revoked in a post step.

**The tag guard.** The last step re-reads every `tag_name` the action emitted and
fails the job if the git ref does not exist. This is the defence against
[release-please#2898](https://github.com/googleapis/release-please/issues/2898):
under REST API version `2026-03-10` the pull-request payload no longer carries
`merge_commit_sha`, so release-please creates no tag and **still exits 0**. Never
set `X-GitHub-Api-Version` in a release job, and never read a green release job
as proof that a release happened.

### `pr-title.yml` — Conventional Commit PR titles

```yaml
name: PR title

on:
  pull_request_target:
    types: [opened, edited, synchronize, reopened, labeled, unlabeled]

permissions:
  pull-requests: read

jobs:
  pr-title:
    uses: Misoto22/ci/.github/workflows/pr-title.yml@<sha> # v0.1.0
```

Every repository squash-merges, so the PR title becomes the commit subject on
the default branch, and that subject is what release-please parses. `labeled` /
`unlabeled` are worth including: release-please labels its own release PR
`autorelease: pending` after opening it, and that label is what makes this check
skip it.

Resulting check: `pr-title / pr-title`.

### `python-ci.yml`

```yaml
jobs:
  ci:
    uses: Misoto22/ci/.github/workflows/python-ci.yml@<sha> # v0.1.0
    with:
      python-version: "3.13"          # default
      command: uv run pytest -q       # default
      working-directory: "."          # default
      runs-on: '["ubuntu-latest"]'    # JSON string, consumed with fromJSON
      enable-uv-cache: true           # false on a self-hosted runner
```

`runs-on` is a JSON string because a reusable workflow cannot take a list input.

`enable-uv-cache: false` is **mandatory** on a self-hosted runner: that machine
already keeps a warm `~/.cache/uv` between jobs, so `actions/cache` adds nothing
but a multi-gigabyte upload on every run, against a 10 GB per-repository quota
that it then evicts everything else out of.

Resulting check: `ci / python-ci`.

### `node-ci.yml`

```yaml
jobs:
  ci:
    uses: Misoto22/ci/.github/workflows/node-ci.yml@<sha> # v0.1.0
    with:
      command: pnpm run check         # default; override per repository
      node-version: "22"              # only used when there is no .nvmrc
      working-directory: "."
      runs-on: '["ubuntu-latest"]'
      enable-node-cache: true         # false on a self-hosted runner
```

The package manager is detected from the lockfile (`pnpm-lock.yaml` →
`pnpm install --frozen-lockfile`, `package-lock.json` → `npm ci`). The pnpm
version is not configured here: `pnpm/action-setup` reads the `packageManager`
field of the repository's own `package.json`. A committed `.nvmrc` always beats
the `node-version` input.

Resulting check: `ci / node-ci`.

### `swift-package-ci.yml`

```yaml
jobs:
  package:
    uses: Misoto22/ci/.github/workflows/swift-package-ci.yml@<sha> # v0.1.0
    with:
      package-path: Packages/Core     # default "."
```

Linux only, in a pinned `swift:6.3-noble` container. SwiftUI, UIKit, Combine,
CoreData and HealthKit do not exist on Linux, so only the pure-logic SwiftPM
package goes through here; anything importing those frameworks stays in the app
target and is tested on macOS. Splitting the logic out is what keeps macOS
minutes — ten times the price of Linux — off every pull request.

Resulting check: `package / swift-package-ci`.

### `ghcr-retag.yml`

```yaml
on:
  release:
    types: [published]

jobs:
  retag:
    uses: Misoto22/ci/.github/workflows/ghcr-retag.yml@<sha> # v0.1.0
    permissions:
      contents: read
      packages: write
    with:
      image: ghcr.io/misoto22/kioku
      source-tag: sha-${{ github.sha }}
      new-tags: |
        ${{ github.event.release.tag_name }}
```

Copies an existing manifest onto new tags with `docker buildx imagetools create`
— no rebuild, same digest, same attestation, multi-arch preserved. The point is
that a rollback can point `KIOKU_IMAGE_TAG` at `v1.2.3` instead of a commit hash.

### `docker-publish.yml`

```yaml
jobs:
  image:
    uses: Misoto22/ci/.github/workflows/docker-publish.yml@<sha> # v0.1.0
    permissions:
      contents: read
      packages: write
    with:
      image: ghcr.io/misoto22/example
      context: "."
      dockerfile: Dockerfile
      platforms: linux/amd64
      push: true
```

Deliberately minimal. Tags: `sha-<short>` always, semver on tag pushes, `latest`
on the default branch. Layer cache is `type=gha`. The services that already have
a bespoke build workflow keep theirs.

## Composite actions

For repositories that keep a bespoke workflow and only want the repeated setup
steps.

```yaml
- uses: Misoto22/ci/actions/setup-uv-cached@<sha> # v0.1.0
  with:
    python-version: "3.13"
    enable-cache: "false"     # on a self-hosted runner
    working-directory: "."
    install: "true"

- uses: Misoto22/ci/actions/setup-pnpm-cached@<sha> # v0.1.0
  with:
    node-version: "22"
    enable-cache: "false"     # on a self-hosted runner
```

Composite-action inputs are always strings, so the cache switch is `"true"` /
`"false"` rather than a boolean.

## Fleet release-please conventions

- **`changelog-type: default` everywhere.** The CHANGELOG entry, the release PR
  body and the GitHub Release body then come from one render and cannot drift.
  Do not mix in the `github` changelog type, which is a different, label-driven
  renderer.
- **`changelog-sections` lists only `feat`, `fix`, `perf`, `revert`, `docs`,
  `refactor`.** Never add `chore`, `ci`, `build`, `test` or `style` — not even
  with `"hidden": true`. Listing them makes release-please consider those commits
  for a version bump, and its default strategy falls through to a patch bump for
  any commit it considers, so a lone `chore` commit opens a release PR
  ([release-please#2638](https://github.com/googleapis/release-please/issues/2638),
  open).
- **Never pin `X-GitHub-Api-Version` in a release job** — see
  [#2898](https://github.com/googleapis/release-please/issues/2898) above.
- **Never judge a release by the job colour.** Check that the tag exists. The
  reusable `release.yml` does this for you.
- **`include-commit-authors` stays off.** `(@Misoto22)` after every line is noise
  on a solo fleet.

Copyable templates live in `fleet/`:

| File | `release-type` | For |
|---|---|---|
| `release-please-config.python.json` | `python` | uv projects (`pyproject.toml`) |
| `release-please-config.node.json` | `node` | `package.json` projects |
| `release-please-config.rust.json` | `rust` | Cargo crates and workspaces |
| `release-please-config.simple.json` | `simple` | anything else; pre-wired with an `extra-files` generic updater for `Config/Version.xcconfig`, the Swift/iOS pattern |

Each needs a sibling `.release-please-manifest.json` holding the current
version, e.g. `{ ".": "0.1.0" }`.

## Conventional Commit vocabulary

One list, used by branch names ([HAR-NAME-006]), commit subjects, PR titles and
changelog sections:

```
feat  fix  chore  docs  refactor  perf  test  ci  build  revert  style
```

Branches are `<type>(<scope>)/<short-kebab-topic>`, for example
`feat(app)/device-auth` or `fix(api)/rate-limit`. Subjects are imperative
English, lowercase first letter, and release tags are `vMAJOR.MINOR.PATCH` and
are never moved ([HAR-NAME-003]).

## Scripts

All three default to a dry run and take `--apply` to write.

| Script | What it does |
|---|---|
| `scripts/fanout-release-bot.sh` | Reads the App private key and client ID from 1Password and sets `APP_PRIVATE_KEY` / `APP_CLIENT_ID` on every repository in `fleet/repos.txt`. Idempotent, so it is also the rotation procedure. Values never touch disk, the terminal or an argument list. Each `op` call has a 20-second watchdog, because GNU `timeout` is not installed on the machine this runs from. |
| `scripts/apply-rulesets.sh` | Creates or updates a repository ruleset named `main` from `fleet/rulesets.json`: `~DEFAULT_BRANCH`, active, no bypass actors, blocking deletion and force-pushes, requiring a pull request (zero approvals — a solo account cannot approve its own PR) and requiring the listed status checks with a strict up-to-date policy. |
| `scripts/enable-immutable-releases.sh` | Turns on immutable releases through `PUT /repos/{owner}/{repo}/immutable-releases`, which makes a published tag impossible to move or delete — [HAR-NAME-003] enforced by the platform rather than by discipline. |

`fleet/rulesets.json` maps `owner/name` to `{ "checks": [...] }`. Seeded
conservatively: only check names verified to actually run and pass are listed,
everything else is `[]`, which still gets the pull-request, deletion and
force-push rules. Verify a repository's real check names before adding them:

```bash
gh api repos/Misoto22/<repo>/commits/<pr-head-sha>/check-runs --jq '.check_runs[].name'
```

A ruleset is additive to any classic branch protection already in place; the
most restrictive rule wins. It never weakens an existing gate, but it does start
requiring a pull request where pushing to the default branch is the current
habit.

Updating an existing ruleset is a full replace, so a repository whose `main`
ruleset already requires checks that `fleet/rulesets.json` does not list would
lose them. `apply-rulesets.sh` fails closed on that: it refuses the repository
and prints the contexts that would have gone, unless `--allow-check-removal`
says the removal is intended. `folio` is the repository this already matters
for — it is the only one with a ruleset named `main` today, and its three
contexts are carried in the seed for exactly this reason. `skills` has one named
`Protect default branch`, which this script leaves alone and adds a second,
`main`, beside.

Several repositories still use **classic** branch protection rather than a
ruleset (`kioku`, `harness`, `touchstone`, `kioku-ui`, `polymarket-edge-lab`).
Those contexts are seeded as `[]` here because the classic protection already
enforces them; reconcile the two before treating the ruleset as the only gate.

## This repository's own CI

`.github/workflows/ci.yml` runs actionlint (in the pinned `rhysd/actionlint`
container), shellcheck over `scripts/*.sh`, and yamllint. The same actionlint
image and tag is what to run locally before pushing:

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -color
shellcheck scripts/*.sh
uvx yamllint@1.38.0 --strict .
```

`.github/workflows/release-self.yml` calls this repository's own `release.yml`.
**It fails until the fan-out has run**, because `APP_CLIENT_ID` and
`APP_PRIVATE_KEY` do not exist here yet — which in turn waits on the
`misoto22-release-bot` GitHub App being created. That red job is expected and
does not block CI.

## License

MIT. See [LICENSE](LICENSE).
