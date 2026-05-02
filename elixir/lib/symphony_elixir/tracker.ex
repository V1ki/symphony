defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.

  Symphony currently supports the Teambition Open API as the production
  tracker, plus an in-memory adapter for tests and local development.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: adapter().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: adapter().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: adapter().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: adapter().create_comment(issue_id, body)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name),
    do: adapter().update_issue_state(issue_id, state_name)

  @spec update_issue_dates(String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_dates(issue_id, opts) when is_binary(issue_id) and is_list(opts) do
    tracker_adapter = adapter()

    if function_exported?(tracker_adapter, :update_issue_dates, 2) do
      apply(tracker_adapter, :update_issue_dates, [issue_id, opts])
    else
      :ok
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Teambition.Adapter
    end
  end
end
