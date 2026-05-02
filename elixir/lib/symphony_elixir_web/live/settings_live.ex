defmodule SymphonyElixirWeb.SettingsLive do
  @moduledoc """
  Runtime settings for repository URL selection.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.RepoSettings
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:saved?, false)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload())}
  end

  @impl true
  def handle_event("save_default", %{"repo" => %{"url" => repo_url}}, socket) do
    RepoSettings.put_default_repo_url(repo_url)
    {:noreply, socket |> assign(:payload, load_payload()) |> assign(:saved?, true)}
  end

  def handle_event("use_recent", %{"url" => repo_url}, socket) do
    RepoSettings.put_default_repo_url(repo_url)
    {:noreply, socket |> assign(:payload, load_payload()) |> assign(:saved?, true)}
  end

  def handle_event("override_issue", %{"issue" => %{"identifier" => identifier, "url" => repo_url}}, socket) do
    RepoSettings.put_issue_override(identifier, repo_url)
    {:noreply, socket |> assign(:payload, load_payload()) |> assign(:saved?, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell history-shell settings-shell">
      <header class="hero-card history-hero">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Runtime Settings</p>
            <h1 class="hero-title history-title">Repository Sources</h1>
            <p class="hero-copy">In-memory defaults and per-issue repository overrides for this running Symphony process.</p>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Project default repo url</h2>
            <p class="section-copy">Stored in application memory for the active process.</p>
          </div>
          <span :if={@saved?} class="status-badge status-badge-live">
            <span class="status-badge-dot"></span>
            Saved
          </span>
        </div>

        <form phx-submit="save_default" class="settings-form">
          <input
            type="text"
            name="repo[url]"
            value={@payload.default_repo_url || ""}
            placeholder="git@github.com:owner/repo.git"
          />
          <button type="submit" class="subtle-button">Save</button>
        </form>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Recent repos</h2>
            <p class="section-copy">The latest repository URLs used by default or issue overrides.</p>
          </div>
        </div>

        <%= if @payload.recent_repos == [] do %>
          <p class="empty-state">No recent repos.</p>
        <% else %>
          <div class="repo-list">
            <div :for={repo_url <- @payload.recent_repos} class="repo-row">
              <code><%= repo_url %></code>
              <button type="button" class="subtle-button" phx-click="use_recent" phx-value-url={repo_url}>
                Use as default
              </button>
            </div>
          </div>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Override per active issue</h2>
            <p class="section-copy">Temporary issue-level repo URLs take priority at dispatch.</p>
          </div>
        </div>

        <%= if @payload.issues == [] do %>
          <p class="empty-state">No active issues.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table settings-table">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Status</th>
                  <th>Repo URL</th>
                  <th>Override</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={issue <- @payload.issues}>
                  <td><span class="issue-id"><%= issue.issue_identifier %></span></td>
                  <td><%= issue.status %></td>
                  <td><code><%= issue.repo_url || "n/a" %></code></td>
                  <td>
                    <form phx-submit="override_issue" class="settings-inline-form">
                      <input type="hidden" name="issue[identifier]" value={issue.issue_identifier} />
                      <input
                        type="text"
                        name="issue[url]"
                        value={issue.override_repo_url || issue.configured_repo_url || ""}
                        placeholder="git@github.com:owner/repo.git"
                      />
                      <button type="submit" class="subtle-button">Save</button>
                    </form>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp load_payload do
    Presenter.repo_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
