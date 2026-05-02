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
  interval_ms: 10000
workspace:
  root: ~/symphony-workspaces
hooks:
  # Mirror the local Symphony fork into each workspace so Codex sees the *current*
  # source code (including uncommitted changes), instead of cloning a public fork.
  # rsync excludes deps/build artifacts and the `tools/` dir which carries secrets.
  after_create: |
    if [ -n "$ISSUE_REPO_URL" ]; then
      git clone --depth 1 "$ISSUE_REPO_URL" .
    else
      SRC="/Users/v1ki/Documents/projs/source/symphony"
      if [ ! -d "$SRC/elixir" ]; then
        echo "[after_create] source dir $SRC missing" >&2
        exit 1
      fi
      rsync -a --delete \
        --exclude '.git/' \
        --exclude '_build/' \
        --exclude 'deps/' \
        --exclude 'node_modules/' \
        --exclude 'tools/' \
        --exclude '.elixir_ls/' \
        --exclude '.DS_Store' \
        "$SRC/" .
    fi
    # Mark this checkout for the agent so it knows the layout.
    cat > AGENT_README.md <<'EOF'
    This workspace is a snapshot of `~/Documents/projs/source/symphony`
    (the V1ki fork of openai/symphony) at dispatch time. The Elixir project lives
    in `./elixir/`. Use `cd elixir && mix compile && mix test` to verify changes.
    Do not commit; this is an ephemeral workspace.
    EOF
agent:
  max_concurrent_agents: 1
  max_turns: 5
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots:
      - "/Users/v1ki/symphony-workspaces"
    readOnlyAccess:
      type: fullAccess
    networkAccess: true
    excludeTmpdirEnvVar: false
    excludeSlashTmp: false
  # 默认 5s 太短：codex app-server 冷启动 + 第一轮模型响应通常 30-90s
  read_timeout_ms: 180000
server:
  # macOS 5000 被 AirPlay Receiver 占用，4000 / 8080 经常被其它进程抢；5050 实测干净
  port: 5050
  host: "127.0.0.1"
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

## 时间精确化（兜底）

Symphony 框架会在 dispatch 时和你完成任务时分别写入 `startDate` / `dueDate`。
如果你看到任务的 startDate 或 dueDate 仍为 null（通过 teambition_api GET 任务可见），
请用以下接口补齐：

- 开始时间：teambition_api({"path": "/v3/task/{{ issue.id }}/startdate", "method": "PUT", "body": {"startDate": "<UTC ISO 8601>"}})
- 结束时间（完成任务流转之前的最后一步）：teambition_api({"path": "/v3/task/{{ issue.id }}/duedate", "method": "PUT", "body": {"dueDate": "<UTC ISO 8601>"}})

UTC ISO 8601 格式举例："2026-05-01T08:32:24.940Z"。一般框架已经写好，这一步只是兜底。

## Per-issue repo override

任务 description 第一行可以写 `Repo: <git url>` 或 yaml frontmatter `repo: <git url>`，
Symphony 会用这个仓库作为本任务的 workspace 源（覆盖全局默认）。
不写则用项目默认或全局默认。

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
