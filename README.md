# claude-action-runner

Ephemeral container that reviews a pull request with Claude when invoked by Forgejo Actions or GitHub Actions. Posts one structured summary comment on the PR with severity-bucketed findings (Critical / Warnings / Suggestions / Nits).

Companion project: [fooelisa/ci-workflows](https://github.com/fooelisa/ci-workflows), which is the reusable-workflow layer that consumer repos actually reference.

## What it does

1. Fetches PR metadata + unified diff from the forge API (auto-detects Forgejo vs GitHub via `$GITHUB_API_URL`).
2. Filters noise files (lockfiles, generated, vendored, minified).
3. Skips out if the filtered diff is empty or > 150K chars — posts a "diff too large" comment and exits cleanly.
4. `POST`s to `https://api.anthropic.com/v1/messages` with the system prompt + user message (Cloudflare's `ARG_MAX` lesson doesn't apply since we're not passing anything on the command line).
5. Parses the model's JSON output → renders Markdown.
6. Upserts a single PR comment matched by the `<!-- claude-review:bot -->` HTML marker, so re-pushes update the same comment.

## Auth model

Uses an Anthropic API key, not the Claude Code CLI and not Pro/Max OAuth.

We tried the OAuth path first — Claude Code 2.1+ requires a TTY-attached interactive session for the OAuth login chain to work, and headless containers don't have TTYs. The `--bare` mode of the CLI explicitly expects `ANTHROPIC_API_KEY` too, so we skip the CLI entirely and talk to `api.anthropic.com/v1/messages` directly with curl. Smaller image, no CLI-version drift.

The reusable workflow injects the key as an env var; `review.sh` sends it in the `x-api-key` header. It never touches disk inside the container.

Rotate via [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) and re-set the `ANTHROPIC_API_KEY` org secret on each forge.

## Tuning the prompt

The system prompt lives in [`system-prompt.md`](system-prompt.md), baked into the image at `/etc/claude-review/system-prompt.md`. Edit and push; the next image build (tagged by commit SHA) will carry the new prompt. Pin the reusable workflow to a specific SHA in [ci-workflows](https://github.com/fooelisa/ci-workflows) to roll consumers forward.

## Build

GHA builds on push to `main` and tags both `:main` and `:<commit-sha>` (immutable). Multi-arch: `linux/arm64` (for the pik8s cluster's forgejo-runner) and `linux/amd64` (for github-hosted runners).

## Resource footprint

Called with a Docker memory limit of `512m` on Forgejo (see the reusable workflow's `container.options`). Typical usage: ~250 MiB. Peak on large diffs: ~500 MiB. OOM at the cap fails the workflow cleanly — no cluster impact.

<!-- next section starts here -->
