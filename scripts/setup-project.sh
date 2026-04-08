#!/usr/bin/env bash
# setup-project.sh — Create (or reuse) the Devin Issue Triage GitHub Project v2
# Idempotent: safe to run multiple times.
#
# Usage:
#   GH_PAT=<token> ./scripts/setup-project.sh
#
# Requires: gh CLI, jq

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
PROJECT_TITLE="Devin Issue Triage"
REPO_OWNER="sidsaw"
REPO_NAME="ghostfolio"
ENV_FILE=".env.project"

# Auth: prefer GH_PAT env var, fall back to gh auth token
TOKEN="${GH_PAT:-$(gh auth token 2>/dev/null)}"
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Set GH_PAT or run 'gh auth login'" >&2
  exit 1
fi

# Helper: run a GraphQL query/mutation authenticated with GH_PAT
gql() {
  gh api graphql \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Github-Next-Global-ID: 1" \
    "$@"
}

# ---------------------------------------------------------------------------
# 1. Resolve owner node ID and repo node ID
# ---------------------------------------------------------------------------
echo "==> Resolving owner and repo IDs..."
IDS=$(gql -f query='
{
  user(login: "'"${REPO_OWNER}"'") { id }
  repository(owner: "'"${REPO_OWNER}"'", name: "'"${REPO_NAME}"'") { id }
}')
OWNER_ID=$(echo "$IDS" | jq -r '.data.user.id')
REPO_ID=$(echo "$IDS"  | jq -r '.data.repository.id')
echo "    Owner ID : $OWNER_ID"
echo "    Repo  ID : $REPO_ID"

# ---------------------------------------------------------------------------
# 2. Find or create the project
# ---------------------------------------------------------------------------
echo "==> Checking for existing project \"${PROJECT_TITLE}\"..."
EXISTING=$(gql -f query='
{
  user(login: "'"${REPO_OWNER}"'") {
    projectsV2(first: 50) {
      nodes { id number title }
    }
  }
}')

PROJECT_NODE=$(echo "$EXISTING" | jq -r \
  --arg title "$PROJECT_TITLE" \
  '.data.user.projectsV2.nodes[] | select(.title == $title) | @base64' | head -1)

if [[ -n "$PROJECT_NODE" ]]; then
  PROJECT_DATA=$(echo "$PROJECT_NODE" | base64 --decode)
  PROJECT_ID=$(echo "$PROJECT_DATA"     | jq -r '.id')
  PROJECT_NUMBER=$(echo "$PROJECT_DATA" | jq -r '.number')
  echo "    Found existing project #${PROJECT_NUMBER} (${PROJECT_ID})"
else
  echo "    Not found — creating..."
  CREATE_RESP=$(gql -f query='
mutation {
  createProjectV2(input: {
    ownerId:      "'"${OWNER_ID}"'"
    title:        "'"${PROJECT_TITLE}"'"
    repositoryId: "'"${REPO_ID}"'"
  }) {
    projectV2 { id number }
  }
}')
  PROJECT_ID=$(echo "$CREATE_RESP"     | jq -r '.data.createProjectV2.projectV2.id')
  PROJECT_NUMBER=$(echo "$CREATE_RESP" | jq -r '.data.createProjectV2.projectV2.number')
  echo "    Created project #${PROJECT_NUMBER} (${PROJECT_ID})"
fi

# ---------------------------------------------------------------------------
# 3. Helper: list all fields on the project
# ---------------------------------------------------------------------------
list_fields() {
  gql -f query='
{
  node(id: "'"${PROJECT_ID}"'") {
    ... on ProjectV2 {
      fields(first: 30) {
        nodes {
          ... on ProjectV2Field             { id name dataType }
          ... on ProjectV2SingleSelectField { id name dataType options { id name } }
          ... on ProjectV2IterationField    { id name dataType }
        }
      }
    }
  }
}' | jq '.data.node.fields.nodes'
}

# ---------------------------------------------------------------------------
# 4. Helper: build GraphQL singleSelectOptions literal from a JSON options array
#    Input:  '[{"name":"Inbox","color":"GRAY","description":"..."},...]'
#    Output: '{ name: "Inbox", color: GRAY, description: "..." }, ...'
# ---------------------------------------------------------------------------
build_opts_gql() {
  echo "$1" | jq -r \
    '.[] | "{ name: \"" + .name + "\", color: " + .color + ", description: \"" + .description + "\" }"' \
    | paste -sd ',' -
}

# ---------------------------------------------------------------------------
# 5. Helper: ensure a single-select field has exactly the required options.
#
#    Strategy:
#      - If field doesn't exist:  create with createProjectV2Field
#      - If field exists but options differ: update with updateProjectV2Field
#      - If field already correct: no-op
#
#    Args: field_name  required_names_json  options_full_json
#    Prints the field ID on the LAST line of stdout.
# ---------------------------------------------------------------------------
ensure_single_select_field() {
  local field_name="$1"
  local required_names_json="$2"  # e.g. '["Inbox","Backlog","Done"]'
  local options_full_json="$3"    # e.g. '[{"name":"Inbox","color":"GRAY","description":""}]'

  local fields
  fields=$(list_fields)

  local existing
  existing=$(echo "$fields" | jq -c \
    --arg n "$field_name" \
    '.[] | select(.name == $n and .dataType == "SINGLE_SELECT")')

  local opts_gql
  opts_gql=$(build_opts_gql "$options_full_json")

  if [[ -z "$existing" ]]; then
    # Field doesn't exist — create it
    echo "    Field \"${field_name}\" not found — creating..."
    local resp
    resp=$(gql -f query='
mutation {
  createProjectV2Field(input: {
    projectId: "'"${PROJECT_ID}"'"
    dataType:  SINGLE_SELECT
    name:      "'"${field_name}"'"
    singleSelectOptions: ['"${opts_gql}"']
  }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField { id name options { id name } }
    }
  }
}')
    local new_id
    new_id=$(echo "$resp" | jq -r '.data.createProjectV2Field.projectV2Field.id')
    echo "    Created \"${field_name}\" (${new_id})"
    echo "$new_id"
    return
  fi

  # Field exists — check if options match
  local existing_names
  existing_names=$(echo "$existing" | jq -c '[.options[].name]')

  local match
  match=$(jq -n \
    --argjson have "$existing_names" \
    --argjson want "$required_names_json" \
    '($have | sort) == ($want | sort)')

  if [[ "$match" == "true" ]]; then
    echo "    Field \"${field_name}\" already correct — skipping"
    echo "$existing" | jq -r '.id'
    return
  fi

  # Options differ — update the field in-place (works for built-in and custom fields)
  echo "    Field \"${field_name}\" exists with wrong options — updating..."
  local field_id
  field_id=$(echo "$existing" | jq -r '.id')

  local update_resp
  update_resp=$(gql -f query='
mutation {
  updateProjectV2Field(input: {
    fieldId: "'"${field_id}"'"
    singleSelectOptions: ['"${opts_gql}"']
  }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField { id name options { id name } }
    }
  }
}')
  local updated_id
  updated_id=$(echo "$update_resp" | jq -r '.data.updateProjectV2Field.projectV2Field.id')
  echo "    Updated \"${field_name}\" (${updated_id})"
  echo "$updated_id"
}

# ---------------------------------------------------------------------------
# 6. Define required fields
# ---------------------------------------------------------------------------

STATUS_OPTIONS='[
  {"name":"Inbox",       "color":"GRAY",   "description":"New, untriaged"},
  {"name":"Backlog",     "color":"BLUE",   "description":"Triaged and prioritized"},
  {"name":"Devin PR",   "color":"PURPLE", "description":"Handed off to Devin"},
  {"name":"In Progress","color":"YELLOW", "description":"Human actively working"},
  {"name":"In Review",  "color":"ORANGE", "description":"PR open, awaiting review"},
  {"name":"Done",        "color":"GREEN",  "description":"Merged and closed"}
]'
STATUS_NAMES='["Inbox","Backlog","Devin PR","In Progress","In Review","Done"]'

PRIORITY_OPTIONS='[
  {"name":"Critical","color":"RED",    "description":""},
  {"name":"High",    "color":"ORANGE", "description":""},
  {"name":"Medium",  "color":"YELLOW", "description":""},
  {"name":"Low",     "color":"GRAY",   "description":""}
]'
PRIORITY_NAMES='["Critical","High","Medium","Low"]'

ASSIGNEE_TYPE_OPTIONS='[
  {"name":"Human","color":"BLUE",   "description":""},
  {"name":"Devin","color":"PURPLE", "description":""}
]'
ASSIGNEE_TYPE_NAMES='["Human","Devin"]'

# ---------------------------------------------------------------------------
# 7. Ensure each field exists with correct options
# ---------------------------------------------------------------------------
echo "==> Ensuring Status field..."
STATUS_FIELD_ID=$(ensure_single_select_field "Status" "$STATUS_NAMES" "$STATUS_OPTIONS" | tail -1)

echo "==> Ensuring Priority field..."
PRIORITY_FIELD_ID=$(ensure_single_select_field "Priority" "$PRIORITY_NAMES" "$PRIORITY_OPTIONS" | tail -1)

echo "==> Ensuring Assignee Type field..."
ASSIGNEE_TYPE_FIELD_ID=$(ensure_single_select_field "Assignee Type" "$ASSIGNEE_TYPE_NAMES" "$ASSIGNEE_TYPE_OPTIONS" | tail -1)

# ---------------------------------------------------------------------------
# 8. Fetch all option IDs (needed by the workflows)
# ---------------------------------------------------------------------------
echo "==> Fetching option IDs..."
FIELDS=$(list_fields)

get_option_id() {
  local field_id="$1" option_name="$2"
  echo "$FIELDS" | jq -r \
    --arg fid "$field_id" --arg opt "$option_name" \
    '.[] | select(.id == $fid) | .options[] | select(.name == $opt) | .id'
}

# Status option IDs
OPT_INBOX=$(get_option_id       "$STATUS_FIELD_ID" "Inbox")
OPT_BACKLOG=$(get_option_id     "$STATUS_FIELD_ID" "Backlog")
OPT_DEVIN_PR=$(get_option_id    "$STATUS_FIELD_ID" "Devin PR")
OPT_IN_PROGRESS=$(get_option_id "$STATUS_FIELD_ID" "In Progress")
OPT_IN_REVIEW=$(get_option_id   "$STATUS_FIELD_ID" "In Review")
OPT_DONE=$(get_option_id        "$STATUS_FIELD_ID" "Done")

# Priority option IDs
OPT_CRITICAL=$(get_option_id "$PRIORITY_FIELD_ID" "Critical")
OPT_HIGH=$(get_option_id     "$PRIORITY_FIELD_ID" "High")
OPT_MEDIUM=$(get_option_id   "$PRIORITY_FIELD_ID" "Medium")
OPT_LOW=$(get_option_id      "$PRIORITY_FIELD_ID" "Low")

# Assignee Type option IDs
OPT_HUMAN=$(get_option_id "$ASSIGNEE_TYPE_FIELD_ID" "Human")
OPT_DEVIN=$(get_option_id "$ASSIGNEE_TYPE_FIELD_ID" "Devin")

# Validate nothing is empty
for var in STATUS_FIELD_ID PRIORITY_FIELD_ID ASSIGNEE_TYPE_FIELD_ID \
           OPT_INBOX OPT_BACKLOG OPT_DEVIN_PR OPT_IN_PROGRESS OPT_IN_REVIEW OPT_DONE \
           OPT_CRITICAL OPT_HIGH OPT_MEDIUM OPT_LOW \
           OPT_HUMAN OPT_DEVIN; do
  val="${!var}"
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo "ERROR: ${var} resolved to '${val}' — check field/option names." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 9. Write .env.project
# ---------------------------------------------------------------------------
echo "==> Writing ${ENV_FILE}..."
cat > "${ENV_FILE}" <<EOF
# Auto-generated by scripts/setup-project.sh — do not edit by hand.
# Re-run the script to regenerate.

PROJECT_OWNER=${REPO_OWNER}
PROJECT_NUMBER=${PROJECT_NUMBER}
PROJECT_ID=${PROJECT_ID}

STATUS_FIELD_ID=${STATUS_FIELD_ID}
PRIORITY_FIELD_ID=${PRIORITY_FIELD_ID}
ASSIGNEE_TYPE_FIELD_ID=${ASSIGNEE_TYPE_FIELD_ID}

# Status option IDs
OPT_INBOX=${OPT_INBOX}
OPT_BACKLOG=${OPT_BACKLOG}
OPT_DEVIN_PR=${OPT_DEVIN_PR}
OPT_IN_PROGRESS=${OPT_IN_PROGRESS}
OPT_IN_REVIEW=${OPT_IN_REVIEW}
OPT_DONE=${OPT_DONE}

# Priority option IDs
OPT_CRITICAL=${OPT_CRITICAL}
OPT_HIGH=${OPT_HIGH}
OPT_MEDIUM=${OPT_MEDIUM}
OPT_LOW=${OPT_LOW}

# Assignee Type option IDs
OPT_HUMAN=${OPT_HUMAN}
OPT_DEVIN=${OPT_DEVIN}
EOF

# ---------------------------------------------------------------------------
# 10. Configure "Item added to project" built-in automation → Status = Inbox
#
#     GitHub Projects v2 has built-in workflows (automations) accessible via
#     GraphQL.  The "Item added to project" workflow can be enabled so new
#     items get a default Status; we also explicitly set Status = Inbox in
#     the issue-opened.yml workflow, so this is belt-and-suspenders for items
#     added through the UI or other paths.
# ---------------------------------------------------------------------------
echo "==> Configuring 'Item added to project' automation (Status → Inbox)..."

WORKFLOWS_RESP=$(gql -f query='
{
  node(id: "'"${PROJECT_ID}"'") {
    ... on ProjectV2 {
      workflows(first: 20) {
        nodes { id name enabled number }
      }
    }
  }
}' 2>/dev/null || echo '{}')

ITEM_ADDED_ID=$(echo "$WORKFLOWS_RESP" | jq -r \
  '(.data.node.workflows.nodes // [])[] | select(.name == "Item added to project") | .id' \
  2>/dev/null || true)

if [[ -n "$ITEM_ADDED_ID" && "$ITEM_ADDED_ID" != "null" ]]; then
  echo "    Found workflow ${ITEM_ADDED_ID} — enabling..."
  ENABLE_RESP=$(gql -f query='
mutation {
  updateProjectV2Workflow(input: {
    workflowId: "'"${ITEM_ADDED_ID}"'"
    enabled: true
  }) {
    workflow { id enabled }
  }
}' 2>/dev/null || echo '{}')

  ENABLED=$(echo "$ENABLE_RESP" | jq -r '.data.updateProjectV2Workflow.workflow.enabled' 2>/dev/null || echo "unknown")
  echo "    Workflow enabled: ${ENABLED}"
  echo "    NOTE: To also set Status=Inbox via this automation, open the project in the GitHub UI"
  echo "    and configure the 'Item added to project' workflow to set Status = Inbox."
else
  echo "    No 'Item added to project' workflow found via API (may require UI configuration)."
  echo "    The issue-opened.yml workflow explicitly sets Status=Inbox for all issues."
fi

# ---------------------------------------------------------------------------
# 11. Ensure required labels exist on the repo
#
#     Uses `gh label create --force` which is idempotent: creates the label
#     if absent, updates color/description if it already exists.
# ---------------------------------------------------------------------------
echo "==> Ensuring Devin workflow labels on ${REPO_OWNER}/${REPO_NAME}..."

declare -A LABELS
LABELS["triage"]="E4E669:Needs triage — auto-applied on issue creation"
LABELS["human"]="0075CA:Requires a human engineer"
LABELS["devin:review"]="1D76DB:Trigger: ask Devin to review the issue"
LABELS["devin:ready"]="0E8A16:Devin assessed: can implement the PR autonomously"
LABELS["devin:triaged"]="E99695:Devin assessed: needs human input or clarification"
LABELS["devin:execute"]="5319E7:Trigger: ask Devin to implement the PR"
LABELS["devin:test"]="F9D0C4:Trigger: ask Devin to review and test this PR"

for label_name in "${!LABELS[@]}"; do
  IFS=':' read -r color description <<< "${LABELS[$label_name]}"
  echo "    Label: ${label_name}"
  gh label create "${label_name}" \
    --repo "${REPO_OWNER}/${REPO_NAME}" \
    --color "${color}" \
    --description "${description}" \
    --force \
    2>&1 | sed 's/^/      /' || true
done

echo "    Labels configured."

# ---------------------------------------------------------------------------
# 12. Print summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Project : ${PROJECT_TITLE}"
echo "  Number  : ${PROJECT_NUMBER}"
echo "  ID      : ${PROJECT_ID}"
echo "------------------------------------------------------------"
echo "  Status field ID        : ${STATUS_FIELD_ID}"
echo "  Priority field ID      : ${PRIORITY_FIELD_ID}"
echo "  Assignee Type field ID : ${ASSIGNEE_TYPE_FIELD_ID}"
echo "------------------------------------------------------------"
echo "  Status options:"
echo "    Inbox       : ${OPT_INBOX}"
echo "    Backlog     : ${OPT_BACKLOG}"
echo "    Devin PR    : ${OPT_DEVIN_PR}"
echo "    In Progress : ${OPT_IN_PROGRESS}"
echo "    In Review   : ${OPT_IN_REVIEW}"
echo "    Done        : ${OPT_DONE}"
echo "============================================================"
echo ""
echo "Next step — set the PROJECT_NUMBER repo variable:"
echo ""
echo "  gh variable set PROJECT_NUMBER --repo ${REPO_OWNER}/${REPO_NAME} --body \"${PROJECT_NUMBER}\""
echo ""
echo "Field IDs written to: ${ENV_FILE}"
