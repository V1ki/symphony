# Symphony × Teambition 快速上手

## 一、前置条件清单

✅ 你已经有的：
- Teambition 企业账号
- 一个项目（任意一个，建议先建一个测试项目）
- 本机已装：Elixir 1.19 / OTP 28、`codex` CLI（`/Users/v1ki/.nvm/...`）
- 本仓库 fork 已 clone 在 `~/Documents/projs/source/symphony`，分支 `feat/teambition-tracker`

❌ 你需要去 Teambition 弄到的（**关键，缺一不可**）：
1. **AppId / AppSecret**（在 Teambition 开放平台创建一个企业内应用得来）
2. **OrganizationId / X-Tenant-Id**（你的企业 ID）
3. **ProjectId**（要让 agent 干活的那个项目）
4. **OperatorId / UserId**（你自己的 Teambition userId）

## 二、获取 Teambition 凭证（10 分钟）

### Step 1. 创建企业内应用

打开 https://open.teambition.com/app → 创建企业内应用

应用配置时**必须勾选**这四个 API 权限：

| 权限码 | 用途 |
|---|---|
| `tb-core:task:list` | 拉候选任务列表 |
| `tb-core:task:get` | 查任务详情 |
| `tb-core:task:update` | 改任务状态 + 评论 |
| `tb-core:project.taskflowstatus:list` | 查项目的工作流状态 |

发布版本 → 让企业管理员审核安装到企业。**不安装等于零权限。**

### Step 2. 找到 OrganizationId

进入 Teambition 企业管理后台，URL 形如：
```
https://www.teambition.com/organizations/<orgId>
```
中间这串就是 `X-Tenant-Id`。

### Step 3. 找到 ProjectId

进入要被 agent 处理的项目，URL 形如：
```
https://www.teambition.com/project/<projectId>/...
```

### Step 4. 找到自己的 UserId

最快的办法：装好应用后跑一次 `appToken` 接口，再用 token 调一次"获取自己信息"接口。或者直接在浏览器开发者工具里看 XHR 请求，header 里通常有。

### Step 5. 用 AppId/Secret 换 access_token

Teambition 的 access_token **会过期**（一般 1 小时左右），需要写个小脚本动态刷新：

```bash
curl -X POST https://open.teambition.com/api/appToken \
  -H 'Content-Type: application/json' \
  -d '{"appId":"<APP_ID>","appSecret":"<APP_SECRET>"}'
```

返回：
```json
{
  "result": {
    "appToken": "eyJ0eXAi...",
    "expire": 3600
  }
}
```

把 `result.appToken` 当成 `TEAMBITION_ACCESS_TOKEN` 用。

⚠️ **注意**：Symphony 当前实现是把 token 放在 `tracker.api_key`，过期后**不会自动续签**。短期测试 OK，长期跑要在 hooks 里加自动刷新。

## 三、准备工作流状态名

Teambition 默认任务流转状态可能是中文（"待处理"/"进行中"/"已完成"）。**Symphony 的 YAML 解析器只认 ASCII**，所以必须：

**方案 A（推荐）**：在 Teambition 项目设置 → 任务流 里加几个英文别名状态：
- `Todo` / `In Progress` / `Review` / `Merging` / `Done` / `Closed` / `Cancelled`

**方案 B（绕过）**：直接改 `WORKFLOW.md` 里的状态名匹配原本的英文状态。本仓库默认的 `WORKFLOW.md` 已经是英文，对应 Teambition 默认英文流转节点（Todo / In Progress / Done）应该可直接用。

确认你项目里的状态名后，把 `elixir/WORKFLOW.md` 里这两段改成你实际用的状态名：
```yaml
active_states:
  - Todo
  - In Progress
  - Review
  - Merging
terminal_states:
  - Done
  - Closed
  - Cancelled
```

## 四、第一次启动（local 模式）

```bash
cd ~/Documents/projs/source/symphony/elixir

# 1. 改 WORKFLOW.md，填上你的 projectId
#    project_slug: "<你的 projectId>"

# 2. 设置环境变量
export TEAMBITION_ACCESS_TOKEN="<上面拿到的 appToken>"
export TEAMBITION_ORGANIZATION_ID="<orgId>"
export TEAMBITION_ASSIGNEE="<你的 userId>"   # 可选，但配上 agent 才会被 task.executorId 路由

# 3. 编译 + 启动
mix deps.get
mix compile
mix escript.build

# 4. 起 Symphony（必须显式承诺自己懂得这是无人值守模式）
./bin/symphony \
  --i_understand_that_this_will_be_running_without_the_usual_guardrails \
  ./WORKFLOW.md
```

## 五、第一个测试任务（只读冒烟）

在 Teambition 项目里**新建一个任务**：
- 标题：`让 Symphony 第一次握手`
- 状态：`Todo`（或者你 active_states 列表里第一个）
- 描述：`只是测试 Symphony 能不能拉到我`
- 不要指派给任何人（或指派给你自己）

启动 Symphony 后，30 秒内应该看到日志里出现：
```
fetching candidate issues ...
got 1 candidate
dispatching <task-id>
```

如果你看到 401/403：access_token 过期或权限没装好。
如果看到 `:state_not_found` / `:teambition_state_lookup_failed`：状态名 / projectId 配错了。
如果看到 `cannot fetch`：endpoint 不通，先 curl 验证：

```bash
# 手工验证 token + 权限
curl -i "https://open.teambition.com/api/v3/project/$YOUR_PROJECT_ID/taskflowstatus/search" \
  -H "Authorization: Bearer $TEAMBITION_ACCESS_TOKEN" \
  -H "X-Tenant-Id: $TEAMBITION_ORGANIZATION_ID" \
  -H "X-Tenant-Type: organization" \
  -H "x-operator-id: $TEAMBITION_ASSIGNEE"
```
正常应该返回 `{"result":[...status list...]}`。

## 六、第一个真实跑通的任务

冒烟过了之后，再建一个能让 agent 实操的任务：

- 标题：`在 README 末尾加一行 hello from teambition agent`
- 状态：`Todo`
- 描述：包含完整需求、验收标准、要操作的仓库 URL

⚠️ Symphony 默认在 `~/code/symphony-workspaces/<task-id>` 下创建工作目录，并执行 `WORKFLOW.md` 里的 `hooks.after_create`（默认是 `git clone openai/symphony`，你得改成你自己想让 agent 操作的仓库）。

## 七、监控 / 调试

- **状态 dashboard**：访问 `http://127.0.0.1:4000/`（或你 `--port` 指定的端口）
- **日志**：默认输出到 stdout；可以 `--logs-root /path/to/logs` 落盘
- **token 用量 / agent runtime**：dashboard 实时刷新

## 八、不要踩的坑

| 坑 | 现象 | 解决 |
|---|---|---|
| token 过期 | 跑半小时后开始 401 | 写个脚本每 50 分钟刷一次，更新 env |
| 状态名中文 | YAML 解析报 `invalid_unicode at byte 523` | 状态名改 ASCII，或在 Teambition 加英文别名 |
| 应用没装到企业 | `code:401` / `企业未安装应用` | 让企业管理员去后台审核安装 |
| 权限不全 | 单个 API 返回 `code:403` | 编辑应用 → 加权限 → **重新发版** → 重新审核 |
| 状态 ID 不匹配 | `:state_not_found` | 状态名拼写要和 Teambition 项目里**一字不差** |
| projectId 写错 | `:teambition_status_lookup_failed` | 仔细从 URL 复制，不要把 orgId 和 projectId 弄混 |
| TQL 拒绝 | `code:400` body 含 `tql` | 检查日志里 q= 参数，可能是状态 IN 列表为空 |

## 九、最小可验证目标

跑一遍这三件事就算端到端通了：

1. ✅ Symphony 启动后 30 秒内打印 "fetched 1 candidate"
2. ✅ 在 Teambition 任务下出现一条由应用身份发出的评论
3. ✅ Teambition 任务状态从 Todo 自动流转到下一个状态

做到 1 已经证明 endpoint + auth + 权限 全对了。
做到 2 证明写路径 OK。
做到 3 证明 update_issue_state 链路全部贯通。

之后才适合让真实 agent 跑真实代码任务。
