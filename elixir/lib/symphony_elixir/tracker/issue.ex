defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized tracker task representation used by the orchestrator.

  Adapter-agnostic: Teambition tasks normalize into this struct in
  `SymphonyElixir.Teambition.Client`. Field names follow tracker-agnostic naming used by prompt templates that reference
  `issue.identifier`, `issue.url`, etc.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil,
    start_date: nil,
    due_date: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          start_date: DateTime.t() | nil,
          due_date: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}), do: labels
end
