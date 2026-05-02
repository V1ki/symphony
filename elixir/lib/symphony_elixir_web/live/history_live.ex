defmodule SymphonyElixirWeb.HistoryLive do
  @moduledoc """
  LiveView for historical Codex sessions launched by Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.SessionHistory
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:sessions, [])
     |> assign(:summary, nil)
     |> assign(:events, [])
     |> assign(:turns, [])
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"session_id" => session_id}, _uri, socket) do
    {:noreply, load_session(socket, session_id)}
  end

  def handle_params(params, _uri, socket) do
    query = Map.get(params, "q", "")
    {:noreply, load_sessions(assign(socket, :query, query))}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: history_path(query))}
  end

  @impl true
  def handle_info(:observability_updated, %{assigns: %{live_action: :index}} = socket) do
    {:noreply, load_sessions(socket)}
  end

  def handle_info(:observability_updated, socket), do: {:noreply, socket}

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <section class="dashboard-shell history-shell">
      <%= if @error do %>
        <section class="error-card">
          <h1 class="error-title">Session unavailable</h1>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% else %>
        <header class="hero-card history-hero">
          <div class="hero-grid">
            <div>
              <p class="eyebrow">Session History</p>
              <h1 class="hero-title history-title"><%= @summary.issue_identifier || @summary.session_id %></h1>
              <p class="hero-copy"><%= @summary.issue_title || "Untitled Symphony session" %></p>
              <div class="history-actions">
                <a class="subtle-link" href="/history">Back to history</a>
                <a :if={@summary.issue_url} class="subtle-link" href={@summary.issue_url} target="_blank" rel="noreferrer">
                  Open in Teambition
                </a>
              </div>
            </div>

            <div class="status-stack">
              <span class={state_badge_class(@summary.issue_state || session_state(@summary))}>
                <%= @summary.issue_state || session_state(@summary) %>
              </span>
            </div>
          </div>
        </header>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Duration</p>
            <p class="metric-value numeric"><%= format_duration(@summary.duration_ms) %></p>
            <p class="metric-detail">Started <%= format_datetime(@summary.started_at) %></p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Tokens</p>
            <p class="metric-value numeric"><%= format_int(@summary.token_usage.total) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@summary.token_usage.input) %> / Out <%= format_int(@summary.token_usage.output) %>
            </p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Cached input</p>
            <p class="metric-value numeric"><%= format_int(@summary.token_usage.cached_input) %></p>
            <p class="metric-detail numeric">
              Reasoning <%= format_int(@summary.token_usage.reasoning_output) %>
            </p>
          </article>
          <article class="metric-card">
            <p class="metric-label">Model</p>
            <p class="metric-value metric-value-compact"><%= @summary.model || "n/a" %></p>
            <p class="metric-detail"><%= @summary.model_provider || "n/a" %></p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Tool calls</h2>
              <p class="section-copy"><%= @summary.workspace || "n/a" %></p>
            </div>
          </div>
          <%= if @summary.tool_calls == [] do %>
            <p class="empty-state">No tool calls recorded.</p>
          <% else %>
            <div class="tool-chip-row">
              <span :for={tool <- @summary.tool_calls} class="tool-chip">
                <%= tool.name %> <strong><%= tool.count %></strong>
              </span>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Turn timeline</h2>
              <p class="section-copy"><%= length(@turns) %> turns, <%= length(@events) %> raw events loaded.</p>
            </div>
          </div>

          <div class="turn-list">
            <details :for={turn <- @turns} class="turn-card" open>
              <summary>
                <span><%= turn.label %></span>
                <span class="muted numeric"><%= length(turn.events) %> events</span>
              </summary>
              <div class="timeline">
                <article :for={event <- turn.events} class={event_class(event)}>
                  <div class="timeline-meta">
                    <span><%= event_label(event) %></span>
                    <span class="muted numeric"><%= format_datetime(event.timestamp) %></span>
                  </div>
                  <.event_view event={event} />
                </article>
              </div>
            </details>
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section class="dashboard-shell history-shell">
      <header class="hero-card history-hero">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Observability</p>
            <h1 class="hero-title history-title">Session History</h1>
            <p class="hero-copy">
              Completed and running Codex sessions launched by the Symphony orchestrator.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              History
            </span>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Sessions</h2>
            <p class="section-copy">Filtered to originator=symphony-orchestrator.</p>
          </div>
          <form phx-change="search" class="history-search">
            <input type="search" name="q" value={@query} placeholder="Search T-N or title" />
          </form>
        </div>

        <%= if @sessions == [] do %>
          <p class="empty-state">No matching sessions.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table history-table">
              <colgroup>
                <col style="width: 8rem;" />
                <col />
                <col style="width: 9rem;" />
                <col style="width: 8rem;" />
                <col style="width: 9rem;" />
                <col style="width: 13rem;" />
              </colgroup>
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Title</th>
                  <th>State</th>
                  <th>Duration</th>
                  <th>Tokens</th>
                  <th>Started</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={session <- @sessions}>
                  <td>
                    <a class="issue-id" href={"/history/#{session.session_id}"}>
                      <%= session.issue_identifier || session.session_id || "unknown" %>
                    </a>
                  </td>
                  <td>
                    <div class="detail-stack">
                      <span class="event-text"><%= session.issue_title || session.workspace || "Untitled session" %></span>
                      <span class="muted mono"><%= short_id(session.session_id) %></span>
                    </div>
                  </td>
                  <td>
                    <span class={state_badge_class(session.issue_state || session_state(session))}>
                      <%= session.issue_state || session_state(session) %>
                    </span>
                  </td>
                  <td class="numeric"><%= format_duration(session.duration_ms) %></td>
                  <td class="numeric"><%= format_int(session.token_usage.total) %></td>
                  <td class="numeric"><%= format_datetime(session.started_at) %></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp load_sessions(socket) do
    sessions =
      SessionHistory.list_sessions(
        originator: "symphony-orchestrator",
        limit: 100,
        query: socket.assigns.query
      )

    assign(socket, sessions: sessions, summary: nil, events: [], turns: [], error: nil)
  end

  defp load_session(socket, session_id) do
    with {:ok, summary} <- SessionHistory.summarize_session(session_id),
         {:ok, events} <- SessionHistory.get_session(session_id) do
      assign(socket,
        summary: summary,
        events: visible_events(events),
        turns: group_turns(visible_events(events)),
        error: nil
      )
    else
      {:error, reason} ->
        assign(socket, summary: nil, events: [], turns: [], error: inspect(reason))
    end
  end

  defp history_path(""), do: "/history"
  defp history_path(query), do: "/history?q=#{URI.encode_www_form(query)}"

  defp visible_events(events) do
    Enum.filter(events, fn
      %{type: "response_item", payload: %{"type" => "message", "role" => role}} when role in ["user", "assistant"] -> true
      %{type: "response_item", payload: %{"type" => "function_call"}} -> true
      %{type: "response_item", payload: %{"type" => "function_call_output"}} -> true
      %{type: "event_msg", payload: %{"type" => "token_count"}} -> true
      %{type: "turn_context"} -> true
      _ -> false
    end)
  end

  defp group_turns(events) do
    {turns, current} =
      Enum.reduce(events, {[], nil}, fn event, {turns, current} ->
        case event do
          %{type: "turn_context", payload: %{"turn_id" => turn_id}} ->
            current = current || %{id: "preamble", label: "Preamble", events: []}
            turns = if current.events == [], do: turns, else: [current | turns]
            {turns, %{id: turn_id, label: "Turn #{length(turns) + 1}", events: []}}

          _ ->
            current = current || %{id: "preamble", label: "Preamble", events: []}
            {turns, %{current | events: current.events ++ [event]}}
        end
      end)

    turns = if current && current.events != [], do: [current | turns], else: turns
    Enum.reverse(turns)
  end

  defp event_view(%{event: %{type: "response_item", payload: %{"type" => "message", "content" => content}}} = assigns) do
    assigns = assign(assigns, :text, message_text(content))

    ~H"""
    <div class="message-body"><%= @text %></div>
    """
  end

  defp event_view(%{event: %{type: "response_item", payload: %{"type" => "function_call"} = payload}} = assigns) do
    assigns = assign(assigns, :payload, payload)

    ~H"""
    <details class="payload-details">
      <summary><%= @payload["name"] || "function_call" %></summary>
      <pre class="code-panel"><%= @payload["arguments"] || inspect(@payload, pretty: true) %></pre>
    </details>
    """
  end

  defp event_view(%{event: %{type: "response_item", payload: %{"type" => "function_call_output"} = payload}} = assigns) do
    assigns = assign(assigns, :output, payload["output"] || inspect(payload, pretty: true))

    ~H"""
    <details class="payload-details">
      <summary>output</summary>
      <pre class="code-panel"><%= @output %></pre>
    </details>
    """
  end

  defp event_view(%{event: %{type: "event_msg", payload: %{"type" => "token_count"} = payload}} = assigns) do
    usage = token_usage(payload)
    cached_percent = percent(usage.cached_input, max(usage.input, 1))

    assigns =
      assigns
      |> assign(:usage, usage)
      |> assign(:cached_percent, cached_percent)

    ~H"""
    <div class="token-meter">
      <div class="token-meter-track">
        <span style={"width: #{@cached_percent}%"}></span>
      </div>
      <p class="metric-detail numeric">
        Last turn <%= format_int(@usage.total) %> tokens, cached input <%= @cached_percent %>%.
        Cumulative <%= format_int(@usage.cumulative_total) %> / cached <%= format_int(@usage.cumulative_cached) %>.
      </p>
    </div>
    """
  end

  defp event_view(%{event: event} = assigns) do
    assigns = assign(assigns, :payload, Map.get(event, :payload, %{}))

    ~H"""
    <pre class="code-panel"><%= inspect(@payload, pretty: true) %></pre>
    """
  end

  defp event_label(%{type: "response_item", payload: %{"type" => "message", "role" => role}}), do: role
  defp event_label(%{type: "response_item", payload: %{"type" => type, "name" => name}}), do: "#{type}: #{name}"
  defp event_label(%{type: "response_item", payload: %{"type" => type}}), do: type
  defp event_label(%{type: "event_msg", payload: %{"type" => type}}), do: type
  defp event_label(%{type: type}), do: type

  defp event_class(%{type: "response_item", payload: %{"type" => "message", "role" => "user"}}), do: "timeline-event timeline-user"
  defp event_class(%{type: "response_item", payload: %{"type" => "message", "role" => "assistant"}}), do: "timeline-event timeline-assistant"
  defp event_class(%{type: "response_item", payload: %{"type" => "function_call"}}), do: "timeline-event timeline-tool"
  defp event_class(%{type: "response_item", payload: %{"type" => "function_call_output"}}), do: "timeline-event timeline-output"
  defp event_class(_event), do: "timeline-event"

  defp message_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "input_text", "text" => text} -> text
      %{"type" => "output_text", "text" => text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n\n")
  end

  defp message_text(content) when is_binary(content), do: content
  defp message_text(_content), do: ""

  defp token_usage(%{"info" => info}) do
    last = usage_map(info["last_token_usage"] || info["total_token_usage"] || %{})
    cumulative = usage_map(info["total_token_usage"] || %{})

    last
    |> Map.put(:cumulative_total, cumulative.total)
    |> Map.put(:cumulative_cached, cumulative.cached_input)
  end

  defp token_usage(_payload) do
    %{total: 0, input: 0, cached_input: 0, cumulative_total: 0, cumulative_cached: 0}
  end

  defp usage_map(usage) do
    %{
      total: usage["total_tokens"] || 0,
      input: usage["input_tokens"] || 0,
      cached_input: usage["cached_input_tokens"] || 0
    }
  end

  defp percent(part, total) when is_integer(part) and is_integer(total) and total > 0 do
    round(part * 100 / total)
  end

  defp percent(_part, _total), do: 0

  defp session_state(%{running: true}), do: "running"
  defp session_state(_session), do: "done"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_datetime(_datetime), do: "n/a"

  defp format_duration(ms) when is_integer(ms) do
    seconds = div(max(ms, 0), 1_000)
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp format_duration(_ms), do: "n/a"

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp short_id(nil), do: "n/a"
  defp short_id(id) when byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id), do: id

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["done", "complete", "完成"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["running", "active"]) -> "#{base} state-badge-warning"
      String.contains?(normalized, ["error", "failed"]) -> "#{base} state-badge-danger"
      true -> base
    end
  end
end
