defmodule SymphonyElixir.Teambition.Adapter do
  @moduledoc """
  Teambition-backed tracker adapter. Mirrors `SymphonyElixir.Teambition.Adapter`
  but speaks Teambition's REST Open API v3.
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
    # TODO(teambition): confirm endpoint shape against docs.
    # Likely: `POST /v3/activity` with body
    #   %{ "_boundToObjectId" => task_id, "boundToObjectType" => "task",
    #      "content" => body, "action" => "comment" }
    # or: `POST /v3/task/{id}/comment` with %{ "content" => body }
    case client_module().request("/v3/task/#{task_id}/comment", :post, %{content: body}) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(task_id, state_name)
      when is_binary(task_id) and is_binary(state_name) do
    with {:ok, project_id} <- fetch_project_id_for_task(task_id),
         {:ok, tfs_id} <- resolve_tfs_id(project_id, state_name),
         {:ok, _} <-
           client_module().request("/v3/task/#{task_id}/move-task-flow-status", :post, %{
             tfsId: tfs_id
           }) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fetch_project_id_for_task(task_id) do
    case client_module().request("/v3/task/#{task_id}", :get) do
      {:ok, %{"result" => %{"_projectId" => pid}}} when is_binary(pid) -> {:ok, pid}
      {:ok, %{"_projectId" => pid}} when is_binary(pid) -> {:ok, pid}
      {:ok, _} -> {:error, :teambition_task_missing_project}
      err -> err
    end
  end

  defp resolve_tfs_id(project_id, state_name) do
    # TODO(teambition): replace with the canonical taskflow status list endpoint.
    case client_module().request("/v3/taskFlowStatus?projectId=#{project_id}", :get) do
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
      id = s["_id"] || s["id"]

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
