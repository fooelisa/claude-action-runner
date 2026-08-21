#!/usr/bin/env bash
# review.sh — invoked by the reusable workflow inside a fresh container per
# PR event. v2 introduces a state machine over synchronize/comment events
# so the LLM only runs on explicit review-requests, not every push.
#
# Modes:
#   full          — call Claude, upsert comment with fresh state marker, post status
#   synchronize   — never calls Claude; decides based on prior state marker:
#                     - overridden or clean       → carry-forward success
#                     - blocked + flagged file touched → auto-address (append footer, success)
#                     - blocked + nothing touched → carry-forward failure
#   override      — manual break-glass; append footer, mark state overridden, success
#   noop          — event we don't handle (e.g., comment without slash cmd)
#
# Forge-agnostic: dispatches on $GITHUB_API_URL. Works on both GitHub Actions
# and Forgejo Actions since Forgejo mirrors GHA's event names and API shapes.
#
# Required env vars (set by the reusable workflow):
#   GITHUB_TOKEN         forge PAT with write:issue + write:statuses
#   ANTHROPIC_API_KEY    from console.anthropic.com
#   GITHUB_REPOSITORY    owner/repo
#   GITHUB_API_URL       e.g. https://api.github.com  or  https://forgejo.motmot-carp.ts.net/api/v1
#   GITHUB_EVENT_NAME    e.g. pull_request, issue_comment
#   GITHUB_EVENT_PATH    JSON file with full event payload
#
# Optional:
#   ANTHROPIC_MODEL      defaults to claude-sonnet-4-6
#   MAX_TOKENS           defaults to 4096
#   BOT_LOGIN            username of the bot account posting comments;
#                        used to skip self-triggering. Defaults to
#                        claude-reviewer (Forgejo) or the workflow actor
#                        on GitHub.

set -euo pipefail

# --------------------------- config ---------------------------
MAX_DIFF_CHARS=150000
COMMENT_MARKER='<!-- claude-review:bot -->'
STATE_MARKER_PREFIX='<!-- claude-review:state '
STATE_MARKER_SUFFIX=' -->'
STATUS_CONTEXT='ai-review'
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-5}"
# Thinking shares this budget with the response text on models that think
# by default (Claude Sonnet 5 and later), so this is deliberately above what
# the review text alone needs. Only tokens actually generated are billed.
MAX_TOKENS="${MAX_TOKENS:-8192}"
BOT_LOGIN_DEFAULT_FORGEJO='claude-reviewer'

# --------------------------- env sanity ---------------------------
: "${GITHUB_TOKEN:?required}"
: "${ANTHROPIC_API_KEY:?required}"
: "${GITHUB_REPOSITORY:?required}"
: "${GITHUB_API_URL:?required}"
: "${GITHUB_EVENT_NAME:?required}"
: "${GITHUB_EVENT_PATH:?required}"

case "$GITHUB_API_URL" in
  https://api.github.com*) FORGE=github ;;
  *)                       FORGE=forgejo ;;
esac
BOT_LOGIN="${BOT_LOGIN:-$BOT_LOGIN_DEFAULT_FORGEJO}"

# --------------------------- helpers ---------------------------

# api METHOD PATH [extra curl args...]
# PATH begins with /repos/... — the base URL is prepended.
api() {
  local method="$1"; shift
  local path="$1"; shift
  curl -sSf -X "$method" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/json" \
    "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY$path" "$@"
}

# post_status SHA STATE DESCRIPTION
post_status() {
  local sha="$1" state="$2" desc="$3"
  local payload
  payload=$(jq -n --arg s "$state" --arg d "$desc" --arg c "$STATUS_CONTEXT" \
    '{state: $s, context: $c, description: $d}')
  printf '%s' "$payload" | curl -sSf -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY/statuses/$sha" > /dev/null
  echo "posted status: sha=${sha:0:8} state=$state desc=\"$desc\""
}

# fetch_existing_comment PR_NUM  — sets EXISTING_COMMENT_{ID,BODY} and STATE
# Picks the LATEST bot comment (highest created_at). Older bot comments
# are historical — a fresh `/review` posts a NEW comment rather than
# overwriting the previous one, so history accumulates over time. Only
# override + auto-address footers patch the latest comment in place.
fetch_existing_comment() {
  local pr_num="$1"
  local resp
  resp=$(api GET "/issues/$pr_num/comments")
  EXISTING_COMMENT=$(printf '%s' "$resp" | jq --arg m "$COMMENT_MARKER" '[.[] | select(.body | contains($m))] | sort_by(.created_at) | last // empty')
  if [ -n "$EXISTING_COMMENT" ] && [ "$EXISTING_COMMENT" != "null" ]; then
    EXISTING_COMMENT_ID=$(printf '%s' "$EXISTING_COMMENT" | jq -r '.id')
    EXISTING_COMMENT_BODY=$(printf '%s' "$EXISTING_COMMENT" | jq -r '.body')
    # Extract JSON between STATE_MARKER_PREFIX and STATE_MARKER_SUFFIX on one line.
    STATE=$(printf '%s\n' "$EXISTING_COMMENT_BODY" \
      | grep -oE "${STATE_MARKER_PREFIX}\{.*\}${STATE_MARKER_SUFFIX}" \
      | head -1 \
      | sed "s|^${STATE_MARKER_PREFIX}||; s|${STATE_MARKER_SUFFIX}\$||" || true)
  else
    EXISTING_COMMENT_ID=""
    EXISTING_COMMENT_BODY=""
    STATE=""
  fi
}

# check_permission USER PR_AUTHOR — returns 0 if authorized to run slash cmds
check_permission() {
  local user="$1" pr_author="$2"
  if [ "$user" = "$pr_author" ]; then return 0; fi
  local perm
  perm=$(api GET "/collaborators/$user/permission" 2>/dev/null | jq -r '.permission // "none"' || echo "none")
  case "$perm" in
    admin|maintain|write|push) return 0 ;;
    *) return 1 ;;
  esac
}

# get_changed_files BASE_SHA HEAD_SHA  — prints one filename per line
get_changed_files() {
  local base="$1" head="$2"
  case "$FORGE" in
    github)
      api GET "/compare/$base...$head" | jq -r '.files[]?.filename // empty' | sort -u
      ;;
    forgejo)
      # Forgejo's compare API returns .commits but not .files. Raw diff URL
      # (web root, not /api/v1) returns unified diff we can parse.
      local web_root diff_text
      web_root="${GITHUB_API_URL%/api/v1}"
      diff_text=$(curl -sSf -H "Authorization: token $GITHUB_TOKEN" \
        "${web_root}/${GITHUB_REPOSITORY}/compare/${base}...${head}.diff" 2>/dev/null || echo "")
      printf '%s\n' "$diff_text" | awk '/^diff --git / {
        path=$NF; sub(/^b\//, "", path); print path
      }' | sort -u
      ;;
  esac
}

# post_new_comment PR_NUM BODY  — always POSTs a fresh comment
# Used for initial review (opened/reopened), `/review` re-review, and
# skip-review outcomes. Prior bot comments stay untouched as history.
post_new_comment() {
  local pr_num="$1" body="$2"
  local payload
  payload=$(jq -n --arg b "$body" '{body: $b}')
  echo "posting new comment on PR $pr_num"
  printf '%s' "$payload" | curl -sSf -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY/issues/$pr_num/comments" > /dev/null
}

# patch_latest_comment PR_NUM BODY  — PATCHes the latest bot comment in place
# Used for auto-address + override footer appends. Requires that
# fetch_existing_comment has run and EXISTING_COMMENT_ID is set.
patch_latest_comment() {
  local pr_num="$1" body="$2"
  if [ -z "${EXISTING_COMMENT_ID:-}" ]; then
    fetch_existing_comment "$pr_num"
  fi
  if [ -z "${EXISTING_COMMENT_ID:-}" ]; then
    # Nothing to patch — this shouldn't happen in override/auto-address
    # flow since both branches guarded on STATE being present. Fall back
    # to POST rather than lose the comment.
    echo "warning: patch_latest_comment with no existing comment — posting instead"
    post_new_comment "$pr_num" "$body"
    return
  fi
  local payload
  payload=$(jq -n --arg b "$body" '{body: $b}')
  echo "patching comment id=$EXISTING_COMMENT_ID"
  printf '%s' "$payload" | curl -sSf -X PATCH \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${GITHUB_API_URL%/}/repos/$GITHUB_REPOSITORY/issues/comments/$EXISTING_COMMENT_ID" > /dev/null
}

# render_state_line NEW_STATE_JSON  — outputs the HTML state marker line
render_state_line() {
  local state_json="$1"
  printf '%s%s%s' "$STATE_MARKER_PREFIX" "$state_json" "$STATE_MARKER_SUFFIX"
}

# replace_state_marker BODY NEW_STATE_LINE  — swaps the state line in a body,
# or inserts it right after the COMMENT_MARKER line if missing.
replace_state_marker() {
  local body="$1" new_state_line="$2"
  # Escape for awk: pass via env, not command line.
  export NEW_STATE_LINE="$new_state_line"
  export COMMENT_MARKER_ENV="$COMMENT_MARKER"
  export STATE_MARKER_PREFIX_ENV="$STATE_MARKER_PREFIX"
  printf '%s' "$body" | awk '
    BEGIN {
      cm = ENVIRON["COMMENT_MARKER_ENV"]
      sp = ENVIRON["STATE_MARKER_PREFIX_ENV"]
      ns = ENVIRON["NEW_STATE_LINE"]
      replaced = 0
      cm_seen = 0
    }
    {
      if (index($0, sp) == 1) {
        # Line begins with the state marker prefix → replace
        print ns
        replaced = 1
        next
      }
      print
      if (index($0, cm) == 1 && !cm_seen) {
        cm_seen = 1
      }
    }
    END {
      if (!replaced && cm_seen) {
        # No existing state line, but we saw the comment marker → append at end
        # (Should be rare — every v2 comment writes both lines together)
      }
    }
  '
  unset NEW_STATE_LINE COMMENT_MARKER_ENV STATE_MARKER_PREFIX_ENV
}

# today_utc  — YYYY-MM-DD in UTC
today_utc() { date -u +%Y-%m-%d; }

# --------------------------- event dispatch ---------------------------
EVENT_PAYLOAD=$(cat "$GITHUB_EVENT_PATH")
EVENT_ACTION=$(printf '%s' "$EVENT_PAYLOAD" | jq -r '.action // ""')
PR_NUMBER=""
PR_AUTHOR=""
COMMENTER=""
COMMENT_BODY=""
MODE="noop"

echo "::group::setup"
echo "forge=$FORGE  event=$GITHUB_EVENT_NAME  action=$EVENT_ACTION  repo=$GITHUB_REPOSITORY"

case "$GITHUB_EVENT_NAME" in
  pull_request)
    PR_NUMBER=$(printf '%s' "$EVENT_PAYLOAD" | jq -r '.pull_request.number // ""')
    PR_AUTHOR=$(printf '%s' "$EVENT_PAYLOAD" | jq -r '.pull_request.user.login // ""')
    case "$EVENT_ACTION" in
      opened|reopened) MODE=full ;;
      synchronize)     MODE=synchronize ;;
      *) echo "ignoring pull_request action: $EVENT_ACTION"; echo "::endgroup::"; exit 0 ;;
    esac
    ;;

  issue_comment)
    IS_PR=$(printf '%s' "$EVENT_PAYLOAD" | jq -r '.issue.pull_request.url // ""')
    if [ -z "$IS_PR" ]; then
      echo "ignoring: comment on issue (not PR)"; echo "::endgroup::"; exit 0
    fi
    if [ "$EVENT_ACTION" != "created" ]; then
      echo "ignoring issue_comment action: $EVENT_ACTION"; echo "::endgroup::"; exit 0
    fi
    PR_NUMBER=$(printf '%s' "$EVENT_PAYLOAD" | jq -r '.issue.number')
    PR_AUTHOR=$(printf '%s' "$EVENT_PAYLOAD" | jq -r '.issue.user.login')
    COMMENTER=$(printf '%s' "$EVENT_PAYLOAD" | jq -r '.comment.user.login')
    COMMENT_BODY=$(printf '%s' "$EVENT_PAYLOAD" | jq -r '.comment.body // ""')

    # Skip our own comments (defense against feedback loop)
    if [ "$COMMENTER" = "$BOT_LOGIN" ] || printf '%s' "$COMMENT_BODY" | grep -qF "$COMMENT_MARKER"; then
      echo "ignoring: our own comment"; echo "::endgroup::"; exit 0
    fi

    if printf '%s' "$COMMENT_BODY" | grep -qE '^[[:space:]]*/review\b'; then
      MODE=full
    elif printf '%s' "$COMMENT_BODY" | grep -qE '^[[:space:]]*/override-ai-review\b'; then
      MODE=override
    else
      echo "ignoring: no slash command"; echo "::endgroup::"; exit 0
    fi

    if ! check_permission "$COMMENTER" "$PR_AUTHOR"; then
      echo "ignoring: $COMMENTER not authorized (must be PR author or write-collab)"
      echo "::endgroup::"; exit 0
    fi
    ;;

  *)
    echo "ignoring event: $GITHUB_EVENT_NAME"; echo "::endgroup::"; exit 0
    ;;
esac

echo "mode=$MODE  pr=$PR_NUMBER  author=$PR_AUTHOR  commenter=${COMMENTER:-n/a}"
echo "::endgroup::"

# --------------------------- fetch PR metadata ---------------------------
PR_JSON=$(api GET "/pulls/$PR_NUMBER")
CURRENT_HEAD_SHA=$(printf '%s' "$PR_JSON" | jq -r '.head.sha')
PR_TITLE=$(printf '%s' "$PR_JSON" | jq -r '.title // ""')
PR_BODY=$(printf '%s' "$PR_JSON" | jq -r '.body // ""')

fetch_existing_comment "$PR_NUMBER"

# --------------------------- mode: synchronize ---------------------------
if [ "$MODE" = "synchronize" ]; then
  if [ -z "$STATE" ]; then
    echo "synchronize: no prior state marker → falling through to full review"
    MODE=full
  else
    OVERRIDDEN=$(printf '%s' "$STATE" | jq -r '.overridden // false')
    CRITICAL_COUNT=$(printf '%s' "$STATE" | jq -r '.critical_count // 0')
    REVIEWED_SHA=$(printf '%s' "$STATE" | jq -r '.reviewed_sha // ""')

    if [ "$OVERRIDDEN" = "true" ]; then
      post_status "$CURRENT_HEAD_SHA" success "Overridden — carried forward"
      exit 0
    fi
    if [ "$CRITICAL_COUNT" = "0" ]; then
      post_status "$CURRENT_HEAD_SHA" success "Review OK — carried forward"
      exit 0
    fi
    # Blocked → check auto-address
    CRITICAL_FILES_JSON=$(printf '%s' "$STATE" | jq -c '.critical_files // []')
    CRITICAL_FILES=$(printf '%s' "$CRITICAL_FILES_JSON" | jq -r '.[]?' | sort -u)
    if [ -z "$CRITICAL_FILES" ] || [ -z "$REVIEWED_SHA" ]; then
      echo "synchronize: state marker missing critical_files or reviewed_sha → carry-forward failure"
      post_status "$CURRENT_HEAD_SHA" failure "${CRITICAL_COUNT} Critical finding(s) — resolve or /override-ai-review"
      exit 0
    fi

    echo "synchronize: reviewed_sha=$REVIEWED_SHA current=$CURRENT_HEAD_SHA"
    CHANGED_FILES=$(get_changed_files "$REVIEWED_SHA" "$CURRENT_HEAD_SHA" || true)
    echo "changed files since review:"
    printf '  %s\n' $CHANGED_FILES 2>/dev/null || true
    echo "critical files from last review:"
    printf '  %s\n' $CRITICAL_FILES 2>/dev/null || true

    TOUCHED=$(comm -12 <(printf '%s\n' "$CRITICAL_FILES") <(printf '%s\n' "$CHANGED_FILES") | grep -v '^$' || true)

    if [ -n "$TOUCHED" ]; then
      echo "auto-address: touched $(echo "$TOUCHED" | tr '\n' ',' | sed 's/,$//')"
      # Update state marker → overridden by auto-address
      NEW_STATE_JSON=$(printf '%s' "$STATE" | jq -c \
        --arg by "auto-addressed by push" \
        --arg sha "$CURRENT_HEAD_SHA" \
        '.overridden = true | .overridden_by = $by | .overridden_sha = $sha')
      NEW_STATE_LINE=$(render_state_line "$NEW_STATE_JSON")
      TOUCHED_CSV=$(echo "$TOUCHED" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
      NEW_BODY=$(replace_state_marker "$EXISTING_COMMENT_BODY" "$NEW_STATE_LINE")
      NEW_BODY="${NEW_BODY}"$'\n\n'"_✅ **Auto-addressed** by commit \`${CURRENT_HEAD_SHA:0:8}\` on $(today_utc) — touched: \`${TOUCHED_CSV}\`. Comment \`/review\` for a fresh look._"
      patch_latest_comment "$PR_NUMBER" "$NEW_BODY"
      post_status "$CURRENT_HEAD_SHA" success "Auto-addressed by push"
      exit 0
    else
      echo "no flagged files touched → carry-forward failure"
      post_status "$CURRENT_HEAD_SHA" failure "${CRITICAL_COUNT} Critical finding(s) — resolve or /override-ai-review"
      exit 0
    fi
  fi
fi

# --------------------------- mode: override ---------------------------
if [ "$MODE" = "override" ]; then
  if [ -z "$STATE" ]; then
    echo "override requested but no prior state → running full review instead"
    MODE=full
  else
    NEW_STATE_JSON=$(printf '%s' "$STATE" | jq -c \
      --arg by "@$COMMENTER" \
      --arg sha "$CURRENT_HEAD_SHA" \
      '.overridden = true | .overridden_by = $by | .overridden_sha = $sha')
    NEW_STATE_LINE=$(render_state_line "$NEW_STATE_JSON")
    NEW_BODY=$(replace_state_marker "$EXISTING_COMMENT_BODY" "$NEW_STATE_LINE")
    NEW_BODY="${NEW_BODY}"$'\n\n'"_✅ **Overridden by @${COMMENTER}** on $(today_utc) at commit \`${CURRENT_HEAD_SHA:0:8}\`._"
    patch_latest_comment "$PR_NUMBER" "$NEW_BODY"
    post_status "$CURRENT_HEAD_SHA" success "Overridden by @${COMMENTER}"
    exit 0
  fi
fi

# --------------------------- mode: full ---------------------------
# The rest is the v1 review flow, extended with state marker + status posting.

# Fetch full diff
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

# Filter noise
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

# skip_review REASON DESC — used for empty/too-large diffs
skip_review() {
  local reason="$1" desc="$2"
  local body="${COMMENT_MARKER}"$'\n'
  local state_line
  state_line=$(render_state_line "$(jq -cn --arg sha "$CURRENT_HEAD_SHA" \
    '{critical_count:0,critical_files:[],warnings:0,suggestions:0,nits:0,overridden:false,reviewed_sha:$sha}')")
  body="${body}${state_line}"$'\n\n'"### 🤖 Claude Review"$'\n\n'"$reason"$'\n\n'"_Skipped commit \`${CURRENT_HEAD_SHA:0:8}\`._"
  post_new_comment "$PR_NUMBER" "$body"
  post_status "$CURRENT_HEAD_SHA" success "$desc"
  exit 0
}

if [ "$DIFF_CHARS" -gt "$MAX_DIFF_CHARS" ]; then
  skip_review "_Diff too large for AI review (${DIFF_CHARS} chars > ${MAX_DIFF_CHARS} cap after filtering)._" \
              "Skipped — diff too large"
fi
if [ "$DIFF_CHARS" -eq 0 ]; then
  skip_review "_No reviewable changes after filtering (lockfiles / generated / vendored files skipped)._" \
              "Skipped — empty diff"
fi

# Build prompt
SYSTEM_PROMPT_FILE="${SYSTEM_PROMPT_FILE:-/etc/claude-review/system-prompt.md}"
if [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
  post_status "$CURRENT_HEAD_SHA" error "System prompt file missing — see logs"
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

# Heartbeat during Anthropic call
( while sleep 30; do echo "…still waiting on anthropic ($(date -u +%H:%M:%SZ))"; done ) &
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
  post_status "$CURRENT_HEAD_SHA" error "Anthropic API HTTP $HTTP_STATUS — see logs"
  rm -f "$API_RESPONSE"
  exit 1
fi

# Take the first text-typed block rather than content[0]. Models with thinking
# enabled return a thinking block first, and on Claude Sonnet 5 adaptive thinking
# is ON BY DEFAULT when the request omits the `thinking` parameter (Sonnet 4.6
# ran thinking-off). Its `display` also defaults to "omitted", so that leading
# block carries an EMPTY thinking string - which is why `.content[0].text` came
# back null and every review died as "empty content" the moment the default
# model moved to Sonnet 5. Selecting by type is model-agnostic and stays correct
# whichever block order a future model returns.
MODEL_TEXT=$(jq -r '[.content[]? | select(.type == "text") | .text] | add // ""' < "$API_RESPONSE")
STOP_REASON=$(jq -r '.stop_reason // ""' < "$API_RESPONSE")
INPUT_TOKENS=$(jq -r '.usage.input_tokens // 0' < "$API_RESPONSE")
OUTPUT_TOKENS=$(jq -r '.usage.output_tokens // 0' < "$API_RESPONSE")
if [ -z "$MODEL_TEXT" ]; then
  echo "--- content block types returned ---" >&2
  jq -r '[.content[]?.type] | join(", ")' < "$API_RESPONSE" >&2
fi
rm -f "$API_RESPONSE"
echo "usage: input=$INPUT_TOKENS output=$OUTPUT_TOKENS stop_reason=$STOP_REASON"

# max_tokens caps thinking AND response text together, so a long thinking pass
# can truncate the JSON payload mid-object. That surfaces downstream as an
# unparseable-JSON error, which reads like a prompt problem rather than a
# budget one - name it here instead.
if [ "$STOP_REASON" = "max_tokens" ]; then
  echo "WARNING: response hit max_tokens ($MAX_TOKENS); thinking and output share this budget, so the review may be truncated." >&2
fi

if [ -z "$MODEL_TEXT" ]; then
  post_status "$CURRENT_HEAD_SHA" error "Empty model response — see logs"
  echo "ERROR: Anthropic returned empty content" >&2
  exit 1
fi

# Strip common fences and parse
JSON_PAYLOAD=$(printf '%s' "$MODEL_TEXT" \
  | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//' \
  | jq -c '.' 2>/dev/null || true)

if [ -z "$JSON_PAYLOAD" ]; then
  post_status "$CURRENT_HEAD_SHA" error "Model output not JSON — see logs"
  echo "ERROR: model output was not parseable JSON:" >&2
  printf '%s' "$MODEL_TEXT" | head -c 2000 >&2
  exit 1
fi

# Extract counts + critical_files for the state marker
CRITICAL_COUNT=$(printf '%s' "$JSON_PAYLOAD" | jq -r '.critical // [] | length')
WARNINGS_COUNT=$(printf '%s' "$JSON_PAYLOAD" | jq -r '.warnings // [] | length')
SUGGESTIONS_COUNT=$(printf '%s' "$JSON_PAYLOAD" | jq -r '.suggestions // [] | length')
NITS_COUNT=$(printf '%s' "$JSON_PAYLOAD" | jq -r '.nits // [] | length')
CRITICAL_FILES_JSON=$(printf '%s' "$JSON_PAYLOAD" | jq -c '[.critical[]?.file] | unique')

NEW_STATE_JSON=$(jq -cn \
  --argjson cc "$CRITICAL_COUNT" \
  --argjson cf "$CRITICAL_FILES_JSON" \
  --argjson w  "$WARNINGS_COUNT" \
  --argjson s  "$SUGGESTIONS_COUNT" \
  --argjson n  "$NITS_COUNT" \
  --arg sha "$CURRENT_HEAD_SHA" \
  '{critical_count:$cc, critical_files:$cf, warnings:$w, suggestions:$s, nits:$n, overridden:false, reviewed_sha:$sha}')
NEW_STATE_LINE=$(render_state_line "$NEW_STATE_JSON")

# Render markdown
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

BLOCK_FOOTER=""
if [ "$CRITICAL_COUNT" -gt 0 ]; then
  BLOCK_FOOTER=$'\n\n'"_⛔ **Merge blocked**: ${CRITICAL_COUNT} Critical finding(s). Resolve them, or override with \`/override-ai-review\`._"
fi

NEW_BODY=$(cat <<EOF
${COMMENT_MARKER}
${NEW_STATE_LINE}
### 🤖 Claude Review

**Summary**: ${SUMMARY}
$(render_bucket critical    "🔴" "Critical")
$(render_bucket warnings    "🟡" "Warnings")
$(render_bucket suggestions "🔵" "Suggestions")
$(render_bucket nits        "⚪" "Nits")

_Reviewed commit \`${CURRENT_HEAD_SHA:0:8}\` · model \`${ANTHROPIC_MODEL}\` · ${INPUT_TOKENS} in / ${OUTPUT_TOKENS} out tokens._
_Re-review: comment \`/review\` · Override block: \`/override-ai-review\`_${BLOCK_FOOTER}
EOF
)

post_new_comment "$PR_NUMBER" "$NEW_BODY"

if [ "$CRITICAL_COUNT" -gt 0 ]; then
  post_status "$CURRENT_HEAD_SHA" failure "${CRITICAL_COUNT} Critical finding(s) — resolve or /override-ai-review"
else
  post_status "$CURRENT_HEAD_SHA" success "Review OK — 0 Critical, ${WARNINGS_COUNT} Warning(s)"
fi

echo "review posted (critical=$CRITICAL_COUNT warnings=$WARNINGS_COUNT suggestions=$SUGGESTIONS_COUNT nits=$NITS_COUNT)"
