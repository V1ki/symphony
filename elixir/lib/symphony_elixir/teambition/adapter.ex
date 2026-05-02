defmodule SymphonyElixir.Teambition.Adapter do
  @moduledoc """
  Teambition-backed tracker adapter.

  Implements the `SymphonyElixir.Tracker` behaviour using verified Teambition
  Open API v3 endpoints (see `SymphonyElixir.Teambition.Client` for the full
  list of paths used).
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Teambition.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(ids), do: client_module().fetch_issue_states_by_ids(ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(task_id, body) when is_binary(task_id) and is_binary(body) do
    # POST /v3/task/{taskId}/comment
    # body: {content, renderMode?, fileTokens?, mentionUserIds?}
    case client_module().request("/v3/task/#{task_id}/comment", :post, %{content: body}) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(task_id, state_name)
      when is_binary(task_id) and is_binary(state_name) do
    with {:ok, tfs_id} <- resolve_tfs_id(task_id, state_name),
         {:ok, _} <-
           client_module().request("/v3/task/#{task_id}/taskflowstatus", :put, %{
             taskflowstatusId: tfs_id,
             tfsName: state_name
           }) do
      :ok
    end
  end

  @spec update_issue_dates(String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_dates(task_id, opts) when is_binary(task_id) and is_list(opts) do
    with :ok <- maybe_put_date(task_id, "startdate", Keyword.get(opts, :start_date)),
         :ok <- maybe_put_date(task_id, "duedate", Keyword.get(opts, :due_date)) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_put_date(_task_id, _kind, nil), do: :ok

  defp maybe_put_date(task_id, kind, %DateTime{} = dt) do
    iso = DateTime.to_iso8601(dt)

    body =
      case kind do
        "startdate" -> %{startDate: iso}
        "duedate" -> %{dueDate: iso}
      end

    case client_module().request("/v3/task/#{task_id}/#{kind}", :put, body) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # Use GET /v3/task/{taskId}/tfs to list the workflow statuses available for
  # this task's task flow, then match by name. This avoids needing to know the
  # task's projectId up front.
  defp resolve_tfs_id(task_id, state_name) do
    case client_module().request("/v3/task/#{task_id}/tfs", :get) do
      {:ok, %{"result" => list}} when is_list(list) -> match_status(list, state_name)
      {:ok, list} when is_list(list) -> match_status(list, state_name)
      {:ok, _} -> {:error, :teambition_state_lookup_failed}
      err -> err
    end
  end

  defp match_status(list, state_name) do
    wanted = String.downcase(state_name)

    Enum.find_value(list, {:error, :state_not_found}, fn s ->
      name = s["name"]
      id = s["id"] || s["_id"]

      if is_binary(name) and String.downcase(name) == wanted and is_binary(id) do
        {:ok, id}
      else
        nil
      end
    end)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :teambition_client_module, Client)
  end
end
