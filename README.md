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

**The fan-out was applied on 2026-09-17 to all 29 repositories in
`fleet/repos.txt`** — 29 ok, 0 failed. A dry run now reports
`APP_PRIVATE_KEY=present APP_CLIENT_ID=present` on every line, and that is what
a rotation should look like before and after. Re-run it whenever the App key is
rotated or a repository is added to `fleet/repos.txt`.

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
| `scripts/apply-rulesets.sh` | Creates or updates a repository ruleset named `main` from `fleet/rulesets.json`: `~DEFAULT_BRANCH`, active, blocking deletion and force-pushes, requiring a pull request (zero approvals — a solo account cannot approve its own PR) and requiring the listed status checks with a strict up-to-date policy. A create grants no bypass; an update keeps the bypass the repository already has unless `--reset-bypass` says otherwise. An entry marked `"skip": true` is reported and left untouched. |
| `scripts/enable-immutable-releases.sh` | Turns on immutable releases through `PUT /repos/{owner}/{repo}/immutable-releases`, which makes a published tag impossible to move or delete — [HAR-NAME-003] enforced by the platform rather than by discipline. Repositories listed in `fleet/immutable-releases-exclude.txt` are reported as `SKIP` with their reason and never written to. |

`fleet/rulesets.json` maps `owner/name` to an entry with three possible keys:

| Key | Meaning |
|---|---|
| `checks` | required status-check contexts; `[]` for none |
| `skip` | `true` leaves the repository entirely alone |
| `note` | why — printed as the reason on the `SKIP` line |

An entry with `"checks": []` still gets the pull-request, deletion and
force-push rules. A context goes in only once all three of these hold:

1. the workflow makes it **unconditional** on a pull request — no `paths` or
   `paths-ignore` on the `pull_request` trigger, and no job-level `if:` that can
   skip the whole job on an ordinary pull request;
2. a check run with exactly that name has **already reported** on a recent pull
   request in that repository;
3. it is **green** there for reasons the pull request controls — never a context
   that is red for a pre-existing reason.

```bash
gh pr list --repo Misoto22/<repo> --state all --limit 3 --json headRefOid
gh api repos/Misoto22/<repo>/commits/<pr-head-sha>/check-runs \
  --jq '.check_runs[] | {name, app: .app.slug, conclusion}'
```

### What each repository requires

What the `main` ruleset requires on each repository, in `fleet/rulesets.json`
order. The rows are generated from that file, so it and this table cannot
disagree without the check below saying so. A repository under classic branch
protection has more gates than this column shows, as described after the table.

<!-- required-checks:begin -->
| Repository | `main` ruleset requires |
|---|---|
| `touchstone-hosted-probe` | `test`, `pr-title / pr-title` |
| `kioku-ios` | `Build`, `pr-title / pr-title` |
| `kioku` | none |
| `harness` | none |
| `touchstone` | none |
| `misoto22-site` | `pr-title / pr-title` |
| `folio` | skipped |
| `career-ops` | `pr-title / pr-title` |
| `skills` | skipped |
| `llm-gateway` | `check`, `pr-title / pr-title` |
| `kioku-ui` | `pr-title / pr-title` |
| `Shiplog` | none |
| `trading-research` | `verify`, `pr-title / pr-title` |
| `ai-investment-research-workflow` | `test` |
| `polymarket-edge-lab` | none |
| `misoto22-admin-ios` | none |
| `misoto22-admin` | `pr-title / pr-title` |
| `portrait-lora-pipeline` | `Core (ubuntu-latest)`, `Core (windows-latest)`, `body-and-verification`, `review-resolution`, `pr-title / pr-title` |
| `zhaojian` | `pr-title / pr-title` |
| `eoi-points-calculator` | `verify`, `deploy`, `pr-title / pr-title` |
| `cvtailors` | `rust`, `frontend`, `pr-title / pr-title` |
| `slatecourt` | `changes`, `pr-title / pr-title` |
| `servo-map` | `Typecheck`, `Lint`, `Test`, `Build Web` |
| `kairos` | `Backend (ruff + pytest)`, `Frontend (lint + vitest)`, `pr-title / pr-title` |
| `kaisetsu-pipeline` | `ci / python-ci` |
| `astra` | `frontend / node-ci` |
| `lumia-crystal-site` | `pr-title / pr-title` |
| `erp-modern` | none |
| `ci` | `actionlint`, `shellcheck`, `yamllint` |
<!-- required-checks:end -->

After editing `fleet/rulesets.json`, regenerate the rows and compare. The
command prints nothing when the table is current:

```bash
diff \
  <(jq -r 'to_entries[] | "| `\(.key | sub("^Misoto22/"; ""))` | \(
      if .value.skip then "skipped"
      elif (.value.checks | length) == 0 then "none"
      else (.value.checks | map("`" + . + "`") | join(", ")) end) |"' \
      fleet/rulesets.json) \
  <(sed -n '/^<!-- required-checks:begin -->$/,/^<!-- required-checks:end -->$/p' README.md |
    grep '^| `')
```

Every entry's `note` gives the reason for its row. The patterns behind them:

**Condition 2 and `pr-title / pr-title`.** A `pull_request_target` workflow runs
the definition from the **base** branch, so the pull request that adds the
caller never produces the context. It first appears on the next pull request
opened or updated after that merge. To get a first report without waiting, comment
`@dependabot rebase` on an older open Dependabot pull request: the rebase fires
`synchronize`, and that runs the caller from `main`. That is how `career-ops`
(#17) and `slatecourt` (#90) got their first report on 2026-09-18, and how
`skills` got one on #113, which Dependabot opened in place of #22.
`ai-investment-research-workflow`, `kaisetsu-pipeline` and `astra` had no open
pull request to rebase. They keep a `"pr-title not yet reported"` note, so a
later pass can add them without re-deriving the reason. `misoto22-admin-ios`,
`erp-modern` and this repository have no caller at all.

**Dependabot titles and condition 3.** `pr-title / pr-title` is green for
reasons the pull request controls, but a Dependabot title is written by
Dependabot's configuration, not by hand. On `Shiplog` it fails because
`.github/dependabot.yml` sets no `commit-message.prefix`, so the title has no
type ([Shiplog#6](https://github.com/Misoto22/Shiplog/pull/6) adds `chore`). On
`servo-map` it fails even with `prefix: chore`, because the prefix does not
decide the case. dependabot-core's `PrNamePrefixer` capitalises "Bump" when no
Dependabot commit is on the default branch and every recent Conventional Commit
message has `: ` followed by a capital somewhere in its full text. Every commit
there carries a `Co-Authored-By:` trailer, which satisfies that. Neither
repository requires the context until a Dependabot pull request passes it,
because requiring it earlier would block every Dependabot update. Retitling
one Dependabot pull request to lowercase before squash-merging it fixes the
case for good, since later titles copy the last Dependabot commit on `main`.

**Condition 1: `paths` and `paths-ignore`.** `misoto22-site`, `zhaojian` and
`Shiplog` keep their CI contexts out because each `ci.yml` declares
`paths-ignore` on `pull_request`. A docs-only pull request produces **no run at
all**, so a required context would sit pending forever and block a merge that
should have been trivial. The first two require `pr-title / pr-title` alone.
`rules`, from the harness-rendered `misoto-harness.yml`, is required nowhere:
since harness 0.4.0 its triggers are restricted to the paths the drift check
reads. `slatecourt` requires only `changes` from CI: `api`, `web` and `contract`
are gated on its path-filter outputs.

**Condition 3: red for a reason the pull request does not control.**
`lumia-crystal-site` requires only `pr-title / pr-title` although
`lint-and-build` is unconditional: the build reads two `NEXT_PUBLIC_SHOPIFY_*`
repository secrets, which a Dependabot run never receives, so it fails every
Dependabot pull request while passing an ordinary one. `career-ops` requires
only `pr-title / pr-title` for the same class of reason: its `test` job is red
on `main`, not on any one pull request.

**The `kioku-ui` exception.** `kioku-ui` requires `pr-title / pr-title` although
condition 2 is not met there: no pull request has been opened since its caller
landed in #28, and there was no Dependabot pull request to rebase. The fleet
orchestrator decided on 2026-09-18 to require it anyway. The caller is the same
`pr-title` job calling the same reusable workflow at the same pin as every
repository where the context renders as `pr-title / pr-title`. Review it at the
first `kioku-ui` pull request. If the context does not appear there under
exactly that name, drop it from `fleet/rulesets.json` and re-apply. This
ruleset also brings the script's strict up-to-date policy to a branch whose
classic protection has `strict: false`. Where rules overlap the most
restrictive wins, so a `kioku-ui` pull request now has to be up to date with
`main` before it merges.

`folio` and `skills` are `"skip": true`:

- **`folio`** already runs a ruleset named `main` with three required contexts
  and an admin bypass. The fleet default would be a downgrade, so folio's
  protection moves with its release-please migration instead.
- **`skills`** protects its default branch with its own ruleset, `Protect
  default branch`. A second ruleset named `main` beside it would be a duplicate
  gate on the same branch with nothing keeping the two in step. A context is
  added to that ruleset by hand: read it back, append the context and keep every
  other field, including `bypass_actors`, then PUT it. This script never writes
  it.

A ruleset is additive to any classic branch protection already in place; the
most restrictive rule wins. It never weakens an existing gate, but it does start
requiring a pull request where pushing to the default branch is the current
habit.

Updating an existing ruleset is a **full replace** — of the rules and of the
bypass list — and the script guards the two differently, because only one of
them can be noticed after the fact:

- **Required checks** that would be dropped are a fail-closed refusal: the
  repository is skipped and the lost contexts printed, unless
  `--allow-check-removal` says the removal is intended.
- **`bypass_actors`** get no such warning, because a bypass that disappears
  leaves nothing behind to compare against. So an update reads the repository's
  current actors back and sends them again verbatim; only a create writes the
  empty list. `--reset-bypass` is how to clear a bypass on purpose, and an
  `--apply` that carried actors over says so on its `OK` line.

Five repositories still use **classic** branch protection as their main gate:
`kioku`, `harness`, `touchstone`, `kioku-ui` and `polymarket-edge-lab`. Their
ruleset entries are `[]`, except `kioku-ui` (above), because the classic
protection already enforces their contexts. Each entry's `note` records what
that protection requires today. The two need reconciling before the ruleset is
treated as the only gate. A context is added to the classic protection with the
classic endpoint, not this script:

```bash
gh api repos/Misoto22/<repo>/branches/main/protection/required_status_checks \
  --jq '{strict, checks}' > before.json
# add the one context, keeping every existing entry and its app_id
gh api -X PATCH repos/Misoto22/<repo>/branches/main/protection/required_status_checks \
  --input after.json
```

`fleet/immutable-releases-exclude.txt` is the equivalent list for
`enable-immutable-releases.sh`: one `owner/name` per line with the reason after
a `#`, reported as `SKIP` and never written to. A repository belongs there when
one of its workflows attaches or replaces an asset on an **already-published**
release, which is exactly what immutable releases block. Two do today:

| Repository | Why |
|---|---|
| `career-ops` | `sbom.yml` runs on `release: published` and its whole job is a `gh release upload` back onto that release |
| `skills` | `release.yml` takes a `gh release upload --clobber` branch whenever a release for the tag already exists — a re-run, a re-dispatch, any retry |

The list is required rather than optional: a missing file is fatal, not an empty
exclusion, because losing it would turn the setting on for precisely the
repositories it breaks. `--exclude /dev/null` is the explicit way to exclude
nothing. Delete an entry once its workflow attaches assets at creation time
instead, which is the compatible shape.

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
It used to fail for want of a credential; since the fan-out on 2026-09-17 both
`APP_CLIENT_ID` and `APP_PRIVATE_KEY` exist here, so a failure in that job is
now a real one worth reading. It is a separate workflow and does not block `CI`
either way.

## License

MIT. See [LICENSE](LICENSE).
