# CLAUDE.md

## What This Is

An automated issue triage system for `sidsaw/ghostfolio` using GitHub Projects v2, GitHub Actions, and Devin AI. Issues flow through a kanban board. Some get handed to Devin (autonomous AI engineer), some to humans. The board updates automatically as work progresses.

---

## Target Repo

`sidsaw/ghostfolio` — https://github.com/sidsaw/ghostfolio

The GitHub Project board lives under the `sidsaw` user (not an org).

---

## ⚠️ Credentials — STORE AS SECRETS, NEVER COMMIT

```
DEVIN_API_TOKEN — stored as repo secret
GH_PAT — stored as repo secret (needs repo + project scopes)
```

Set them:
```bash
gh secret set DEVIN_API_TOKEN --repo sidsaw/ghostfolio --body "<token>"
gh secret set GH_PAT --repo sidsaw/ghostfolio --body "<token>"
gh variable set DEVIN_ORG_ID --repo sidsaw/ghostfolio --body "org-bd83a43825e94f2a813d2e60862f9059"
gh variable set PROJECT_OWNER --repo sidsaw/ghostfolio --body "sidsaw"
```

---

## Board Columns (GitHub Project Status Field)

| Status | Purpose |
|---|---|
| **Inbox** | **Default for every issue.** New issues land here. No issue should ever be in "No Status." |
| **Backlog** | Triaged and prioritized. Assigned to human or flagged for Devin. |
| **Devin PR** | Handed off to Devin to do the PR. Session running or PR opened by Devin. |
| **In Progress** | A human is actively working on it. |
| **In Review** | A PR exists (human or Devin) awaiting code review. Both tracks converge here. |
| **Done** | Merged and closed. |

---

## Labels

### Devin workflow labels
- `devin:review` — **Trigger label.** User applies this to ask Devin to review the issue and decide if it can do the work. Removed by the workflow after Devin responds.
- `devin:ready` — Applied by Devin when it determines it CAN do the PR. Means Devin has posted its plan and the issue is ready to be moved to "Devin PR."
- `devin:triaged` — Applied by Devin when it determines it CANNOT do the PR. Means Devin has posted what it needs or what a human should do.

### General labels
- `human` — Requires a human engineer.
- `triage` — Needs triage (auto-applied on creation, removed after triage).
- `priority:critical` / `priority:high` / `priority:medium` / `priority:low`
- `bug`, `feature`, `chore`, `docs`

---

## Devin API

**Org ID:** `org-bd83a43825e94f2a813d2e60862f9059`
**Endpoint:** `https://api.devin.ai/v3/organizations/org-bd83a43825e94f2a813d2e60862f9059/sessions`
**Auth:** `Authorization: Bearer $DEVIN_API_TOKEN`

### Create a session:
```bash
curl -X POST "https://api.devin.ai/v3/organizations/org-bd83a43825e94f2a813d2e60862f9059/sessions" \
  -H "Authorization: Bearer $DEVIN_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "<prompt_text>"
  }'
```

Response has `session_id` and `url`. Post both as a comment on the issue.

### Check session status:
```bash
curl "https://api.devin.ai/v3/organizations/org-bd83a43825e94f2a813d2e60862f9059/sessions/$SESSION_ID" \
  -H "Authorization: Bearer $DEVIN_API_TOKEN"
```

---

## Three Changes To Build

### Change 1: Every issue starts in Inbox (no "No Status")

**Problem:** When issues are added to the GitHub Project, they can land in "No Status" if the workflow doesn't explicitly set the status. Nothing should ever be in "No Status."

**What to do:**
- The `setup-project.sh` script must configure the project so the default status field value is "Inbox."
- The `issue-opened.yml` workflow must add the issue to the project AND explicitly set its status to "Inbox" in the same workflow run.
- Any existing issues already on the board with "No Status" should be moved to "Inbox" (a one-time seed script or manual fix).
- The project board settings should be verified so that items added via the UI also default to Inbox.

### Change 2: Devin Review Workflow (issue-devin-review.yml)

**Trigger:** `issues: [labeled]` where the label is `devin:review`

**Flow:**
1. User applies the `devin:review` label to an issue that is in Inbox status.
2. Workflow calls Devin API with a **review prompt** (not a "do the work" prompt). The prompt tells Devin to:
   - Read the issue title, body, and all comments.
   - Assess whether it can autonomously create a PR to resolve this issue.
   - If YES:
     - Post a comment on the issue with its plan (what files it will change, approach, etc.).
     - Add the `devin:ready` label to the issue.
   - If NO:
     - Post a comment explaining what clarity it needs from the team and/or a plan a human should follow.
     - Add the `devin:triaged` label to the issue.
   - In both cases: remove the `devin:review` label.
3. **The issue stays in Inbox.** This workflow does NOT change the project status.

**Key details:**
- The Devin prompt must explicitly instruct Devin to use the GitHub API to add/remove labels and post comments.
- Devin needs access to the repo and issue context. Include the full issue URL in the prompt so Devin can read comments.
- The workflow itself should NOT move the issue status. Devin's job here is assessment only.

### Change 3: Devin PR Workflow (issue-devin-pr.yml)

**Trigger:** Project item moved to "Devin PR" status. Since GitHub Actions can't directly trigger on project field changes, use `issues: [labeled]` with a workflow that detects status change, OR use a `workflow_dispatch` / manual trigger, OR poll. Recommended approach: trigger on `project_card` events or use a secondary label like moving the card triggers a workflow. **Simplest approach:** Use a `workflow_dispatch` that accepts an issue number, or trigger on the issue being assigned to a "devin" user, or add a `devin:execute` label when moving to Devin PR column.

**Alternative trigger (recommended):** Since GitHub Projects v2 doesn't emit events on column moves, the simplest reliable trigger is:
- When a user moves an issue to "Devin PR" status, they also apply a `devin:execute` label (or automate this with a project automation rule).
- The workflow triggers on `issues: [labeled]` where label is `devin:execute`.

**Flow:**
1. Issue is moved to "Devin PR" status (and `devin:execute` label is applied).
2. Workflow calls Devin API with an **execution prompt** telling Devin to:
   - Read the issue description, all comments, and the codebase.
   - If the issue does NOT have the `devin:ready` label (meaning Devin hasn't already reviewed it): post its plan as a comment first, then do the work.
   - If the issue DOES have the `devin:ready` label (meaning a plan was already posted during review): proceed directly with the work.
   - Open a PR with `closes #<issue_number>` in the body.
3. The issue stays in "Devin PR" status. The existing `pr-opened.yml` and `pr-merged.yml` workflows handle moving it to "In Review" and "Done."

---

## File Structure
```
.
├── .github/
│   └── workflows/
│       ├── issue-opened.yml           # New issue → add to project as Inbox + triage label
│       ├── issue-devin-review.yml     # devin:review label → Devin assesses, adds devin:ready or devin:triaged
│       ├── issue-devin-pr.yml         # devin:execute label (Devin PR column) → Devin does the PR
│       ├── issue-triaged.yml          # human label → Backlog
│       ├── pr-opened.yml              # PR opened → move linked issue to In Review
│       ├── pr-merged.yml              # PR merged → move linked issue to Done, close it
│       └── issue-assigned.yml         # Human assigned → In Progress
├── scripts/
│   ├── setup-project.sh               # Creates GitHub Project with all fields/columns, Inbox as default
│   ├── move-issue-status.sh           # Helper: GraphQL mutation to change project item status
│   ├── create-devin-session.sh        # Helper: Calls Devin API, comments on issue
│   └── seed-inbox.sh                  # One-time: moves all "No Status" items to Inbox
├── .env.project                       # Generated by setup-project.sh (field IDs, project ID)
├── .env.project.example               # Template with placeholder values
├── BUILD-GUIDE.md                     # Step-by-step prompts for Claude Code
├── CLAUDE.md                          # This file
└── README.md
```

---

## Key Technical Decisions

- **GitHub Projects v2 requires GraphQL.** REST API cannot mutate project items.
- **`secrets.GH_PAT` everywhere, not `github.token`.** Default token can't write to Projects v2.
- **Devin bot username:** Likely `devin-ai-integration[bot]` — verify after first Devin PR.
- **Issue-to-PR linking:** Relies on `closes #N` / `fixes #N` in PR body.
- **All workflows must be idempotent.**
- **GitHub Projects v2 doesn't emit events on column moves.** We use label-based triggers as a workaround.
- **Devin review vs. execution are separate workflows.** Review is cheap (assessment only). Execution is expensive (full session). This lets the user control when Devin actually starts working.

---

## Claude Code Prompts

### Prompt 1: Inbox Default + Seed Script

```
I need to make sure every issue on my GitHub Project board starts in "Inbox" status — nothing should ever be in "No Status."

Context: Read CLAUDE.md for the full project spec. The target repo is sidsaw/ghostfolio. The project board uses GitHub Projects v2 with GraphQL.

Do these things:

1. Update `scripts/setup-project.sh` so that when it creates or configures the project, "Inbox" is the default value for the Status field. Use the GitHub Projects v2 GraphQL API. If the project already exists, update it — don't create a duplicate.

2. Update `.github/workflows/issue-opened.yml` so that when a new issue is created, it:
   - Adds the issue to the project
   - Explicitly sets the status to "Inbox" (don't rely on the default — be explicit)
   - Adds the `triage` label
   - Uses `secrets.GH_PAT` for auth

3. Create `scripts/seed-inbox.sh` — a one-time script that:
   - Queries the project for all items that have no status set (null/empty)
   - Moves each one to "Inbox"
   - Prints what it moved
   - Uses GH_PAT from environment

All GraphQL mutations should use `updateProjectV2ItemFieldValue`. Read field IDs from environment variables or `.env.project`. Make everything idempotent.
```

### Prompt 2: Devin Review Workflow

```
I need a new GitHub Actions workflow that lets Devin AI review an issue and decide whether it can handle it.

Context: Read CLAUDE.md for the full project spec, especially "Change 2: Devin Review Workflow."

Build `.github/workflows/issue-devin-review.yml` that does this:

Trigger: `issues: [labeled]` — only runs when the label added is `devin:review`.

Steps:
1. Call the Devin API to create a session with a REVIEW prompt (not an execution prompt). The prompt should tell Devin:
   - Here is the issue: include full issue URL (https://github.com/sidsaw/ghostfolio/issues/<number>)
   - Read the issue title, description, and ALL comments on the issue
   - Assess whether you can autonomously create a PR to resolve this
   - If YES: post a comment on the issue with your plan (files to change, approach), then add the label `devin:ready` to the issue
   - If NO: post a comment explaining what clarity you need or what plan a human should follow, then add the label `devin:triaged` to the issue
   - In either case: remove the `devin:review` label from the issue
   - Do NOT open a PR. This is assessment only.

2. After calling the Devin API, post a comment on the issue saying "Devin is reviewing this issue..." with a link to the Devin session URL.

3. This workflow does NOT change the project board status. The issue stays wherever it is (should be Inbox).

Use `secrets.GH_PAT` for GitHub API calls and `secrets.DEVIN_API_TOKEN` for the Devin API. Use `scripts/create-devin-session.sh` as a helper or inline it — your call on what's cleaner.

The Devin API endpoint and auth details are in CLAUDE.md.
```

### Prompt 3: Devin PR Execution Workflow

```
I need a GitHub Actions workflow that triggers Devin to actually do the PR work.

Context: Read CLAUDE.md for the full project spec, especially "Change 3: Devin PR Workflow."

Build `.github/workflows/issue-devin-pr.yml` that does this:

Trigger: `issues: [labeled]` — only runs when the label added is `devin:execute`.

The intended usage: when I move an issue to the "Devin PR" column on the project board, I also add the `devin:execute` label to trigger this workflow.

Steps:
1. Check whether the issue has the `devin:ready` label.

2. Call the Devin API to create an execution session. The prompt should tell Devin:
   - Here is the issue: include full issue URL
   - Read the issue description, all comments, and explore the codebase at https://github.com/sidsaw/ghostfolio
   - If the issue does NOT have the `devin:ready` label: first post your plan as a comment, then do the work
   - If the issue DOES have the `devin:ready` label: a plan was already posted during review, proceed with the work
   - Open a PR with `closes #<issue_number>` in the PR body when done

3. Post a comment on the issue with the Devin session link.

4. Do NOT change the project status — the existing pr-opened.yml and pr-merged.yml workflows handle moving issues to "In Review" and "Done" when Devin opens/merges the PR.

Use `secrets.GH_PAT` and `secrets.DEVIN_API_TOKEN`. The Devin API details are in CLAUDE.md. Also create the `devin:execute` label in the setup script or label creation step if it doesn't exist.
```

---

## Current Status

Setup script and basic workflows exist. The three changes above are the next items to build. Do them in order — Change 1 first, then Change 2, then Change 3.
