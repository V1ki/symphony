---
tracker:
  kind: teambition
  # Teambition project _id (from the project URL path /project/<projectId>)
  project_slug: "REPLACE_WITH_TEAMBITION_PROJECT_ID"
  # Resolved at runtime from $TEAMBITION_ACCESS_TOKEN if left as the placeholder below.
  api_key: $TEAMBITION_ACCESS_TOKEN
  # Tenant header. Resolved at runtime from $TEAMBITION_ORGANIZATION_ID if not set here.
  organization_id: $TEAMBITION_ORGANIZATION_ID
  # Endpoint defaults to https://open.teambition.com/api when kind is teambition.
  active_states:
    - 待处理
    - 进行中
    - 复审
    - 待合并
  terminal_states:
    - 已完成
    - 已关闭
    - 已取消
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/<your-org>/<your-repo> .
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 5
  max_turns: 20
codex:
  command: codex --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on a Teambition task `{{ issue.identifier }}` (id `{{ issue.id }}`).

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the task is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed.
- Do not end the turn while the task remains in an active state unless blocked by missing required permissions/secrets.
{% endif %}

Task context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Tracker tool: `teambition_api`

You can call Teambition Open API v3 directly through the `teambition_api` dynamic tool.

Examples:

- Read this task in full:
  `teambition_api({"path": "/v3/task/{{ issue.id }}", "method": "GET"})`
- Post a workpad comment:
  `teambition_api({"path": "/v3/task/{{ issue.id }}/comment", "method": "POST", "body": {"content": "..."}})`
- Move task status:
  `teambition_api({"path": "/v3/task/{{ issue.id }}/move-task-flow-status", "method": "POST", "body": {"tfsId": "<tfsId>"}})`

If you need a status `tfsId`, fetch the project's task flow statuses first:
  `teambition_api({"path": "/v3/taskFlowStatus?projectId=<projectId>", "method": "GET"})`

## Default posture

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets).
3. Final message must report completed actions and blockers only — no "next steps for user".
4. Operate only within the provided repository copy. Do not touch any other path.

## Status map (customize for your team's Teambition workflow)

- `待处理` -> queued; transition to `进行中` before active work.
- `进行中` -> implementation underway.
- `复审` -> PR is attached and validated; awaiting human approval.
- `待合并` -> approved; perform the `land` flow (do not call `gh pr merge` directly).
- `已完成` / `已关闭` / `已取消` -> terminal; no further action.
