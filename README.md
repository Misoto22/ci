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
      # auto-merge:    true                           (default)
    secrets:
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

Outputs: `release_created`, `releases_created`, `tag_name`, `version`, `major`,
`minor`, `patch`, `prs_created`, `paths_released`, `pr`, `auto_merge`,
`auto_merge_reason`.

**Why an App token and not `GITHUB_TOKEN`.** Tags, releases and commits created
with the default `GITHUB_TOKEN` deliberately trigger no further workflow runs.
A fleet whose publish steps hang off `on: release: published` — PyPI, npm, the
GHCR retag, TestFlight — would therefore silently never publish. A token minted
from the `misoto22-release-bot` App is a different identity, so the events it
raises do start downstream workflows. The token is minted per job, scoped to the
calling repository, valid for one hour and revoked in a post step.

**The tag guard.** The "Verify the tag exists" step re-reads every `tag_name`
the action emitted and fails the job if the git ref does not exist. This is the
defence against
[release-please#2898](https://github.com/googleapis/release-please/issues/2898):
under REST API version `2026-03-10` the pull-request payload no longer carries
`merge_commit_sha`, so release-please creates no tag and **still exits 0**. Never
set `X-GitHub-Api-Version` in a release job, and never read a green release job
as proof that a release happened.

#### Auto-merge of the release PR

The last step enables GitHub auto-merge on the bot's release PR, so it merges
itself once the target branch's required checks pass. It acts only when **all**
of these hold, each read live on every run:

1. **release-please opened or updated a release PR in this run**
   (`prs_created == 'true'`; the PR numbers come from the action's `prs`
   output).
2. **The repository allows auto-merge** (`allow_auto_merge` in
   `gh api repos/<owner>/<repo>`). This repository setting is the
   per-repository opt-in switch. `scripts/enable-auto-merge.sh` turns it on
   across the fleet; turning it off in a repository's settings opts that
   repository out without touching its workflow.
3. **The target branch requires at least one status check besides
   `pr-title / pr-title`**, counting both the active rulesets
   (`gh api repos/<r>/rules/branches/<branch>`, rule type
   `required_status_checks`) and classic branch protection. pr-title passes the
   moment the PR opens, so on a branch that requires nothing else a release PR
   would merge before any build ran.

When condition 2 or 3 does not hold, the step logs a `::notice::` saying which
one and exits 0. A run with no release PR, the common case, logs a plain line.
`auto-merge: false` on the caller opts out explicitly.

**Merge method.** `--squash` when the repository allows squash merges, else
`--merge` when it allows merge commits (`harness` allows only merge commits),
else `--rebase`, read from `allow_squash_merge`, `allow_merge_commit` and
`allow_rebase_merge`.

**Idempotent.** A PR that already has auto-merge on is left alone, and still
reports `enabled`. `gh pr merge --auto` merges on the spot rather than arming
auto-merge when the PR is already mergeable. Because a required check exists,
that happens only once every required check has passed, and the reason says
"merged at once".

**It deploys.** Merging a release PR is an ordinary merge to the default
branch, so it deploys wherever deploy-on-main is wired, exactly as a hand merge
of the same PR would. The merge is made by the App identity, not by
`GITHUB_TOKEN`, so the push it makes starts the follow-up release run that tags
the version.

**Classic protection and the App's permissions.** The classic endpoint
`repos/<r>/branches/<branch>/protection/required_status_checks` needs
Administration read. With the permission set listed under "Secrets contract"
it answers `403`. On any answer other than `404` (not protected), the step falls
back to the classic summary that `repos/<r>/branches/<branch>` returns, which
needs only Contents read. Only when both fail are the classic contexts treated
as unknown, and then the rulesets alone must show a real check. On 2026-09-18
both paths gave the same classic contexts for `kioku`, `harness` and
`touchstone` when tested with a token limited to exactly those permissions.

Outputs: `auto_merge` is `enabled`, `skipped` or `disabled`, and
`auto_merge_reason` is one line saying why. The step is `continue-on-error`,
because a convenience must never fail the job that publishing jobs `needs`.
Every decision it makes exits 0. A crash still shows as a failed step and
reads `skipped` with "the auto-merge step did not complete".

Callers pin this workflow by SHA, so a repository picks the step up when its
pin moves past the release that adds it.

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

Every repository except `harness` squash-merges. release-please parses the
commit subject that lands on the default branch, so the PR title only matters
if it becomes that subject. On GitHub's default settings it does not always
(see [the next section](#the-squash-subject-must-be-the-pr-title)). `labeled` /
`unlabeled` are worth including: release-please labels its own release PR
`autorelease: pending` after opening it, and that label is what makes this check
skip it.

Resulting check: `pr-title / pr-title`.

#### The squash subject must be the PR title

`pr-title / pr-title` validates the pull request's title. release-please parses
the commit subject that lands on the default branch. The two are the same only
when the repository's `squash_merge_commit_title` is `PR_TITLE`. GitHub's
default, `COMMIT_OR_PR_TITLE`, uses the PR title only for a pull request with
more than one commit. A single-commit pull request lands that commit's own
subject, which no check has read.

servo-map #20 shows the difference. Dependabot opened it as `chore: Bump the
actions group across 1 directory with 3 updates`. It was retitled to
`chore: bump …`, passed `pr-title / pr-title` and every other required check,
and landed as Dependabot's original commit subject:

```text
ef2f7d0 chore: Bump the actions group across 1 directory with 3 updates (#20)
```

That commit does more than put an unvalidated subject in front of
release-please. It also sets Dependabot's next title. dependabot-core's
`PrNamePrefixer#capitalize_first_word?` copies the case of the last Dependabot
commit on the default branch (see
[What each repository requires](#what-each-repository-requires)), so
servo-map's next Dependabot pull request comes out `chore: Bump …` and fails
the check again. With `PR_TITLE`, the title that passed the check is the
subject that lands. One lowercase Dependabot merge then sets the case for
every later Dependabot pull request.

`scripts/set-squash-merge-title.sh` sets `squash_merge_commit_title=PR_TITLE`
on every repository in `fleet/repos.txt` that allows squash merging.

- It keeps `squash_merge_commit_message` as it is: `COMMIT_MESSAGES` on every
  repository on 2026-09-18. The REST API needs the title whenever the message
  is sent, so the two always go together. `PR_TITLE` pairs with all three
  message values; the settings UI offers each of those pairs. If the API
  rejects a pair anyway, the script retries once with `COMMIT_MESSAGES` and
  says so on the line.
- A repository with squash merging off is reported as `SKIP` and never written
  to. That is `harness`, which merges with merge commits.
- Every write is confirmed by a fresh `GET`, not by the `PATCH`'s exit code.

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

All five default to a dry run and take `--apply` to write.

| Script | What it does |
|---|---|
| `scripts/fanout-release-bot.sh` | Reads the App private key and client ID from 1Password and sets `APP_PRIVATE_KEY` / `APP_CLIENT_ID` on every repository in `fleet/repos.txt`. Idempotent, so it is also the rotation procedure. Values never touch disk, the terminal or an argument list. Each `op` call has a 20-second watchdog, because GNU `timeout` is not installed on the machine this runs from. |
| `scripts/apply-rulesets.sh` | Creates or updates a repository ruleset named `main` from `fleet/rulesets.json`: `~DEFAULT_BRANCH`, active, blocking deletion and force-pushes, requiring a pull request (zero approvals — a solo account cannot approve its own PR) and requiring the listed status checks with a strict up-to-date policy. A create grants no bypass; an update keeps the bypass the repository already has unless `--reset-bypass` says otherwise. An entry marked `"skip": true` is reported and left untouched. |
| `scripts/enable-immutable-releases.sh` | Turns on immutable releases through `PUT /repos/{owner}/{repo}/immutable-releases`, which makes a published tag impossible to move or delete — [HAR-NAME-003] enforced by the platform rather than by discipline. Repositories listed in `fleet/immutable-releases-exclude.txt` are reported as `SKIP` with their reason and never written to. |
| `scripts/enable-auto-merge.sh` | Sets `allow_auto_merge=true` (`PATCH /repos/{owner}/{repo}`), the opt-in switch for [auto-merging release PRs](#auto-merge-of-the-release-pr), but only where the default branch requires a status check besides `pr-title / pr-title`. It uses the same check as the workflow step, in a function kept identical to the one in the step. A repository that fails the check, or is listed in `fleet/auto-merge-exclude.txt`, is reported as `SKIP` with the reason and never written to. It only turns the setting on, never off. |
| `scripts/set-squash-merge-title.sh` | Sets `squash_merge_commit_title=PR_TITLE` (`PATCH /repos/{owner}/{repo}`, sent with the repository's current `squash_merge_commit_message`) on every repository in `fleet/repos.txt` that allows squash merging. The validated PR title then becomes the squash subject, [even for a single-commit PR](#the-squash-subject-must-be-the-pr-title). A repository with squash merging off, or already on `PR_TITLE`, is reported as `SKIP`. Each write is confirmed by reading the repository back. |

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
| `kioku-ui` | none |
| `Shiplog` | `pr-title / pr-title` |
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
| `servo-map` | `Typecheck`, `Lint`, `Test`, `Build Web`, `pr-title / pr-title` |
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
`ai-investment-research-workflow`, `kaisetsu-pipeline`, `astra` and `kioku-ui`
had no open pull request to rebase. They keep a note saying pr-title has not
reported yet, so a later pass can add them without re-deriving the reason.
`misoto22-admin-ios`, `erp-modern` and this repository have no caller at all.

**Dependabot titles.** `pr-title / pr-title` checks a title that Dependabot
writes, so Dependabot's configuration decides whether its pull requests pass.
Two things decide it:

- **The type** comes from `commit-message.prefix` in `.github/dependabot.yml`.
  Without one the title is `Bump x from y to z`, which fails. That was
  `Shiplog` until [Shiplog#6](https://github.com/Misoto22/Shiplog/pull/6)
  added `chore`.
- **The case of "bump"** comes from dependabot-core's
  `PrNamePrefixer#capitalize_first_word?`, not from the prefix. It copies the
  last Dependabot commit on the default branch. When there is none, it
  capitalises when every recent Conventional Commit message has `: ` followed
  by a capital somewhere in its full text, and a `Co-Authored-By:` trailer is
  enough. That is why `servo-map` got `chore: Bump …` although it has
  `prefix: chore`.

So the first Dependabot commit to land on `main` sets the case for every later
title, and it has to land lowercase. Retitling the pull request is not enough.
Under the default `squash_merge_commit_title: COMMIT_OR_PR_TITLE`, a
single-commit squash takes Dependabot's commit subject, not the edited title.

- `Shiplog`'s #5 landed lowercase (`3714d54 chore: bump actions/checkout`), so
  its later titles should pass.
- `servo-map`'s #20 was retitled but landed as `ef2f7d0 chore: Bump the actions
  group …`. Its next Dependabot pull request will come out `chore: Bump …` and
  fail `pr-title / pr-title`. Fix that one pull request's title by hand.
  `scripts/set-squash-merge-title.sh` switched the repository's squash title
  to `PR_TITLE` on 2026-09-18
  ([why](#the-squash-subject-must-be-the-pr-title)), so the corrected title is
  what lands, and it sets the case lowercase for later titles.

**Condition 1: `paths` and `paths-ignore`.** `misoto22-site`, `zhaojian` and
`Shiplog` keep their CI contexts out because each `ci.yml` declares
`paths-ignore` on `pull_request`. A docs-only pull request produces **no run at
all**, so a required context would sit pending forever and block a merge that
should have been trivial. All three require `pr-title / pr-title` alone.
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
ruleset entries are `[]`, because the classic protection already enforces their
contexts. Each entry's `note` records what that protection requires today. The
two need reconciling before the ruleset is treated as the only gate. Listing a
context in the ruleset as well would not be neutral: this script always writes
a strict up-to-date policy, and the most restrictive rule wins. That would
override `kioku-ui`'s deliberate `strict: false`. A context is added to the
classic protection with the classic endpoint, not this script:

```bash
gh api repos/Misoto22/<repo>/branches/main/protection/required_status_checks \
  --jq '{strict, checks}' > before.json
# add the one context, keeping every existing entry and its app_id
gh api -X PATCH repos/Misoto22/<repo>/branches/main/protection/required_status_checks \
  --input after.json
```

The contexts sub-endpoint appends a single context and leaves `strict` and
every other entry alone:

```bash
gh api -X POST \
  repos/Misoto22/<repo>/branches/main/protection/required_status_checks/contexts \
  --input - <<<'{"contexts": ["pr-title / pr-title"]}'
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

`fleet/auto-merge-exclude.txt` works the same way for
`enable-auto-merge.sh`: one `owner/name` per line, with the reason after a
`#`. A missing file is fatal, and `--exclude /dev/null` excludes nothing. It
started empty. An entry keeps the script from turning auto-merge **on**. It
does not turn the setting off. To opt a repository out, switch
`allow_auto_merge` off in its settings (or pass `auto-merge: false` to the
reusable workflow), then list it here so the next run leaves it off.

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
