defmodule SymphonyElixir.Teambition.Client do
  @moduledoc """
  Thin Teambition Open API v3 client.

  Endpoints used here are verified against Teambition's official Open API
  documentation (https://open.teambition.com/docs). They are RESTful,
  authenticated with an OAuth `app_access_token` plus an organization tenant
  id (`X-Tenant-Id` header) and `X-Tenant-Type: organization`.

  ## Required configuration (read from `Config.settings!().tracker`)

    * `:api_key`             - OAuth `app_access_token` (resolved from `TEAMBITION_ACCESS_TOKEN`)
    * `:project_slug`        - Reused field; carries Teambition `projectId`
    * `:endpoint`            - Defaults to `https://open.teambition.com/api`
    * `:organization_id`     - Tenant id (resolved from `TEAMBITION_ORGANIZATION_ID`)
    * `:assignee`            - Optional `x-operator-id` (a Teambition userId)
    * `:active_states`       - Status names (matched against the project's task flow statuses)

  ## Verified endpoints

    * `GET /v3/project/{projectId}/task/query?q=<TQL>&pageSize=&pageToken=`
      Project task search with TQL. Returns full task objects in `result[]`.
    * `GET /v3/task/query?taskId=id1,id2,...`
      Batch task lookup. Returns `result[]` (always an array).
    * `GET /v3/project/{projectId}/taskflowstatus/search?pageSize=`
      List task flow statuses for a project. Used to resolve status name -> id.
    * `POST /v3/task/{taskId}/comment` body: `{content, renderMode?, fileTokens?, mentionUserIds?}`
    * `PUT /v3/task/{taskId}/taskflowstatus` body: `{taskflowstatusId, tfsName?, tfsUpdateNote?}`
  """

  require Logger
  alias SymphonyElixir.{Config, RepoSettings, Tracker.Issue}

  @page_size 50
  @dependency_line_regex ~r/^\s*(?:Depends on|Blocked by|依赖任务|依赖)[:：]\s*(.+)$/iu
  @identifier_regex ~r/T-?(\d+)/i

  # ---------------------------------------------------------------------------
  # Public API expected by SymphonyElixir.Teambition.Adapter
  # ---------------------------------------------------------------------------

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_teambition_access_token}
      is_nil(tracker.project_slug) -> {:error, :missing_teambition_project_id}
      true -> do_fetch_by_states(tracker.project_slug, tracker.active_states, resolve_blockers: true)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      cond do
        is_nil(tracker.api_key) -> {:error, :missing_teambition_access_token}
        is_nil(tracker.project_slug) -> {:error, :missing_teambition_project_id}
        true -> do_fetch_by_states(tracker.project_slug, states)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(ids) when is_list(ids) do
    case Enum.uniq(ids) do
      [] -> {:ok, []}
      uniq -> do_fetch_by_ids(uniq, resolve_blockers: true)
    end
  end

  @doc """
  POST a generic Teambition Open API request. Used by both the adapter and
  the dynamic `teambition_api` tool exposed to the agent.

  `path` MUST start with `/`, `body` is a map JSON-encoded automatically.
  """
  @spec request(String.t(), atom(), map(), keyword()) ::
          {:ok, map() | list()} | {:error, term()}
  def request(path, method, body \\ %{}, opts \\ [])
      when is_binary(path) and method in [:get, :post, :put, :delete] do
    request_fun = Keyword.get(opts, :request_fun, &http_request/4)

    with {:ok, headers} <- auth_headers(),
         {:ok, %{status: status, body: resp_body}} <-
           request_fun.(method, full_url(path), headers, body),
         :ok <- check_status(status, path, resp_body) do
      {:ok, resp_body}
    else
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: fetch candidate / by-states (uses project task search + TQL)
  # ---------------------------------------------------------------------------

  @doc false
  @spec normalize_task_for_test(map(), map(), [map()]) :: Issue.t()
  def normalize_task_for_test(task, status_index, tasks) when is_map(task) and is_map(status_index) and is_list(tasks) do
    task_lookup = build_task_lookup(tasks, status_index)
    normalize_task(task, status_index, task_lookup)
  end

  defp do_fetch_by_states(project_id, state_names, opts \\ []) do
    with {:ok, status_index} <- resolve_status_index(project_id),
         tfs_ids = filter_tfs_ids(status_index, state_names),
         {:ok, tasks} <- fetch_project_tasks(project_id, tfs_ids) do
      issues = normalize_tasks(tasks, status_index)

      if Keyword.get(opts, :resolve_blockers, false) do
        resolve_issue_blockers(issues)
      else
        {:ok, issues}
      end
    end
  end

  defp do_fetch_by_ids(ids, opts) do
    {task_ids, unique_ids} = split_task_and_unique_ids(ids)

    with {:ok, by_id} <- batch_fetch_tasks(task_ids),
         {:ok, by_unique} <- fetch_tasks_by_unique_ids(unique_ids) do
      tasks = by_id ++ by_unique

      with {:ok, status_index} <- status_index_for_tasks(tasks) do
        issues = normalize_tasks(tasks, status_index)

        if Keyword.get(opts, :resolve_blockers, false) do
          resolve_issue_blockers(issues)
        else
          {:ok, issues}
        end
      end
    end
  end

  # Build a tfsId -> name map covering every project that the supplied tasks
  # belong to. We resolve project status lists once per project to keep this
  # call O(projects) rather than O(tasks).
  defp status_index_for_tasks(tasks) do
    project_ids =
      tasks
      |> Enum.map(fn t -> t["projectId"] || t["_projectId"] end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    Enum.reduce_while(project_ids, {:ok, %{}}, fn pid, {:ok, acc} ->
      case resolve_status_index(pid) do
        {:ok, idx} -> {:cont, {:ok, Map.merge(acc, idx)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # GET /v3/project/{projectId}/task/query?q=<TQL>&pageSize=&pageToken=
  defp fetch_project_tasks(_project_id, []), do: {:ok, []}

  defp fetch_project_tasks(project_id, tfs_ids) do
    tql = build_tql(tfs_ids)
    paginate("/v3/project/#{project_id}/task/query", %{q: tql, pageSize: @page_size}, [])
  end

  defp build_tql(tfs_ids) do
    quoted = tfs_ids |> Enum.map(&"#{&1}") |> Enum.join(", ")

    # Active tasks only: not done, not archived, in the configured statuses.
    "isDone = false AND isArchived = false AND taskflowstatusId IN (#{quoted}) ORDER BY priority DESC, created ASC"
  end

  # GET /v3/task/query?taskId=id1,id2 (batched in chunks of @page_size)
  defp batch_fetch_tasks([]), do: {:ok, []}

  defp batch_fetch_tasks(ids) do
    ids
    |> Enum.chunk_every(@page_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      qs = build_query(%{taskId: Enum.join(chunk, ",")})

      case request("/v3/task/query#{qs}", :get) do
        {:ok, %{"result" => list}} when is_list(list) -> {:cont, {:ok, acc ++ list}}
        {:ok, list} when is_list(list) -> {:cont, {:ok, acc ++ list}}
        {:ok, other} -> {:halt, {:error, {:teambition_unexpected_payload, other}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp fetch_tasks_by_unique_ids([]), do: {:ok, []}

  defp fetch_tasks_by_unique_ids(unique_ids) do
    tracker = Config.settings!().tracker

    if is_nil(tracker.project_slug) do
      {:ok, []}
    else
      unique_ids
      |> Enum.reduce_while({:ok, []}, fn unique_id, {:ok, acc} ->
        tql = "uniqueId = #{unique_id}"

        case paginate("/v3/project/#{tracker.project_slug}/task/query", %{q: tql, pageSize: @page_size}, []) do
          {:ok, list} -> {:cont, {:ok, acc ++ list}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp split_task_and_unique_ids(ids) do
    Enum.reduce(ids, {[], []}, fn id, {task_ids, unique_ids} ->
      normalized = normalize_lookup_id(id)

      cond do
        is_nil(normalized) ->
          {task_ids, unique_ids}

        Regex.match?(~r/^[0-9a-f]{24}$/i, normalized) ->
          {[normalized | task_ids], unique_ids}

        Regex.match?(~r/^\d+$/, normalized) ->
          {task_ids, [normalized | unique_ids]}

        true ->
          {[normalized | task_ids], unique_ids}
      end
    end)
    |> then(fn {task_ids, unique_ids} ->
      {Enum.reverse(task_ids), Enum.reverse(unique_ids)}
    end)
  end

  defp normalize_lookup_id(id) when is_binary(id) do
    id
    |> String.trim()
    |> case do
      "T-" <> number -> number
      "" -> nil
      other -> other
    end
  end

  defp normalize_lookup_id(_id), do: nil

  # GET /v3/project/{projectId}/taskflowstatus/search
  defp resolve_status_index(project_id) do
    case paginate("/v3/project/#{project_id}/taskflowstatus/search", %{pageSize: @page_size}, []) do
      {:ok, list} -> {:ok, build_status_index(list)}
      {:error, reason} -> {:error, {:teambition_status_lookup_failed, reason}}
    end
  end

  defp build_status_index(list) do
    Enum.reduce(list, %{}, fn s, acc ->
      id = s["id"] || s["_id"]
      name = s["name"]
      if is_binary(id) and is_binary(name), do: Map.put(acc, id, name), else: acc
    end)
  end

  defp filter_tfs_ids(status_index, state_names) do
    wanted = state_names |> Enum.map(&String.downcase/1) |> MapSet.new()

    status_index
    |> Enum.filter(fn {_id, name} -> MapSet.member?(wanted, String.downcase(name)) end)
    |> Enum.map(&elem(&1, 0))
  end

  # ---------------------------------------------------------------------------
  # Pagination helper using `nextPageToken`
  # ---------------------------------------------------------------------------

  defp paginate(path, params, acc) do
    qs = build_query(params)

    case request("#{path}#{qs}", :get) do
      {:ok, %{"result" => list, "nextPageToken" => token}} when is_list(list) ->
        merged = acc ++ list

        if is_binary(token) and token != "" do
          paginate(path, Map.put(params, :pageToken, token), merged)
        else
          {:ok, merged}
        end

      {:ok, %{"result" => list}} when is_list(list) ->
        {:ok, acc ++ list}

      {:ok, list} when is_list(list) ->
        {:ok, acc ++ list}

      {:ok, other} ->
        {:error, {:teambition_unexpected_payload, other}}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization: Teambition task -> Symphony's Issue struct
  # ---------------------------------------------------------------------------

  defp normalize_tasks(tasks, status_index) when is_list(tasks) and is_map(status_index) do
    task_lookup = build_task_lookup(tasks, status_index)
    Enum.map(tasks, &normalize_task(&1, status_index, task_lookup))
  end

  defp build_task_lookup(tasks, status_index) when is_list(tasks) and is_map(status_index) do
    Enum.reduce(tasks, %{}, fn task, acc ->
      identifier = build_identifier(task)
      id = task["id"] || task["_id"]

      if is_binary(identifier) and identifier != "" do
        Map.put(acc, identifier, %{
          id: id,
          identifier: identifier,
          state: task_state_name(task, status_index),
          parent_id: task_parent_id(task),
          pos: task_pos(task)
        })
      else
        acc
      end
    end)
  end

  defp normalize_task(task, status_index, task_lookup) when is_map(task) and is_map(task_lookup) do
    id = task["id"] || task["_id"]
    state_name = task_state_name(task, status_index)
    identifier = build_identifier(task)
    description = task["note"] || task["description"]

    %Issue{
      id: id,
      identifier: identifier,
      title: task["content"] || task["title"],
      description: description,
      priority: parse_priority(task["priority"]),
      state: state_name,
      branch_name: nil,
      url: build_url(task),
      repo_url: RepoSettings.resolve_repo_url(identifier, description),
      assignee_id: task["executorId"],
      blocked_by: extract_blockers(task, task_lookup),
      labels: extract_tag_ids(task),
      assigned_to_worker: assigned_to_worker?(task),
      created_at: parse_dt(task["created"] || task["createdAt"]),
      updated_at: parse_dt(task["updated"] || task["updatedAt"]),
      start_date: parse_dt(task["startDate"]),
      due_date: parse_dt(task["dueDate"])
    }
  end

  defp task_state_name(task, status_index) do
    tfs_id = task["tfsId"] || task["taskflowstatusId"]

    Map.get(status_index, tfs_id) || get_in(task, ["taskflowstatus", "name"]) ||
      get_in(task, ["tfs", "name"])
  end

  defp build_identifier(task) do
    case task["uniqueId"] do
      uid when is_integer(uid) -> "T-#{uid}"
      uid when is_binary(uid) and uid != "" -> uid
      _ -> task["id"] || task["_id"]
    end
  end

  defp parse_priority(p) when is_integer(p), do: p
  defp parse_priority(_), do: nil

  defp extract_blockers(task, task_lookup) when is_map(task) and is_map(task_lookup) do
    identifier = build_identifier(task)

    case explicit_dependency_identifiers(task) do
      {:explicit, identifiers} ->
        identifiers
        |> Enum.reject(&self_dependency?(&1, identifier))
        |> tap(fn blockers ->
          log_self_dependency_warning(identifier, identifiers, blockers)
        end)
        |> Enum.map(&blocker_from_identifier(&1, task_lookup))

      :none ->
        sibling_blockers(task, task_lookup)
    end
  end

  defp explicit_dependency_identifiers(task) do
    {seen_dependency_line?, identifiers} =
      (task["note"] || task["description"] || "")
      |> to_string()
      |> String.split(~r/\R/u)
      |> Enum.reduce({false, []}, fn line, {seen?, acc} ->
        case Regex.run(@dependency_line_regex, line) do
          [_, dependency_text] -> {true, acc ++ extract_dependency_identifiers(dependency_text)}
          _ -> {seen?, acc}
        end
      end)

    if seen_dependency_line? do
      {:explicit, Enum.uniq(identifiers)}
    else
      :none
    end
  end

  defp extract_dependency_identifiers(dependency_text) when is_binary(dependency_text) do
    @identifier_regex
    |> Regex.scan(dependency_text)
    |> Enum.map(fn [_, number] -> "T-#{number}" end)
  end

  defp self_dependency?(identifier, identifier), do: true
  defp self_dependency?(_blocker_identifier, _issue_identifier), do: false

  defp log_self_dependency_warning(issue_identifier, identifiers, blockers) do
    if length(identifiers) != length(blockers) do
      Logger.warning("Ignoring self dependency in Teambition task #{issue_identifier}")
    end
  end

  defp blocker_from_identifier(identifier, task_lookup) do
    task_lookup
    |> Map.get(identifier, %{identifier: identifier, id: nil, state: nil})
    |> blocker_map()
  end

  defp sibling_blockers(task, task_lookup) do
    parent_id = task_parent_id(task)
    pos = task_pos(task)
    identifier = build_identifier(task)

    if is_binary(parent_id) and is_number(pos) do
      task_lookup
      |> Map.values()
      |> Enum.filter(fn sibling ->
        sibling.parent_id == parent_id and is_number(sibling.pos) and sibling.pos < pos and
          sibling.identifier != identifier
      end)
      |> Enum.sort_by(&{&1.pos, &1.identifier})
      |> Enum.map(&blocker_map/1)
    else
      []
    end
  end

  defp task_parent_id(task) do
    task["_parentId"] || task["parentTaskId"] || task["parentId"] || last_ancestor_id(task["ancestorIds"])
  end

  defp last_ancestor_id(ancestor_ids) when is_list(ancestor_ids) do
    Enum.find(Enum.reverse(ancestor_ids), &is_binary/1)
  end

  defp last_ancestor_id(_ancestor_ids), do: nil

  defp task_pos(%{"pos" => pos}) when is_number(pos), do: pos

  defp task_pos(%{"pos" => pos}) when is_binary(pos) do
    case Float.parse(pos) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp task_pos(_task), do: nil

  defp resolve_issue_blockers(issues) when is_list(issues) do
    identifiers =
      issues
      |> Enum.flat_map(& &1.blocked_by)
      |> Enum.map(&Map.get(&1, :identifier))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with {:ok, tasks} <- fetch_tasks_by_unique_ids(identifiers),
         {:ok, status_index} <- status_index_for_tasks(tasks) do
      fetched_lookup = build_task_lookup(tasks, status_index)
      issue_lookup = build_issue_lookup(issues)
      lookup = Map.merge(issue_lookup, fetched_lookup)

      {:ok,
       Enum.map(issues, fn issue ->
         %{issue | blocked_by: Enum.map(issue.blocked_by, &resolve_blocker(&1, lookup))}
       end)}
    end
  end

  defp build_issue_lookup(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{id: id, identifier: identifier, state: state}, acc when is_binary(identifier) ->
        Map.put(acc, identifier, %{id: id, identifier: identifier, state: state})

      _issue, acc ->
        acc
    end)
  end

  defp resolve_blocker(%{identifier: identifier} = blocker, lookup) when is_binary(identifier) do
    case Map.get(lookup, identifier) do
      nil ->
        %{identifier: identifier, id: nil, state: "已废弃"}

      resolved ->
        resolved
        |> Map.merge(Map.take(blocker, [:identifier]))
        |> blocker_map()
    end
  end

  defp resolve_blocker(blocker, _lookup), do: blocker_map(blocker)

  defp blocker_map(%{id: id, identifier: identifier, state: state}) do
    %{id: id, identifier: identifier, state: state}
  end

  defp blocker_map(%{identifier: identifier}) do
    %{id: nil, identifier: identifier, state: nil}
  end

  defp parse_dt(nil), do: nil
  defp parse_dt(""), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp extract_tag_ids(task) do
    case task["tagIds"] do
      ids when is_list(ids) -> Enum.map(ids, &to_string/1)
      _ -> []
    end
  end

  defp build_url(%{"projectId" => proj, "id" => id}) when is_binary(proj) and is_binary(id) do
    "https://www.teambition.com/project/#{proj}/tasks/#{id}"
  end

  defp build_url(%{"_projectId" => proj, "_id" => id}) when is_binary(proj) and is_binary(id) do
    "https://www.teambition.com/project/#{proj}/tasks/#{id}"
  end

  defp build_url(_), do: nil

  defp assigned_to_worker?(task) do
    configured = Config.settings!().tracker.assignee

    case configured do
      nil ->
        true

      "" ->
        true

      operator when is_binary(operator) ->
        executor = task["executorId"]
        is_binary(executor) and executor == operator
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP plumbing
  # ---------------------------------------------------------------------------

  defp full_url("/" <> _ = path) do
    base =
      Config.settings!().tracker.endpoint
      |> case do
        nil -> "https://open.teambition.com/api"
        v -> String.trim_trailing(v, "/")
      end

    base <> path
  end

  defp build_query(params) do
    qs =
      params
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
      |> Enum.map(fn {k, v} -> "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}" end)
      |> Enum.join("&")

    if qs == "", do: "", else: "?" <> qs
  end

  defp auth_headers do
    tracker = Config.settings!().tracker

    case tracker.api_key do
      nil ->
        {:error, :missing_teambition_access_token}

      token ->
        base = [
          {"Authorization", "Bearer " <> token},
          {"Content-Type", "application/json"},
          {"Accept", "application/json"},
          # All Teambition Open API v3 calls require this header today; the
          # only documented value is "organization".
          {"X-Tenant-Type", "organization"}
        ]

        headers =
          base
          |> maybe_put_header("X-Tenant-Id", Map.get(tracker, :organization_id))
          |> maybe_put_header("x-operator-id", Map.get(tracker, :assignee))

        {:ok, headers}
    end
  end

  defp maybe_put_header(headers, _name, nil), do: headers
  defp maybe_put_header(headers, _name, ""), do: headers

  defp maybe_put_header(headers, name, value) when is_binary(value),
    do: [{name, value} | headers]

  defp http_request(:get, url, headers, _body) do
    Req.get(url, headers: headers, connect_options: [timeout: 30_000])
  end

  defp http_request(method, url, headers, body) when method in [:post, :put, :delete] do
    Req.request(
      method: method,
      url: url,
      headers: headers,
      json: body,
      connect_options: [timeout: 30_000]
    )
  end

  defp check_status(status, _path, _body) when status in 200..299, do: :ok

  defp check_status(status, path, body) do
    Logger.error("Teambition API #{path} failed status=#{status} body=#{inspect(body, limit: 8)}")
    {:error, {:teambition_api_status, status}}
  end
end
