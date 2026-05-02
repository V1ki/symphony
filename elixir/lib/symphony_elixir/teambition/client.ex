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
  alias SymphonyElixir.{Config, Tracker.Issue}

  @page_size 50

  # ---------------------------------------------------------------------------
  # Public API expected by SymphonyElixir.Teambition.Adapter
  # ---------------------------------------------------------------------------

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_teambition_access_token}
      is_nil(tracker.project_slug) -> {:error, :missing_teambition_project_id}
      true -> do_fetch_by_states(tracker.project_slug, tracker.active_states)
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
      uniq -> do_fetch_by_ids(uniq)
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

  defp do_fetch_by_states(project_id, state_names) do
    with {:ok, status_index} <- resolve_status_index(project_id),
         tfs_ids = filter_tfs_ids(status_index, state_names),
         {:ok, tasks} <- fetch_project_tasks(project_id, tfs_ids) do
      {:ok, Enum.map(tasks, &normalize_task(&1, status_index))}
    end
  end

  defp do_fetch_by_ids(ids) do
    {task_ids, unique_ids} = split_task_and_unique_ids(ids)

    with {:ok, by_id} <- batch_fetch_tasks(task_ids),
         {:ok, by_unique} <- fetch_tasks_by_unique_ids(unique_ids) do
      tasks = by_id ++ by_unique

      with {:ok, status_index} <- status_index_for_tasks(tasks) do
        {:ok, Enum.map(tasks, &normalize_task(&1, status_index))}
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

  defp normalize_task(task, status_index) when is_map(task) do
    id = task["id"] || task["_id"]
    tfs_id = task["tfsId"] || task["taskflowstatusId"]

    state_name =
      Map.get(status_index, tfs_id) || get_in(task, ["taskflowstatus", "name"]) ||
        get_in(task, ["tfs", "name"])

    %Issue{
      id: id,
      identifier: build_identifier(task),
      title: task["content"] || task["title"],
      description: task["note"] || task["description"],
      priority: parse_priority(task["priority"]),
      state: state_name,
      branch_name: nil,
      url: build_url(task),
      assignee_id: task["executorId"],
      blocked_by: [],
      labels: extract_tag_ids(task),
      assigned_to_worker: assigned_to_worker?(task),
      created_at: parse_dt(task["created"] || task["createdAt"]),
      updated_at: parse_dt(task["updated"] || task["updatedAt"]),
      start_date: parse_dt(task["startDate"]),
      due_date: parse_dt(task["dueDate"])
    }
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
