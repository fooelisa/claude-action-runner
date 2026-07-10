# syntax=docker/dockerfile:1.7
# claude-action-runner: ephemeral container invoked by Forgejo Actions /
# GitHub Actions to review pull requests via the Anthropic Messages API.
#
# No Claude Code CLI dep — talks to https://api.anthropic.com/v1/messages
# directly with curl. Smaller image (~50 MiB base vs ~250 MiB with Node),
# faster cold start, no CLI-version drift to track.
#
# Called with these env vars set by the reusable workflow:
#   GITHUB_TOKEN         forge PAT (write:issue scope)
#   ANTHROPIC_API_KEY    from console.anthropic.com
#   GITHUB_REPOSITORY    owner/repo (auto-populated by both forges)
#   GITHUB_API_URL       API base URL (auto-populated by both forges)
#   PR_NUMBER            set by the caller workflow from the pull_request event
#   ANTHROPIC_MODEL      (optional) defaults to claude-sonnet-4-6

# Multi-arch: linux/arm64 for the pik8s cluster's forgejo-runner, linux/amd64
# for github-hosted runners.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
    && rm -rf /var/lib/apt/lists/*

COPY review.sh /usr/local/bin/review.sh
RUN chmod +x /usr/local/bin/review.sh

# The prompt lives in its own file so it's tunable via a git diff to a
# single readable document rather than editing bash heredocs. Baked into
# the image so the workflow's image-SHA pin controls both code AND prompt
# behavior in one lever.
COPY system-prompt.md /etc/claude-review/system-prompt.md

ENTRYPOINT ["/usr/local/bin/review.sh"]
