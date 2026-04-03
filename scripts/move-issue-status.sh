#!/usr/bin/env bash
# move-issue-status.sh — Move a GitHub issue to a target Status on the project board.
#
# Usage (env-var style, for GitHub Actions):
#   ISSUE_NODE_ID=<id>  TARGET_STATUS=<status>  ./scripts/move-issue-status.sh
#
# Or positional args (for local use):
#   ./scripts/move-issue-status.sh <issue_node_id> <target_status>
#
# Target status values: Inbox | Backlog | Devin PR | In Progress | In Review | Done
#
# Required env vars (or loaded from .env.project):
#   GH_PAT                  — GitHub PAT with project scope
#   PROJECT_ID              — Project node ID  (PVT_...)
#   STATUS_FIELD_ID         — Status field node ID  (PVTSSF_...)
#   OPT_INBOX / OPT_BACKLOG / OPT_DEVIN_PR / OPT_IN_PROGRESS / OPT_IN_REVIEW / OPT_DONE
#
# Requires: gh CLI, jq

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ISSUE_NODE_ID="${ISSUE_NODE_ID:-${1:-}}"
TARGET_STATUS="${TARGET_STATUS:-${2:-}}"

if [[ -z "$ISSUE_NODE_ID" || -z "$TARGET_STATUS" ]]; then
  echo "Usage: ISSUE_NODE_ID=<id> TARGET_STATUS=<status> $0" >&2
  echo "  or: $0 <issue_node_id> <target_status>" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Load .env.project if present and vars aren't already set
# ---------------------------------------------------------------------------
ENV_FILE="${ENV_FILE:-.env.project}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Validate required vars
# ---------------------------------------------------------------------------
TOKEN="${GH_PAT:-}"
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: GH_PAT is not set" >&2
  exit 1
fi

for var in PROJECT_ID STATUS_FIELD_ID \
           OPT_INBOX OPT_BACKLOG OPT_DEVIN_PR OPT_IN_PROGRESS OPT_IN_REVIEW OPT_DONE; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} is not set. Run setup-project.sh first." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Map target status name → option ID
# ---------------------------------------------------------------------------
case "$TARGET_STATUS" in
  "Inbox")       OPT_ID="$OPT_INBOX"       ;;
  "Backlog")     OPT_ID="$OPT_BACKLOG"     ;;
  "Devin PR")    OPT_ID="$OPT_DEVIN_PR"    ;;
  "In Progress") OPT_ID="$OPT_IN_PROGRESS" ;;
  "In Review")   OPT_ID="$OPT_IN_REVIEW"   ;;
  "Done")        OPT_ID="$OPT_DONE"        ;;
  *)
    echo "ERROR: Unknown status \"${TARGET_STATUS}\"." >&2
    echo "  Valid values: Inbox | Backlog | Devin PR | In Progress | In Review | Done" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
gql() {
  gh api graphql \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Github-Next-Global-ID: 1" \
    "$@"
}

# ---------------------------------------------------------------------------
# 1. Find the project item ID for this issue
# ---------------------------------------------------------------------------
echo "Looking up project item for issue ${ISSUE_NODE_ID}..."

ITEM_RESP=$(gql -f query='
{
  node(id: "'"${ISSUE_NODE_ID}"'") {
    ... on Issue {
      projectItems(first: 20) {
        nodes {
          id
          project { id }
        }
      }
    }
  }
}')

ITEM_ID=$(echo "$ITEM_RESP" | jq -r \
  --arg pid "$PROJECT_ID" \
  '.data.node.projectItems.nodes[] | select(.project.id == $pid) | .id' \
  | head -1)

if [[ -z "$ITEM_ID" || "$ITEM_ID" == "null" ]]; then
  echo "ERROR: Issue ${ISSUE_NODE_ID} is not on project ${PROJECT_ID}." >&2
  echo "  Add it to the project first (issue-opened workflow)." >&2
  exit 1
fi

echo "  Project item ID: ${ITEM_ID}"

# ---------------------------------------------------------------------------
# 2. Update the Status field
# ---------------------------------------------------------------------------
echo "Moving to \"${TARGET_STATUS}\" (option ${OPT_ID})..."

UPDATE_RESP=$(gql -f query='
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "'"${PROJECT_ID}"'"
    itemId:    "'"${ITEM_ID}"'"
    fieldId:   "'"${STATUS_FIELD_ID}"'"
    value:     { singleSelectOptionId: "'"${OPT_ID}"'" }
  }) {
    projectV2Item { id }
  }
}')

UPDATED_ID=$(echo "$UPDATE_RESP" | jq -r '.data.updateProjectV2ItemFieldValue.projectV2Item.id')

if [[ -z "$UPDATED_ID" || "$UPDATED_ID" == "null" ]]; then
  echo "ERROR: Mutation returned no item. Response:" >&2
  echo "$UPDATE_RESP" | jq . >&2
  exit 1
fi

echo "Done — issue is now \"${TARGET_STATUS}\"."
