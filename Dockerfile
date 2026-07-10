# syntax=docker/dockerfile:1.7
# claude-action-runner: ephemeral container invoked by Forgejo Actions /
# GitHub Actions to review pull requests via the Claude CLI.
#
# Called with these env vars set by the reusable workflow:
#   GITHUB_TOKEN           forge PAT (write:issue scope)
#   ANTHROPIC_CREDENTIALS  contents of ~/.claude/.credentials.json
#   GITHUB_REPOSITORY      owner/repo (auto-populated by both forges)
#   GITHUB_API_URL         API base URL (auto-populated by both forges)
#   PR_NUMBER              set by the caller workflow from the pull_request event

# Multi-arch (linux/arm64 for the Pi cluster's forgejo-runner, linux/amd64 for
# github-hosted runners). Pinning to the tagged version rather than a digest
# because the multi-arch index digest changes on any per-arch security bump —
# gets in the way more than it helps for a short-lived reviewer image. Bump
# the tag deliberately in commit messages if you want reproducibility.
FROM node:22-bookworm-slim

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
    && rm -rf /var/lib/apt/lists/*

# Claude CLI — pinned by version so review behavior is stable across
# rebuilds. Bump alongside review.sh changes when Anthropic ships new CLI
# flags we want.
ARG CLAUDE_CLI_VERSION=2.1.197
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CLI_VERSION} \
    && npm cache clean --force

COPY review.sh /usr/local/bin/review.sh
RUN chmod +x /usr/local/bin/review.sh

# The prompt lives in its own file so it's tunable via a git diff to a
# single readable document rather than editing bash heredocs. Baked into
# the image so the workflow's image-SHA pin controls both code AND prompt
# behavior in one lever.
COPY system-prompt.md /etc/claude-review/system-prompt.md

# HOME must be writable — the claude CLI writes .credentials.json here at
# runtime from the ANTHROPIC_CREDENTIALS env var. The reusable workflow's
# job container runs as root inside DinD, so /root works fine.
ENV HOME=/root

ENTRYPOINT ["/usr/local/bin/review.sh"]
