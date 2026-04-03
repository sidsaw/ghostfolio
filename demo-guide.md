# Demo Guide

**Repo:** `sidsaw/ghostfolio` · **Project board:** [Devin Issue Triage](https://github.com/users/sidsaw/projects)

---

## Board Columns

`Inbox` → `Backlog` → `Devin PR` / `In Progress` → `In Review` → `Done`

---

## Devin Path

| Step | Action | What happens |
|---|---|---|
| 1 | File a new issue | Issue appears in **Inbox** with `triage` label |
| 2 | Add label `devin:review` | Devin reads the issue and posts an assessment comment, then adds `devin:ready` or `devin:triaged` and removes `devin:review` |
| 3 | Move issue to **Devin PR** column + add label `devin:execute` | Devin starts implementing; posts session link as a comment |
| 4 | *(wait)* Devin opens a PR with `closes #N` | Issue moves to **In Review** automatically |
| 5 | Review and merge the PR | Issue moves to **Done** and closes automatically |

**Labels set by Devin:**
- `devin:ready` — Devin can do it autonomously (plan posted as comment)
- `devin:triaged` — Devin needs more info (explanation posted as comment)

---

## Human Path

| Step | Action | What happens |
|---|---|---|
| 1 | File a new issue | Issue appears in **Inbox** with `triage` label |
| 2 | Add label `human` | Issue moves to **Backlog** |
| 3 | Assign the issue to an engineer | Issue moves to **In Progress** |
| 4 | Engineer opens a PR with `closes #N` | Issue moves to **In Review** automatically |
| 5 | Review and merge the PR | Issue moves to **Done** and closes automatically |

---

## Good Demo Issues

- **Bug:** *"Currency conversion uses stale exchange rates in portfolio summary"*
- **Feature:** *"Add dark mode toggle to the settings page"*
- **Docs:** *"README missing setup instructions for Docker Compose"*

---

## Setup (first time only)

```bash
# 1. Create the project board and labels
GH_PAT=<token> ./scripts/setup-project.sh

# 2. Set repo variables
gh variable set PROJECT_NUMBER --repo sidsaw/ghostfolio --body "<number from above>"
gh variable set PROJECT_OWNER  --repo sidsaw/ghostfolio --body "sidsaw"
gh variable set DEVIN_ORG_ID   --repo sidsaw/ghostfolio --body "org-bd83a43825e94f2a813d2e60862f9059"

# 3. Set repo secrets
gh secret set GH_PAT           --repo sidsaw/ghostfolio --body "<token>"
gh secret set DEVIN_API_TOKEN  --repo sidsaw/ghostfolio --body "<token>"

# 4. Seed any existing issues to Inbox (one-time)
GH_PAT=<token> ./scripts/seed-inbox.sh
```
