defmodule SymphonyElixir.Teambition.Client do
  @moduledoc """
  Thin Teambition Open API v3 client.

  Endpoints used here follow Teambition's official Open API documentation
  (https://open.teambition.com/docs). They are RESTful, authenticated with
  an OAuth `access_token` plus an organization tenant id (`X-Tenant-Id` header).

  ## Required configuration (read from `Config.settings!().tracker`)

    * `:api_key`             - OAuth `access_token` (resolved from `TEAMBITION_ACCESS_TOKEN`)
    * `:project_slug`        - Reused field; carries Teambition `projectId`
    * `:endpoint`            - Defaults to `https://open.teambition.com/api`
    * `:organization_id`     - Tenant id (header `X-Tenant-Id`)
    * `:active_states`       - State names (e.g. ["待处理", "进行中"])

  ## Endpoint conventions referenced below

  Teambition Open API v3 uses paths under `/v3/...`. The exact paths are
  marked with TODO comments where they MUST be confirmed against the official
  docs before going live; the client fails loudly on unexpected status codes
  instead of silently sending bad requests.
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
  # Internal: tracker behaviour helpers
  # ---------------------------------------------------------------------------

  defp do_fetch_by_states(project_id, state_names) do
    with {:ok, status_index} <- resolve_status_index(project_id),
         wanted_status_ids = filter_status_ids(status_index, state_names),
         {:ok, tasks} <- fetch_tasks_for_project(project_id, wanted_status_ids) do
      {:ok, Enum.map(tasks, &normalize_task(&1, status_index))}
    end
  end

  defp do_fetch_by_ids(ids) do
    # TODO(teambition): batch endpoint may differ; if not available, iterate.
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case request("/v3/task/#{id}", :get) do
        {:ok, %{"result" => task}} ->
          {:cont, {:ok, [normalize_task(task, %{}) | acc]}}

        {:ok, task} when is_map(task) ->
          {:cont, {:ok, [normalize_task(task, %{}) | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  # TODO(teambition): confirm exact path. Two known shapes in the wild:
  #   * `GET /v3/task?projectId=...&tfsIds=...&isArchived=false&pageSize=50&pageToken=...`
  #   * `POST /v3/task/search` with body filter
  # Until verified, default to GET with query params; switch by config if needed.
  defp fetch_tasks_for_project(project_id, status_ids) do
    qs = build_query(%{
      projectId: project_id,
      tfsIds: Enum.join(status_ids, ","),
      pageSize: @page_size,
      isArchived: false,
      isDone: false
    })

    case request("/v3/task#{qs}", :get) do
      {:ok, %{"result" => list}} when is_list(list) -> {:ok, list}
      {:ok, %{"data" => list}} when is_list(list) -> {:ok, list}
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, {:teambition_unexpected_payload, other}}
      err -> err
    end
  end

  defp resolve_status_index(project_id) do
    # TODO(teambition): real path is `/v3/taskFlowStatus?projectId=...`
    # or via `/v3/project/{id}/task-flow-status`. Confirm with docs.
    case request("/v3/taskFlowStatus?projectId=#{project_id}", :get) do
      {:ok, %{"result" => list}} when is_list(list) -> {:ok, build_status_index(list)}
      {:ok, list} when is_list(list) -> {:ok, build_status_index(list)}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, {:teambition_status_lookup_failed, reason}}
    end
  end

  defp build_status_index(list) do
    Enum.reduce(list, %{}, fn s, acc ->
      id = s["_id"] || s["id"]
      name = s["name"]
      if is_binary(id) and is_binary(name), do: Map.put(acc, id, name), else: acc
    end)
  end

  defp filter_status_ids(status_index, state_names) do
    wanted = state_names |> Enum.map(&String.downcase/1) |> MapSet.new()

    status_index
    |> Enum.filter(fn {_id, name} ->
      MapSet.member?(wanted, String.downcase(name))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # ---------------------------------------------------------------------------
  # Normalization: Teambition task -> Symphony's Issue struct
  # ---------------------------------------------------------------------------

  defp normalize_task(task, status_index) when is_map(task) do
    id = task["_id"] || task["id"]
    tfs_id = task["tfsId"]
    state_name = Map.get(status_index, tfs_id) || get_in(task, ["taskFlowStatus", "name"])

    %Issue{
      id: id,
      identifier: task["uniqueId"] || id,
      title: task["content"] || task["title"],
      description: task["note"] || task["description"],
      priority: parse_priority(task["priority"]),
      state: state_name,
      branch_name: nil,
      url: task["objectlink"] || build_url(task),
      assignee_id: task["executorId"],
      blocked_by: [],
      labels: extract_tag_names(task),
      assigned_to_worker: true,
      created_at: parse_dt(task["created"] || task["createdAt"]),
      updated_at: parse_dt(task["updated"] || task["updatedAt"])
    }
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

  defp extract_tag_names(task) do
    case task["tags"] do
      list when is_list(list) ->
        list |> Enum.map(&(&1["name"] || &1)) |> Enum.filter(&is_binary/1) |> Enum.map(&String.downcase/1)

      _ ->
        case task["tagIds"] do
          ids when is_list(ids) -> Enum.map(ids, &to_string/1)
          _ -> []
        end
    end
  end

  defp build_url(%{"_organizationId" => org, "_projectId" => proj, "_id" => id}) do
    "https://www.teambition.com/organization/#{org}/project/#{proj}/works/#{id}"
  end

  defp build_url(_), do: nil

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
      |> Enum.map(fn {k, v} -> "#{URI.encode(to_string(k))}=#{URI.encode(to_string(v))}" end)
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
          {"Accept", "application/json"}
        ]

        headers =
          case Map.get(tracker, :organization_id) do
            org when is_binary(org) and org != "" -> [{"X-Tenant-Id", org} | base]
            _ -> base
          end

        {:ok, headers}
    end
  end

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
