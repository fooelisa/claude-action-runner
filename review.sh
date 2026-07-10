#!/usr/bin/env bash
# review.sh — invoked by the reusable workflow inside a fresh container per PR.
# Fetches the PR diff, sends it to the Anthropic Messages API, upserts a
# summary comment on the PR.
#
# Forge-agnostic: dispatches on $GITHUB_API_URL (populated by both GitHub
# Actions and Forgejo Actions from the server's ROOT_URL). Same script works
# on both.
#
# Required env vars (set by the reusable workflow):
#   GITHUB_TOKEN         forge PAT with write:issue
#   ANTHROPIC_API_KEY    from console.anthropic.com
#   GITHUB_REPOSITORY    owner/repo
#   GITHUB_API_URL       e.g. https://forgejo.motmot-carp.ts.net/api/v1
#                             or https://api.github.com
#   PR_NUMBER            PR / MR number
#
# Optional:
#   ANTHROPIC_MODEL      defaults to claude-sonnet-4-6
#   MAX_TOKENS           defaults to 4096

set -euo pipefail

MAX_DIFF_CHARS=150000                             # ~40k tokens; drop-loud above this
COMMENT_MARKER='<!-- claude-review:bot -->'       # upsert key
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-4-6}"
MAX_TOKENS="${MAX_TOKENS:-4096}"

# ---------- 0. sanity ----------
: "${GITHUB_TOKEN:?required}"
: "${ANTHROPIC_API_KEY:?required}"
: "${GITHUB_REPOSITORY:?required}"
: "${GITHUB_API_URL:?required}"
: "${PR_NUMBER:?required}"

# Forge detection. GitHub's api base is api.github.com; anything else is
# assumed Forgejo/Gitea-compatible. Only affects the diff-fetching endpoint;
# the comments endpoint is identical.
case "$GITHUB_API_URL" in
  https://api.github.com*) FORGE=github ;;
  *)                       FORGE=forgejo ;;
esac
echo "::group::setup"
echo "forge=$FORGE  repo=$GITHUB_REPOSITORY  pr=$PR_NUMBER  model=$ANTHROPIC_MODEL"
echo "::endgroup::"

# ---------- 1. fetch PR metadata ----------
api() {
  # $1 = path (starts with /), $2..$N = extra curl args
  local path="$1"; shift
  curl -sSf \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/json" \
    "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY$path" "$@"
}

pr_json=$(api "/pulls/$PR_NUMBER")
PR_TITLE=$(printf '%s' "$pr_json" | jq -r '.title // ""')
PR_BODY=$(printf '%s' "$pr_json" | jq -r '.body // ""')
HEAD_SHA=$(printf '%s' "$pr_json" | jq -r '.head.sha')
echo "pr title: $PR_TITLE"
echo "head sha: $HEAD_SHA"

# ---------- 2. fetch the diff ----------
case "$FORGE" in
  github)
    RAW_DIFF=$(curl -sSf \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3.diff" \
      "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER")
    ;;
  forgejo)
    RAW_DIFF=$(curl -sSf \
      -H "Authorization: token $GITHUB_TOKEN" \
      "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER.diff")
    ;;
esac

# ---------- 3. filter noise files ----------
FILTERED_DIFF=$(printf '%s\n' "$RAW_DIFF" | awk '
  BEGIN { keep=1 }
  /^diff --git / {
    keep = 1
    path = $NF; sub(/^b\//, "", path)
    if (path ~ /(^|\/)package-lock\.json$/) keep = 0
    if (path ~ /\.lock$/)                   keep = 0
    if (path ~ /-lock\.ya?ml$/)             keep = 0
    if (path ~ /(^|\/)(dist|build|node_modules|vendor)\//) keep = 0
    if (path ~ /\.min\.(js|css)$/)          keep = 0
    if (path ~ /\.generated\./)             keep = 0
  }
  keep { print }
')

DIFF_CHARS=${#FILTERED_DIFF}
echo "diff chars after filter: $DIFF_CHARS (cap $MAX_DIFF_CHARS)"

# ---------- 4. upsert helper (defined early — used by too-large exit path too) ----------
upsert_comment() {
  local body="$1"
  local marker_body
  marker_body=$(printf '%s\n\n%s' "$COMMENT_MARKER" "$body")

  local existing_id
  existing_id=$(api "/issues/$PR_NUMBER/comments" \
    | jq --arg m "$COMMENT_MARKER" '[.[] | select(.body | contains($m))][0].id // empty')

  local payload
  payload=$(jq -n --arg b "$marker_body" '{body: $b}')

  if [ -n "$existing_id" ]; then
    echo "patching existing comment $existing_id"
    curl -sSf -X PATCH \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY/issues/comments/$existing_id" > /dev/null
  else
    echo "posting new comment"
    curl -sSf -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" > /dev/null
  fi
}

if [ "$DIFF_CHARS" -gt "$MAX_DIFF_CHARS" ]; then
  upsert_comment "_Diff too large for AI review (${DIFF_CHARS} chars > ${MAX_DIFF_CHARS} cap after filtering)._"
  echo "diff too large — posted skip comment, exiting 0"
  exit 0
fi

if [ "$DIFF_CHARS" -eq 0 ]; then
  upsert_comment "_No reviewable changes after filtering (lockfiles / generated / vendored files skipped)._"
  echo "empty diff after filter — posted skip comment, exiting 0"
  exit 0
fi

# ---------- 5. build the prompt ----------
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-/etc/claude-review/system-prompt.md}"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
  echo "ERROR: system prompt file not found at $SYSTEM_PROMPT_FILE" >&2
  exit 1
fi

SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")
USER_MESSAGE=$(cat <<EOF
<pr-title>${PR_TITLE}</pr-title>
<pr-description>
${PR_BODY}
</pr-description>
<diff>
${FILTERED_DIFF}
</diff>
EOF
)

# Build request body with jq so escaping is correct — the system prompt and
# diff both contain quotes, newlines, and shell-hostile characters.
REQUEST_BODY=$(jq -n \
  --arg model "$ANTHROPIC_MODEL" \
  --argjson max_tokens "$MAX_TOKENS" \
  --arg system "$SYSTEM_PROMPT" \
  --arg user "$USER_MESSAGE" \
  '{
    model: $model,
    max_tokens: $max_tokens,
    system: $system,
    messages: [{role: "user", content: $user}]
  }')

# ---------- 6. call the Messages API ----------
# Heartbeat every 30s so the workflow log doesn't look hung (Cloudflare lesson).
(
  while sleep 30; do
    echo "…still waiting on anthropic ($(date -u +%H:%M:%SZ))"
  done
) &
HEARTBEAT_PID=$!
trap 'kill $HEARTBEAT_PID 2>/dev/null || true' EXIT

echo "::group::anthropic call"

API_RESPONSE=$(mktemp)
HTTP_STATUS=$(printf '%s' "$REQUEST_BODY" | curl -sS -o "$API_RESPONSE" -w '%{http_code}' \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  --data-binary @-)

echo "::endgroup::"

kill $HEARTBEAT_PID 2>/dev/null || true

if [ "$HTTP_STATUS" != "200" ]; then
  echo "ERROR: Anthropic API returned HTTP $HTTP_STATUS" >&2
  echo "--- response body ---" >&2
  cat "$API_RESPONSE" >&2
  rm -f "$API_RESPONSE"
  upsert_comment "_AI review failed: Anthropic API HTTP $HTTP_STATUS. See workflow logs._"
  exit 1
fi

MODEL_TEXT=$(jq -r '.content[0].text // ""' < "$API_RESPONSE")
STOP_REASON=$(jq -r '.stop_reason // ""' < "$API_RESPONSE")
INPUT_TOKENS=$(jq -r '.usage.input_tokens // 0' < "$API_RESPONSE")
OUTPUT_TOKENS=$(jq -r '.usage.output_tokens // 0' < "$API_RESPONSE")
rm -f "$API_RESPONSE"

echo "usage: input=$INPUT_TOKENS output=$OUTPUT_TOKENS stop=$STOP_REASON"

if [ -z "$MODEL_TEXT" ]; then
  echo "ERROR: Anthropic API returned no content" >&2
  upsert_comment "_AI review failed: model returned empty content (stop_reason=$STOP_REASON). See workflow logs._"
  exit 1
fi

# Strip common wrapping: ```json ... ``` fences, leading/trailing whitespace.
JSON_PAYLOAD=$(printf '%s' "$MODEL_TEXT" \
  | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//' \
  | jq -c '.' 2>/dev/null || true)

if [ -z "$JSON_PAYLOAD" ]; then
  echo "ERROR: model output was not parseable JSON" >&2
  echo "--- raw model text (first 2000 chars) ---" >&2
  printf '%s' "$MODEL_TEXT" | head -c 2000 >&2
  upsert_comment "_AI review failed: model output did not parse as JSON. See workflow logs._"
  exit 1
fi

# ---------- 7. render markdown ----------
render_bucket() {
  local key="$1" emoji="$2" name="$3"
  local n
  n=$(printf '%s' "$JSON_PAYLOAD" | jq --arg k "$key" '.[$k] // [] | length')
  [ "$n" = "0" ] && return
  printf '\n**%s %s (%s)**\n' "$emoji" "$name" "$n"
  printf '%s' "$JSON_PAYLOAD" | jq -r --arg k "$key" '
    .[$k][] |
    if .line then "- `\(.file):\(.line)` — \(.body)"
    else       "- `\(.file)` — \(.body)"
    end'
}

SUMMARY=$(printf '%s' "$JSON_PAYLOAD" | jq -r '.summary // "(no summary)"')

BODY=$(cat <<EOF
### 🤖 Claude Review

**Summary**: ${SUMMARY}
$(render_bucket critical    "🔴" "Critical")
$(render_bucket warnings    "🟡" "Warnings")
$(render_bucket suggestions "🔵" "Suggestions")
$(render_bucket nits        "⚪" "Nits")

_Reviewed commit \`${HEAD_SHA:0:12}\` · model \`${ANTHROPIC_MODEL}\` · ${INPUT_TOKENS} in / ${OUTPUT_TOKENS} out tokens · re-runs on every push._
EOF
)

upsert_comment "$BODY"
echo "review posted"
