defmodule SymphonyElixirWeb.HistoryLive do
  @moduledoc """
  LiveView for historical Codex sessions launched by Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias Phoenix.HTML
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
     |> assign(:sparkline, token_sparkline([]))
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
            <div class="token-sparkline" aria-label="Token usage by turn">
              <svg viewBox="0 0 160 42" role="img">
                <polyline :if={@sparkline.points != ""} points={@sparkline.points} />
              </svg>
            </div>
            <p class="metric-detail numeric">In <%= format_int(@summary.token_usage.input) %> / Out <%= format_int(@summary.token_usage.output) %></p>
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
              <p class="section-copy"><%= length(@turns) %> turns, <%= length(@events) %> readable events after pairing.</p>
            </div>
          </div>

          <div class="turn-list">
            <details :for={turn <- @turns} class="turn-card" open>
              <summary>
                <span><%= turn_summary_line(turn) %></span>
                <span class="muted numeric"><%= format_duration(turn.wall_ms) %></span>
              </summary>
              <div class="timeline">
                <article :for={event <- turn.events} class={event_class(event)}>
                  <div class="timeline-meta">
                    <span><%= event_label(event) %></span>
                    <span class="muted numeric"><%= format_datetime(event.timestamp) %></span>
                  </div>
                  <.event_view event={event} workspace={@summary.workspace} />
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

    assign(socket, sessions: sessions, summary: nil, events: [], turns: [], sparkline: token_sparkline([]), error: nil)
  end

  defp load_session(socket, session_id) do
    with {:ok, summary} <- SessionHistory.summarize_session(session_id),
         {:ok, events} <- SessionHistory.get_session(session_id) do
      events =
        events
        |> visible_events()
        |> SessionHistory.pair_calls_with_outputs()

      turns = group_turns(events, summary)

      assign(socket,
        summary: summary,
        events: events,
        turns: turns,
        sparkline: token_sparkline(turns),
        error: nil
      )
    else
      {:error, reason} ->
        assign(socket, summary: nil, events: [], turns: [], sparkline: token_sparkline([]), error: inspect(reason))
    end
  end

  defp history_path(""), do: "/history"
  defp history_path(query), do: "/history?q=#{URI.encode_www_form(query)}"

  defp visible_events(events) do
    Enum.filter(events, fn
      %{type: "response_item", payload: %{"type" => "message", "role" => role}} when role in ["user", "assistant"] -> true
      %{type: "response_item", payload: %{"type" => "reasoning"}} -> true
      %{type: "response_item", payload: %{"type" => "function_call"}} -> true
      %{type: "response_item", payload: %{"type" => "function_call_output"}} -> true
      %{type: "custom_tool_call"} -> true
      %{payload: %{"type" => "custom_tool_call"}} -> true
      %{type: "event_msg", payload: %{"type" => "token_count"}} -> true
      %{type: "turn_context"} -> true
      _ -> false
    end)
  end

  defp group_turns(events, summary) do
    {turns, current} =
      Enum.reduce(events, {[], nil}, fn event, {turns, current} ->
        case event do
          %{type: "turn_context", payload: %{"turn_id" => turn_id}} ->
            current = current || %{id: "preamble", label: "Preamble", events: []}
            turns = if current.events == [], do: turns, else: [summarize_turn(current, summary) | turns]
            {turns, %{id: turn_id, label: "Turn #{length(turns) + 1}", events: []}}

          _ ->
            current = current || %{id: "preamble", label: "Preamble", events: []}
            {turns, %{current | events: current.events ++ [event]}}
        end
      end)

    turns = if current && current.events != [], do: [summarize_turn(current, summary) | turns], else: turns
    Enum.reverse(turns)
  end

  defp event_view(%{event: %{type: "response_item", payload: %{"type" => "message", "role" => role, "content" => content}}} = assigns) do
    text = message_text(content)

    assigns =
      assigns
      |> assign(:role, role)
      |> assign(:text, text)
      |> assign(:markdown, markdown_html(text))

    ~H"""
    <div class={["message-card", "message-card-#{@role}"]}>
      <.copy_button text={@text} />
      <%= if @role == "user" and long_text?(@text) do %>
        <details class="long-text">
          <summary><span><%= text_preview(@text) %></span><b>Show more</b></summary>
          <div class="message-body markdown-body"><%= HTML.raw(@markdown) %></div>
        </details>
      <% else %>
        <div class="message-body markdown-body"><%= HTML.raw(@markdown) %></div>
      <% end %>
    </div>
    """
  end

  defp event_view(%{event: %{type: "response_item", payload: %{"type" => "reasoning"} = payload}} = assigns) do
    text = reasoning_text(payload)

    assigns =
      assigns
      |> assign(:text, text)
      |> assign(:word_count, word_count(text))
      |> assign(:markdown, markdown_html(text))

    ~H"""
    <details class="reasoning-card">
      <summary>Codex thinking · <%= @word_count %> words</summary>
      <div class="message-body markdown-body"><%= HTML.raw(@markdown) %></div>
    </details>
    """
  end

  defp event_view(%{event: %{type: "logical_function_call", payload: %{"name" => "apply_patch"} = payload}} = assigns) do
    input = call_input(payload)
    patches = SessionHistory.parse_apply_patch(input)

    assigns =
      assigns
      |> assign(:payload, payload)
      |> assign(:input, input)
      |> assign(:patches, patches)
      |> assign(:summary, patch_summary(patches))
      |> assign(:output, payload["output"] || "")
      |> assign(:output_stats, output_stats(payload["output"] || ""))

    ~H"""
    <details class="call-card patch-card">
      <summary>
        <span class="call-summary">
          <span class="tool-icon">patch</span>
          apply_patch · <%= @summary %> · <%= format_duration(@payload["duration_ms"]) %> · <%= @output_stats %>
        </span>
        <.copy_button text={@input} />
      </summary>

      <div class="patch-list">
        <section :for={patch <- @patches} class="patch-block">
          <div class="patch-title">
            <span class={["patch-op", "patch-op-#{patch.op}"]}><%= patch.op %></span>
            <code><%= patch.path %></code>
            <a :if={file_url(@workspace, patch.path)} class="subtle-link file-link" href={file_url(@workspace, patch.path)}>在 workspace 打开</a>
          </div>

          <%= if patch.op == :delete do %>
            <span class="deleted-badge">deleted</span>
          <% else %>
            <details :for={hunk <- patch.hunks} class="patch-hunk" open={patch.op == :update}>
              <summary><%= hunk_label(patch.op, hunk) %></summary>
              <%= if patch.op == :update do %>
                <div class="diff-columns">
                  <pre><%= diff_lines(hunk.search) %></pre>
                  <pre><%= diff_lines(hunk.replace) %></pre>
                </div>
              <% else %>
                <pre class="diff-add"><%= diff_lines(hunk.lines) %></pre>
              <% end %>
            </details>
          <% end %>
        </section>
      </div>

      <.maybe_output output={@output} />
    </details>
    """
  end

  defp event_view(%{event: %{type: "logical_function_call", payload: payload}} = assigns) do
    args = call_input(payload)
    output = payload["output"] || ""
    cmd = command_from_args(args)

    assigns =
      assigns
      |> assign(:payload, payload)
      |> assign(:args, format_args(args))
      |> assign(:args_text, args)
      |> assign(:args_summary, one_line(args, 80))
      |> assign(:cmd, cmd)
      |> assign(:output, output)
      |> assign(:output_stats, output_stats(output))

    ~H"""
    <details class="call-card">
      <summary>
        <span class="call-summary">
          <span class="tool-icon">fn</span>
          <%= @payload["name"] || "tool" %>
          <code :if={@cmd} class="cmd-chip"><%= @cmd %></code>
          <span :if={is_nil(@cmd)}>· <%= @args_summary %></span>
          · <%= format_duration(@payload["duration_ms"]) %> · <%= @output_stats %>
        </span>
        <.copy_button text={@args_text <> "\n\n" <> @output} />
      </summary>

      <div class="call-grid">
        <section>
          <h4>Args</h4>
          <%= if long_text?(@args) do %>
            <details class="long-text">
              <summary><span><%= text_preview(@args) %></span><b>Show more</b></summary>
              <pre class="code-panel"><%= @args %></pre>
            </details>
          <% else %>
            <pre class="code-panel"><%= @args %></pre>
          <% end %>
        </section>
        <section>
          <h4>Output</h4>
          <.numbered_output output={@output} />
        </section>
      </div>
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

  defp copy_button(assigns) do
    ~H"""
    <button type="button" class="copy-button" data-copy={@text} onclick="navigator.clipboard.writeText(this.dataset.copy)">copy</button>
    """
  end

  defp numbered_output(assigns) do
    assigns =
      assigns
      |> assign(:numbered, numbered_lines(assigns[:output] || ""))
      |> assign(:preview, text_preview(assigns[:output] || ""))

    ~H"""
    <%= if long_text?(@output) do %>
      <details class="long-text">
        <summary><span><%= @preview %></span><b>Show more</b></summary>
        <pre class="code-panel output-panel"><%= @numbered %></pre>
      </details>
    <% else %>
      <pre class="code-panel output-panel"><%= @numbered %></pre>
    <% end %>
    """
  end

  defp maybe_output(assigns) do
    ~H"""
    <section :if={@output != ""} class="patch-output">
      <h4>Output</h4>
      <.numbered_output output={@output} />
    </section>
    """
  end

  defp summarize_turn(turn, summary) do
    token_usage = turn_token_usage(turn.events)

    turn
    |> Map.put(:event_count, length(turn.events))
    |> Map.put(:tool_call_count, Enum.count(turn.events, &(&1.type == "logical_function_call")))
    |> Map.put(:token_usage, token_usage)
    |> Map.put(:wall_ms, turn_wall_ms(turn.events))
    |> Map.put(:model, summary.model)
  end

  defp turn_summary_line(turn) do
    usage = turn.token_usage

    [
      turn.label,
      "#{turn.event_count} events",
      "#{turn.tool_call_count} tool calls",
      "#{format_int(usage.total)} tokens (#{format_int(usage.input)}/#{format_int(usage.output)}/#{format_int(usage.cached_input)})",
      "model #{turn.model || "n/a"}"
    ]
    |> Enum.join(" · ")
  end

  defp turn_token_usage(events) do
    Enum.reduce(events, %{total: 0, input: 0, cached_input: 0, output: 0, cumulative_total: 0}, fn
      %{type: "event_msg", payload: %{"type" => "token_count"} = payload}, acc ->
        usage = token_usage(payload)

        %{
          total: acc.total + usage.total,
          input: acc.input + usage.input,
          cached_input: acc.cached_input + usage.cached_input,
          output: acc.output + usage.output,
          cumulative_total: max(acc.cumulative_total, usage.cumulative_total)
        }

      _event, acc ->
        acc
    end)
  end

  defp turn_wall_ms(events) do
    timestamps =
      events
      |> Enum.map(& &1.timestamp)
      |> Enum.filter(&match?(%DateTime{}, &1))

    case {List.first(timestamps), List.last(timestamps)} do
      {%DateTime{} = first, %DateTime{} = last} -> DateTime.diff(last, first, :millisecond)
      _ -> nil
    end
  end

  defp token_sparkline([]), do: %{points: "", values: []}

  defp token_sparkline(turns) do
    values =
      turns
      |> Enum.map(& &1.token_usage.cumulative_total)
      |> Enum.reject(&(&1 == 0))

    max_value = Enum.max(values, fn -> 0 end)

    points =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {value, index} ->
        x = if length(values) == 1, do: 80.0, else: index * 150 / max(length(values) - 1, 1) + 5
        y = 37 - value * 30 / max(max_value, 1)
        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
      end)

    %{points: points, values: values}
  end

  defp event_label(%{type: "response_item", payload: %{"type" => "message", "role" => role}}), do: role
  defp event_label(%{type: "response_item", payload: %{"type" => "reasoning"}}), do: "reasoning"
  defp event_label(%{type: "logical_function_call", payload: %{"name" => name}}), do: "tool: #{name}"
  defp event_label(%{type: "response_item", payload: %{"type" => type, "name" => name}}), do: "#{type}: #{name}"
  defp event_label(%{type: "response_item", payload: %{"type" => type}}), do: type
  defp event_label(%{type: "event_msg", payload: %{"type" => type}}), do: type
  defp event_label(%{type: type}), do: type

  defp event_class(%{type: "response_item", payload: %{"type" => "message", "role" => "user"}}), do: "timeline-event timeline-user"
  defp event_class(%{type: "response_item", payload: %{"type" => "message", "role" => "assistant"}}), do: "timeline-event timeline-assistant"
  defp event_class(%{type: "response_item", payload: %{"type" => "reasoning"}}), do: "timeline-event timeline-reasoning"
  defp event_class(%{type: "logical_function_call", payload: %{"name" => "apply_patch"}}), do: "timeline-event timeline-patch"
  defp event_class(%{type: "logical_function_call"}), do: "timeline-event timeline-tool"
  defp event_class(%{type: "response_item", payload: %{"type" => "function_call"}}), do: "timeline-event timeline-tool"
  defp event_class(%{type: "response_item", payload: %{"type" => "function_call_output"}}), do: "timeline-event timeline-output"
  defp event_class(_event), do: "timeline-event"

  defp call_input(%{"arguments" => arguments}) when is_binary(arguments), do: arguments
  defp call_input(%{"input" => input}) when is_binary(input), do: input
  defp call_input(%{"call_payload" => payload}) when is_map(payload), do: inspect(payload, pretty: true)
  defp call_input(_payload), do: ""

  defp format_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      {:error, _reason} -> args
    end
  end

  defp command_from_args(args) when is_binary(args) do
    with {:ok, %{"cmd" => cmd}} when is_binary(cmd) <- Jason.decode(args) do
      cmd
    else
      _ -> nil
    end
  end

  defp output_stats(output) when is_binary(output) do
    "#{line_count(output)} lines / #{byte_size(output)} bytes"
  end

  defp output_stats(_output), do: "0 lines / 0 bytes"

  defp line_count(""), do: 0
  defp line_count(output), do: output |> String.split("\n", trim: false) |> length()

  defp numbered_lines(""), do: ""

  defp numbered_lines(output) do
    width =
      output
      |> line_count()
      |> Integer.to_string()
      |> String.length()

    output
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, number} ->
      "#{String.pad_leading(Integer.to_string(number), width)} | #{line}"
    end)
  end

  defp long_text?(text) when is_binary(text), do: String.length(text) > 800
  defp long_text?(_text), do: false

  defp text_preview(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 200)
  end

  defp one_line(text, length) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, length)
  end

  defp patch_summary([]), do: "no parsed patch blocks"

  defp patch_summary(patches) do
    patches
    |> Enum.map(fn patch -> "#{patch.op} #{patch.path}" end)
    |> Enum.join(", ")
    |> one_line(120)
  end

  defp hunk_label(:update, %{header: header}) when is_binary(header), do: header
  defp hunk_label(:update, _hunk), do: "update hunk"
  defp hunk_label(:add, hunk), do: "#{length(hunk.lines)} added lines"
  defp hunk_label(_op, _hunk), do: "hunk"

  defp diff_lines(lines) when is_list(lines) do
    Enum.map_join(lines, "\n", fn %{kind: kind, text: text} ->
      prefix =
        case kind do
          :add -> "+"
          :remove -> "-"
          _ -> " "
        end

      prefix <> text
    end)
  end

  defp file_url(workspace, path) when is_binary(workspace) and is_binary(path) do
    workspace = Path.expand(workspace)
    full_path = if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, workspace)

    if full_path == workspace or String.starts_with?(full_path, workspace <> "/") do
      "file://" <> full_path
    end
  end

  defp file_url(_workspace, _path), do: nil

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

  defp reasoning_text(%{"summary" => summary}) when is_list(summary), do: message_text(summary)
  defp reasoning_text(%{"content" => content}) when is_list(content), do: message_text(content)
  defp reasoning_text(%{"text" => text}) when is_binary(text), do: text
  defp reasoning_text(payload), do: inspect(payload, pretty: true)

  defp word_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp markdown_html(text) when is_binary(text) do
    text
    |> HTML.html_escape()
    |> HTML.safe_to_string()
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> String.replace("\n", "<br>")
  end

  defp token_usage(%{"info" => info}) do
    last = usage_map(info["last_token_usage"] || info["total_token_usage"] || %{})
    cumulative = usage_map(info["total_token_usage"] || %{})

    last
    |> Map.put(:cumulative_total, cumulative.total)
    |> Map.put(:cumulative_cached, cumulative.cached_input)
  end

  defp token_usage(_payload) do
    %{total: 0, input: 0, cached_input: 0, output: 0, cumulative_total: 0, cumulative_cached: 0}
  end

  defp usage_map(usage) do
    %{
      total: usage["total_tokens"] || 0,
      input: usage["input_tokens"] || 0,
      cached_input: usage["cached_input_tokens"] || 0,
      output: usage["output_tokens"] || 0
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
