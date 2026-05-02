defmodule SymphonyElixir.SessionHistory do
  @moduledoc """
  Reads Codex rollout jsonl files and projects them into Symphony history views.
  """

  use GenServer

  alias SymphonyElixir.Tracker

  @index_table __MODULE__.Index
  @cache_table __MODULE__.Cache
  @default_limit 50

  @type event :: %{timestamp: DateTime.t() | nil, type: String.t(), payload: map()}
  @type token_usage :: %{
          total: integer(),
          input: integer(),
          cached_input: integer(),
          output: integer(),
          reasoning_output: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    ensure_tables()
    refresh_index(session_root(opts))
    {:ok, %{session_root: session_root(opts)}}
  end

  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) do
    ensure_tables()

    root = session_root(opts)
    refresh_index(root)

    rows =
      root
      |> session_files()
      |> Enum.map(&list_summary(&1))
      |> attach_issues()
      |> filter_by_originator(Keyword.get(opts, :originator))
      |> filter_by_query(Keyword.get(opts, :query))
      |> Enum.sort_by(&sort_timestamp/1, {:desc, DateTime})

    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, @default_limit)

    rows
    |> Enum.drop(max(offset, 0))
    |> Enum.take(max(limit, 0))
  end

  @spec get_session(String.t(), keyword()) :: {:ok, [event()]} | {:error, term()}
  def get_session(session_id, opts \\ []) when is_binary(session_id) do
    ensure_tables()

    with {:ok, path} <- path_for_session(session_id, opts),
         {:ok, events} <- parse_events(path) do
      events =
        events
        |> Enum.drop(max(Keyword.get(opts, :offset, 0), 0))
        |> maybe_take(Keyword.get(opts, :limit))

      {:ok, events}
    end
  end

  @spec summarize_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def summarize_session(session_id, opts \\ []) when is_binary(session_id) do
    ensure_tables()

    with {:ok, path} <- path_for_session(session_id, opts),
         {:ok, parsed} <- parse_full(path) do
      parsed
      |> full_summary()
      |> List.wrap()
      |> attach_issues()
      |> List.first()
      |> case do
        nil -> {:error, :session_not_found}
        summary -> {:ok, summary}
      end
    end
  end

  @spec reset_cache() :: :ok
  def reset_cache do
    ensure_tables()
    :ets.delete_all_objects(@index_table)
    :ets.delete_all_objects(@cache_table)
    :ok
  end

  defp session_root(opts) do
    Keyword.get(opts, :sessions_root) ||
      Application.get_env(:symphony_elixir, :codex_sessions_root) ||
      Path.expand("~/.codex/sessions")
  end

  defp ensure_tables do
    ensure_table(@index_table)
    ensure_table(@cache_table)
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ets.new(table, [:named_table, :public, read_concurrency: true])
      _tid -> table
    end
  rescue
    ArgumentError -> table
  end

  defp refresh_index(root) do
    root
    |> session_files()
    |> Enum.each(fn path ->
      if id = session_id_from_path(path) do
        :ets.insert(@index_table, {id, path})
      end
    end)
  end

  defp session_files(root) when is_binary(root) do
    if File.dir?(root) do
      Path.wildcard(Path.join([root, "**", "rollout-*.jsonl"]))
    else
      []
    end
  end

  defp session_id_from_path(path) do
    path
    |> Path.basename()
    |> then(fn basename ->
      Regex.run(~r/rollout-.+-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i, basename)
    end)
    |> case do
      [_basename, id] -> id
      _ -> nil
    end
  end

  defp path_for_session(session_id, opts) do
    case :ets.lookup(@index_table, session_id) do
      [{^session_id, path}] ->
        {:ok, path}

      [] ->
        refresh_index(session_root(opts))

        case :ets.lookup(@index_table, session_id) do
          [{^session_id, path}] -> {:ok, path}
          [] -> {:error, :session_not_found}
        end
    end
  end

  defp list_summary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         cache_key = {path, stat.mtime, stat.size},
         :miss <- cache_lookup(cache_key),
         {:ok, parsed} <- parse_list(path) do
      summary = summary_from_list_parse(parsed, path, stat)

      unless summary.running do
        :ets.insert(@cache_table, {cache_key, summary})
      end

      summary
    else
      {:hit, cached} ->
        cached

      {:error, reason} ->
        failed_summary(path, reason)
    end
  end

  defp cache_lookup(cache_key) do
    case :ets.lookup(@cache_table, cache_key) do
      [{^cache_key, summary}] -> {:hit, summary}
      [] -> :miss
    end
  end

  defp parse_list(path) do
    reduce_jsonl(path, %{
      meta: nil,
      first_at: nil,
      last_at: nil,
      token_usage: empty_usage(),
      task_started: false,
      task_complete: false,
      task_duration_ms: nil,
      turn_ids: MapSet.new()
    }, fn line, acc ->
      case decode_line(line) do
        {:ok, %{"timestamp" => timestamp, "type" => type, "payload" => payload}} ->
          parsed_at = parse_datetime(timestamp)

          acc
          |> put_first_at(parsed_at)
          |> Map.put(:last_at, parsed_at || acc.last_at)
          |> absorb_list_event(type, payload, parsed_at)

        {:ok, _other} ->
          acc

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_full(path) do
    reduce_jsonl(path, %{events: [], list: nil, tool_calls: %{}}, fn line, acc ->
      case decode_line(line) do
        {:ok, %{"timestamp" => timestamp, "type" => type, "payload" => payload}} ->
          event = %{timestamp: parse_datetime(timestamp), type: type, payload: normalize_payload(payload)}

          acc =
            acc
            |> Map.update!(:events, &[event | &1])
            |> Map.put(:list, absorb_list_event(acc.list || initial_list_parse(), type, payload, event.timestamp))
            |> absorb_tool_call(type, payload)

          acc

        {:ok, _other} ->
          acc

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok, %{acc | events: Enum.reverse(acc.events)} |> Map.put(:path, path)}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_events(path) do
    with {:ok, parsed} <- parse_full(path) do
      {:ok, parsed.events}
    end
  end

  defp initial_list_parse do
    %{
      meta: nil,
      first_at: nil,
      last_at: nil,
      token_usage: empty_usage(),
      task_started: false,
      task_complete: false,
      task_duration_ms: nil,
      turn_ids: MapSet.new()
    }
  end

  defp reduce_jsonl(path, acc, reducer) do
    path
    |> File.stream!([], :line)
    |> Enum.reduce_while(acc, fn line, current ->
      case reducer.(line, current) do
        {:halt, {:error, reason}} -> {:halt, {:error, reason}}
        next -> {:cont, next}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      parsed -> {:ok, parsed}
    end
  rescue
    error in File.Error -> {:error, error.reason}
  end

  defp decode_line(line) do
    line
    |> String.trim()
    |> case do
      "" -> {:ok, %{}}
      json -> Jason.decode(json)
    end
  end

  defp absorb_list_event(acc, "session_meta", payload, parsed_at) do
    meta = normalize_payload(payload)

    acc
    |> Map.put(:meta, meta)
    |> put_first_at(parse_datetime(meta["timestamp"]) || parsed_at)
  end

  defp absorb_list_event(acc, "turn_context", payload, _parsed_at) do
    case normalize_payload(payload)["turn_id"] do
      id when is_binary(id) -> Map.update!(acc, :turn_ids, &MapSet.put(&1, id))
      _ -> acc
    end
  end

  defp absorb_list_event(acc, "event_msg", payload, _parsed_at) do
    payload = normalize_payload(payload)

    acc =
      case payload["type"] do
        "token_count" -> Map.put(acc, :token_usage, token_usage_from_payload(payload))
        "task_started" -> Map.put(acc, :task_started, true)
        "task_complete" -> acc |> Map.put(:task_complete, true) |> Map.put(:task_duration_ms, payload["duration_ms"])
        "turn_aborted" -> Map.put(acc, :task_complete, true)
        "turn_completed" -> Map.put(acc, :task_complete, true)
        "turn_failed" -> Map.put(acc, :task_complete, true)
        "turn_cancelled" -> Map.put(acc, :task_complete, true)
        _ -> acc
      end

    case payload["turn_id"] do
      id when is_binary(id) -> Map.update!(acc, :turn_ids, &MapSet.put(&1, id))
      _ -> acc
    end
  end

  defp absorb_list_event(acc, _type, _payload, _parsed_at), do: acc

  defp absorb_tool_call(acc, "response_item", payload) do
    payload = response_item_payload(payload)

    case payload do
      %{"type" => "function_call", "name" => name} when is_binary(name) ->
        Map.update!(acc, :tool_calls, &Map.update(&1, name, 1, fn count -> count + 1 end))

      _ ->
        acc
    end
  end

  defp absorb_tool_call(acc, _type, _payload), do: acc

  defp summary_from_list_parse(parsed, path, stat) do
    meta = parsed.meta || %{}
    session_id = meta["id"] || session_id_from_path(path)
    workspace = meta["cwd"]
    started_at = parse_datetime(meta["timestamp"]) || parsed.first_at || mtime_to_datetime(stat.mtime)
    ended_at = parsed.last_at || started_at
    running = running?(parsed, meta)

    %{
      session_id: session_id,
      issue_unique_id: issue_unique_id(workspace),
      issue_identifier: issue_identifier(issue_unique_id(workspace)),
      issue_id: nil,
      issue_title: nil,
      issue_state: nil,
      issue_url: nil,
      started_at: started_at,
      ended_at: if(running, do: nil, else: ended_at),
      duration_ms: duration_ms(parsed.task_duration_ms, started_at, ended_at),
      turns: MapSet.size(parsed.turn_ids),
      model: meta["model"] || meta["model_slug"],
      model_provider: meta["model_provider"],
      token_usage: parsed.token_usage,
      workspace: workspace,
      originator: meta["originator"],
      running: running,
      path: path,
      parse_error: nil
    }
  end

  defp full_summary(%{list: list_parse, path: path, tool_calls: tool_calls}) do
    stat = case File.stat(path, time: :posix) do
      {:ok, stat} -> stat
      {:error, _reason} -> fake_stat(list_parse)
    end

    list_parse
    |> summary_from_list_parse(path, stat)
    |> Map.put(:tool_calls, tool_call_summary(tool_calls))
  end

  defp fake_stat(parsed) do
    %{mtime: datetime_to_posix(parsed.last_at || parsed.first_at)}
  end

  defp failed_summary(path, reason) do
    %{
      session_id: session_id_from_path(path),
      issue_unique_id: nil,
      issue_identifier: nil,
      issue_id: nil,
      issue_title: "(failed to parse)",
      issue_state: "error",
      issue_url: nil,
      started_at: nil,
      ended_at: nil,
      duration_ms: nil,
      turns: 0,
      model: nil,
      model_provider: nil,
      token_usage: empty_usage(),
      workspace: nil,
      originator: nil,
      running: false,
      path: path,
      parse_error: inspect(reason)
    }
  end

  defp attach_issues(rows) do
    unique_ids =
      rows
      |> Enum.map(& &1.issue_unique_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    issue_index =
      case Tracker.fetch_issue_states_by_ids(unique_ids) do
        {:ok, issues} ->
          Map.new(issues, fn issue ->
            {unique_id_from_identifier(issue.identifier), issue}
          end)

        {:error, _reason} ->
          %{}
      end

    Enum.map(rows, fn row ->
      issue = Map.get(issue_index, row.issue_unique_id)
      merge_issue(row, issue)
    end)
  end

  defp merge_issue(row, nil), do: row

  defp merge_issue(row, issue) do
    %{
      row
      | issue_id: issue.id,
        issue_identifier: issue.identifier || row.issue_identifier,
        issue_title: issue.title,
        issue_state: issue.state,
        issue_url: issue.url
    }
  end

  defp filter_by_originator(rows, nil), do: rows

  defp filter_by_originator(rows, originator) do
    Enum.filter(rows, &(&1.originator == originator))
  end

  defp filter_by_query(rows, nil), do: rows
  defp filter_by_query(rows, ""), do: rows

  defp filter_by_query(rows, query) when is_binary(query) do
    needle = String.downcase(String.trim(query))

    Enum.filter(rows, fn row ->
      [row.issue_identifier, row.issue_title]
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(fn value -> value |> to_string() |> String.downcase() |> String.contains?(needle) end)
    end)
  end

  defp sort_timestamp(%{started_at: %DateTime{} = started_at}), do: started_at
  defp sort_timestamp(_row), do: ~U[1970-01-01 00:00:00Z]

  defp token_usage_from_payload(%{"info" => %{"total_token_usage" => usage}}), do: token_usage(usage)
  defp token_usage_from_payload(%{"info" => %{"last_token_usage" => usage}}), do: token_usage(usage)
  defp token_usage_from_payload(_payload), do: empty_usage()

  defp token_usage(usage) when is_map(usage) do
    %{
      total: int(usage["total_tokens"]),
      input: int(usage["input_tokens"]),
      cached_input: int(usage["cached_input_tokens"]),
      output: int(usage["output_tokens"]),
      reasoning_output: int(usage["reasoning_output_tokens"])
    }
  end

  defp token_usage(_usage), do: empty_usage()

  defp empty_usage do
    %{total: 0, input: 0, cached_input: 0, output: 0, reasoning_output: 0}
  end

  defp tool_call_summary(tool_calls) do
    tool_calls
    |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
    |> Enum.sort_by(& &1.name)
  end

  defp running?(%{task_complete: true}, _meta), do: false
  defp running?(%{task_started: true}, _meta), do: true
  defp running?(_parsed, _meta), do: false

  defp duration_ms(ms, _started_at, _ended_at) when is_integer(ms), do: ms

  defp duration_ms(_ms, %DateTime{} = started_at, %DateTime{} = ended_at) do
    DateTime.diff(ended_at, started_at, :millisecond)
  end

  defp duration_ms(_ms, _started_at, _ended_at), do: nil

  defp issue_unique_id(workspace) when is_binary(workspace) do
    case Regex.run(~r{/symphony-workspaces/T-(\d+)(?:/|$)}, workspace) do
      [_match, id] -> id
      _ -> nil
    end
  end

  defp issue_unique_id(_workspace), do: nil

  defp unique_id_from_identifier(identifier) when is_binary(identifier) do
    case Regex.run(~r/^T-(\d+)$/, identifier) do
      [_match, id] -> id
      _ -> identifier
    end
  end

  defp unique_id_from_identifier(_identifier), do: nil

  defp issue_identifier(nil), do: nil
  defp issue_identifier(id), do: "T-#{id}"

  defp response_item_payload(%{"item" => item}) when is_map(item), do: normalize_payload(item)
  defp response_item_payload(payload), do: normalize_payload(payload)

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(_payload), do: %{}

  defp put_first_at(acc, nil), do: acc
  defp put_first_at(%{first_at: nil} = acc, at), do: %{acc | first_at: at}
  defp put_first_at(acc, _at), do: acc

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp mtime_to_datetime(posix) when is_integer(posix), do: DateTime.from_unix!(posix)
  defp mtime_to_datetime(_posix), do: nil

  defp datetime_to_posix(%DateTime{} = datetime), do: DateTime.to_unix(datetime)
  defp datetime_to_posix(_datetime), do: 0

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_binary(value), do: String.to_integer(value)
  defp int(_value), do: 0

  defp maybe_take(events, nil), do: events
  defp maybe_take(events, limit), do: Enum.take(events, max(limit, 0))
end
