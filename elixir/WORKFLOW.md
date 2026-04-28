---
tracker:
  kind: teambition
  # Teambition project _id (from the project URL path /project/<projectId>)
  project_slug: "69f04713cfcd439e91aeb107"
  # Resolved at runtime from $TEAMBITION_ACCESS_TOKEN if left as the placeholder below.
  api_key: $TEAMBITION_ACCESS_TOKEN
  # Tenant header. Resolved at runtime from $TEAMBITION_ORGANIZATION_ID if not set here.
  organization_id: $TEAMBITION_ORGANIZATION_ID
  # Endpoint defaults to https://open.teambition.com/api when kind is teambition.
  # Status name strings support UTF-8. Comments here are kept ASCII because
  # the YAML pre-processor in Symphony's frontmatter parser is stricter than
  # YamlElixir itself when scanning lines outside quoted scalars.
  # This project has two flows; we list states from both as candidates.
  active_states:
    - "未完成"
    - "待评审"
    - "评审中"
    - "执行中"
  terminal_states:
    - "已完成"
    - "已通过"
    - "未通过"
    - "废弃"
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Teambition task `{{ issue.identifier }}` (id `{{ issue.id }}`).

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the task is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the task remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the task according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: `teambition_api` tool is available

Symphony injects a client-side `teambition_api` tool into the Codex app-server session.
Use it for any Teambition Open API v3 call. Verified endpoint examples:

- Read this task in full (`/v3/task/query` returns `result[]`):
  `teambition_api({"path": "/v3/task/query?taskId={{ issue.id }}", "method": "GET"})`
- List task flow statuses available on this task:
  `teambition_api({"path": "/v3/task/{{ issue.id }}/tfs", "method": "GET"})`
- Post a workpad comment:
  `teambition_api({"path": "/v3/task/{{ issue.id }}/comment", "method": "POST", "body": {"content": "...", "renderMode": "markdown"}})`
- Move task status (PUT, not POST):
  `teambition_api({"path": "/v3/task/{{ issue.id }}/taskflowstatus", "method": "PUT", "body": {"taskflowstatusId": "<tfsId>", "tfsName": "<status name>"}})`
- Search project task flow statuses (when you need the full list, e.g. when
  building a status map):
  `teambition_api({"path": "/v3/project/<projectId>/taskflowstatus/search", "method": "GET"})`
- Search tasks across the project (TQL syntax):
  `teambition_api({"path": "/v3/project/<projectId>/task/query?q=isDone%20%3D%20false", "method": "GET"})`

## Default posture

- Start by determining the task's current status, then follow the matching flow.
- Treat a single persistent Teambition comment as the source of truth for progress (a "workpad" comment).
- Keep task metadata current (status, checklist, acceptance criteria, links).
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.

## Status map (this project)

简单流（未完成 -> 已完成）：

- `未完成` -> queued; the agent should pick this up, do the work, then move to `已完成`.
- `已完成` -> terminal.

评审流（待评审 -> 评审中 / 执行中 / 阻塞 -> 已通过 / 未通过 / 废弃）：

- `待评审` -> queued for review; the agent investigates and either moves to `执行中` (start work)
  or `评审中` (gather more info).
- `评审中` -> review in progress; the agent gathers context and posts findings.
- `执行中` -> implementation actively underway.
- `阻塞` -> blocked; record blocker in the workpad and stop until unblocked.
- `已通过` / `未通过` / `废弃` -> terminal.
