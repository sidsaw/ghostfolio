#!/usr/bin/env bash
# create-devin-session.sh — Start a Devin session for a GitHub issue and post a comment.
#
# Usage (env-var style, for GitHub Actions):
#   ISSUE_NUMBER=<n>  ISSUE_TITLE=<title>  ISSUE_BODY=<body>  ./scripts/create-devin-session.sh
#
# Or positional args (for local use):
#   ./scripts/create-devin-session.sh <issue_number> <issue_title> <issue_body>
#
# Required env vars:
#   GH_PAT              — GitHub PAT (for posting the comment)
#   DEVIN_API_TOKEN     — Devin service token
#   DEVIN_ORG_ID        — e.g. org-bd83a43825e94f2a813d2e60862f9059
#
# Optional env vars (have sensible defaults):
#   REPO_OWNER          — default: sidsaw
#   REPO_NAME           — default: ghostfolio
#   REPO_URL            — default: https://github.com/<REPO_OWNER>/<REPO_NAME>
#
# Outputs (to stdout, one per line):
#   DEVIN_SESSION_ID=<id>
#   DEVIN_SESSION_URL=<url>
#
# Requires: curl, jq, gh CLI

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ISSUE_NUMBER="${ISSUE_NUMBER:-${1:-}}"
ISSUE_TITLE="${ISSUE_TITLE:-${2:-}}"
ISSUE_BODY="${ISSUE_BODY:-${3:-}}"

if [[ -z "$ISSUE_NUMBER" || -z "$ISSUE_TITLE" ]]; then
  echo "Usage: ISSUE_NUMBER=<n> ISSUE_TITLE=<title> ISSUE_BODY=<body> $0" >&2
  echo "  or: $0 <issue_number> <issue_title> [issue_body]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REPO_OWNER="${REPO_OWNER:-sidsaw}"
REPO_NAME="${REPO_NAME:-ghostfolio}"
REPO_URL="${REPO_URL:-https://github.com/${REPO_OWNER}/${REPO_NAME}}"

# ---------------------------------------------------------------------------
# Validate required secrets
# ---------------------------------------------------------------------------
GH_PAT="${GH_PAT:-}"
DEVIN_API_TOKEN="${DEVIN_API_TOKEN:-}"
DEVIN_ORG_ID="${DEVIN_ORG_ID:-}"

for var in GH_PAT DEVIN_API_TOKEN DEVIN_ORG_ID; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: ${var} is not set" >&2
    exit 1
  fi
done

DEVIN_API_BASE="https://api.devin.ai/v3/organizations/${DEVIN_ORG_ID}"

# ---------------------------------------------------------------------------
# 1. Build the prompt for Devin
# ---------------------------------------------------------------------------
PROMPT="You are working on the repository ${REPO_URL}.

Please fix the following GitHub issue:

Title: ${ISSUE_TITLE}

${ISSUE_BODY}

Instructions:
- Clone the repo, create a feature branch, and implement a fix.
- Open a pull request when done.
- The PR body MUST include \`closes #${ISSUE_NUMBER}\` so the issue links automatically.
- Keep the PR focused on the issue — no unrelated changes."

# ---------------------------------------------------------------------------
# 2. Create the Devin session
# ---------------------------------------------------------------------------
echo "Creating Devin session for issue #${ISSUE_NUMBER}..."

DEVIN_RESP=$(curl --silent --fail-with-body \
  -X POST "${DEVIN_API_BASE}/sessions" \
  -H "Authorization: Bearer ${DEVIN_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg prompt "$PROMPT" '{"prompt": $prompt}')")

# Check for curl/API error
if [[ $? -ne 0 ]]; then
  echo "ERROR: Devin API request failed:" >&2
  echo "$DEVIN_RESP" >&2
  exit 1
fi

SESSION_ID=$(echo "$DEVIN_RESP" | jq -r '.session_id // empty')
SESSION_URL=$(echo "$DEVIN_RESP" | jq -r '.url // empty')

if [[ -z "$SESSION_ID" ]]; then
  echo "ERROR: Devin API returned no session_id. Full response:" >&2
  echo "$DEVIN_RESP" | jq . >&2
  exit 1
fi

echo "  Session ID : ${SESSION_ID}"
echo "  Session URL: ${SESSION_URL}"

# ---------------------------------------------------------------------------
# 3. Post a comment on the GitHub issue
# ---------------------------------------------------------------------------
COMMENT_BODY="🤖 **Devin is on it!**

A Devin session has been started for this issue.

| | |
|---|---|
| **Session ID** | \`${SESSION_ID}\` |
| **Session URL** | ${SESSION_URL} |

Devin will open a PR with \`closes #${ISSUE_NUMBER}\` in the body when done. You can follow progress at the session URL above."

echo "Posting comment on issue #${ISSUE_NUMBER}..."

gh api \
  -H "Authorization: Bearer ${GH_PAT}" \
  -X POST \
  "/repos/${REPO_OWNER}/${REPO_NAME}/issues/${ISSUE_NUMBER}/comments" \
  -f body="$COMMENT_BODY" \
  --silent

echo "Comment posted."

# ---------------------------------------------------------------------------
# 4. Emit outputs (for use by calling workflow steps)
# ---------------------------------------------------------------------------
echo "DEVIN_SESSION_ID=${SESSION_ID}"
echo "DEVIN_SESSION_URL=${SESSION_URL}"
