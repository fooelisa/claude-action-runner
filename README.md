# claude-action-runner

Ephemeral container that reviews a pull request with Claude when invoked by Forgejo Actions or GitHub Actions. Posts one structured summary comment on the PR with severity-bucketed findings (Critical / Warnings / Suggestions / Nits).

Companion to [fooelisa/ci-workflows](https://github.com/fooelisa/ci-workflows), which is the reusable-workflow layer that consumer repos actually reference.

## What it does

1. Fetches PR metadata + unified diff from the forge API (auto-detects Forgejo vs GitHub via `$GITHUB_API_URL`).
2. Filters noise files (lockfiles, generated, vendored, minified).
3. Skips out if the filtered diff is empty or > 150K chars — posts a "diff too large" comment and exits cleanly.
4. Pipes the prompt into `claude -p --output-format json` via stdin (Cloudflare's `ARG_MAX` lesson).
5. Parses Claude's JSON output → renders Markdown.
6. Upserts a single PR comment matched by the `<!-- claude-review:bot -->` HTML marker, so re-pushes update the same comment.

## Auth model

Uses Claude Pro/Max OAuth (not a per-request Anthropic API key). The reusable workflow mounts the credentials as an env var; `review.sh` materializes them into `~/.claude/.credentials.json` at container start.

The tokens rotate roughly monthly. When a review starts failing with an auth error, refresh from the claude-workstation pod:

```
kubectl exec -n claude deploy/claude -- cat /home/claude/.claude/.credentials.json
```

Paste the output into the `ANTHROPIC_CREDENTIALS` org-level secret on each forge.

## Tuning the prompt

The system prompt lives in [`system-prompt.md`](system-prompt.md), baked into the image at `/etc/claude-review/system-prompt.md`. Edit and push; the next image build (tagged by commit SHA) will carry the new prompt. Pin the reusable workflow to a specific SHA in [ci-workflows](https://github.com/fooelisa/ci-workflows) to roll consumers forward.

## Build

GHA builds on push to `main` and tags both `:main` and `:<commit-sha>` (immutable). Multi-arch: `linux/arm64` (for the pik8s cluster's forgejo-runner) and `linux/amd64` (for github-hosted runners).

## Resource footprint

Called with a Docker memory limit of `512m` on Forgejo (see the reusable workflow's `container.options`). Typical usage: ~250 MiB. Peak on large diffs: ~500 MiB. OOM at the cap fails the workflow cleanly — no cluster impact.
