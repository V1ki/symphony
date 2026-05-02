defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.RepoSettings
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec repos(Conn.t(), map()) :: Conn.t()
  def repos(conn, _params) do
    json(conn, Presenter.repo_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec set_default_repo(Conn.t(), map()) :: Conn.t()
  def set_default_repo(conn, params) do
    repo_url = params["repo_url"] || params["url"] || params["default_repo_url"]
    normalized = RepoSettings.put_default_repo_url(repo_url)

    json(conn, %{
      default_repo_url: normalized,
      recent_repos: RepoSettings.recent_repos()
    })
  end

  @spec set_issue_repo(Conn.t(), map()) :: Conn.t()
  def set_issue_repo(conn, %{"issue_identifier" => issue_identifier} = params) do
    repo_url = params["repo_url"] || params["url"]
    normalized = RepoSettings.put_issue_override(issue_identifier, repo_url)

    json(conn, %{
      issue_identifier: issue_identifier,
      repo_url: normalized,
      override_repo_url: RepoSettings.issue_override(issue_identifier),
      recent_repos: RepoSettings.recent_repos()
    })
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
