# claude-action-runner

Ephemeral container that reviews a pull request with Claude when invoked by Forgejo Actions or GitHub Actions. Posts one structured summary comment on the PR with severity-bucketed findings (Critical / Warnings / Suggestions / Nits) and an `ai-review` commit status that can gate merge via branch protection.

Companion project: [fooelisa/ci-workflows](https://github.com/fooelisa/ci-workflows), which is the reusable-workflow layer that consumer repos actually reference.

## What it does (v2 state machine)

Dispatches on the event type:

- **`pull_request` opened / reopened / (v1-era PR without state marker) synchronize** → **full review** (LLM call): fetch diff → filter → prompt Claude → parse → upsert comment with state marker → post `success` or `failure` commit status.
- **`pull_request` synchronize (v2 PR with state marker)** → **never calls Claude**. Reads the state marker embedded in the existing bot comment:
  - `overridden` or `critical_count == 0` → carry-forward `success` on the new SHA
  - `critical_count > 0` + push touched a file listed in `critical_files` → **auto-address**: update state marker to overridden, append "auto-addressed" footer, post `success`
  - `critical_count > 0` + push touched nothing in `critical_files` → carry-forward `failure`
- **`issue_comment` `/review`** (PR author or write-collab) → full review
- **`issue_comment` `/override-ai-review`** (PR author or write-collab) → append override footer, mark overridden, post `success`
- Anything else → noop

Diff filtering (lockfiles, `dist/`, `build/`, `node_modules/`, `vendor/`, `*.min.*`, `*.generated.*`) happens before the model sees anything. Diffs >150K chars post a "diff too large" comment, skip the review, and post `success` (nothing meaningful to block on).

## Auth model

Uses an Anthropic API key, not the Claude Code CLI and not Pro/Max OAuth.

We tried the OAuth path first — Claude Code 2.1+ requires a TTY-attached interactive session for the OAuth login chain, and headless containers don't have TTYs. The `--bare` mode of the CLI explicitly expects `ANTHROPIC_API_KEY` too, so we skip the CLI entirely and talk to `api.anthropic.com/v1/messages` directly with curl. Smaller image, no CLI-version drift.

The reusable workflow injects the key as an env var; `review.sh` sends it in the `x-api-key` header. It never touches disk inside the container.

Rotate via [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) and re-set the `ANTHROPIC_API_KEY` secret on each opted-in repo.

**Forgejo-side auth for status posting**: the `REVIEWER_PAT` needs `write:repository` scope (Forgejo has no narrower "just statuses" scope). `claude-reviewer` must also be a Write collaborator on each opted-in repo. See [ci-workflows/README](https://github.com/fooelisa/ci-workflows#forgejo-hosted-repo) for the setup steps.

## Tuning the prompt

The system prompt lives in [`system-prompt.md`](system-prompt.md), baked into the image at `/etc/claude-review/system-prompt.md`. Edit + push → GHA rebuilds the image → consumers pick it up on next full review. Pin the reusable workflow to a specific `:<sha>` in [ci-workflows](https://github.com/fooelisa/ci-workflows) if you want deterministic behavior.

## Build

GHA builds on push to `main` and tags both `:main` (rolling) and `:<commit-sha>` (immutable). Multi-arch: `linux/arm64` (for the pik8s cluster's forgejo-runner) and `linux/amd64` (for github-hosted runners). `provenance: false` on the build-push-action to avoid GHCR attestation-manifest GC.

## Resource footprint

Called with a Docker memory limit of `512m` on Forgejo (see the reusable workflow's `container.options`). Typical usage: ~250 MiB. Peak on large diffs: ~500 MiB. OOM at the cap fails the workflow cleanly — no cluster impact.

## Cost

- Full review (opened / `/review`): ~$0.005–0.02 depending on diff size (Sonnet 4.6 pricing)
- **Any synchronize event: $0** — just API calls to fetch state and post status
- Manual override / auto-address: $0
