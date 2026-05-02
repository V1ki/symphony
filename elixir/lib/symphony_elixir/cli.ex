defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:ok, message} ->
        IO.puts(message)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:ok, String.t()} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps())

  def evaluate(["repo" | repo_args], deps) do
    repo_command(repo_args, deps)
  end

  def evaluate(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    """
    Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]
           symphony repo list
           symphony repo set <issue_identifier> <url>
           symphony repo default <url>
    """
    |> String.trim()
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      repo_http_request: &repo_http_request/3,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp repo_command(["list"], deps) do
    with {:ok, payload} <- call_repo_api(deps, :get, "/api/v1/repos", %{}) do
      {:ok, format_repo_list(payload)}
    end
  end

  defp repo_command(["set", issue_identifier, repo_url], deps) do
    path = "/api/v1/issues/#{URI.encode_www_form(issue_identifier)}/repo"

    with {:ok, payload} <- call_repo_api(deps, :put, path, %{repo_url: repo_url}) do
      {:ok, "Set #{payload["issue_identifier"] || issue_identifier} repo to #{payload["repo_url"] || "n/a"}"}
    end
  end

  defp repo_command(["default", repo_url], deps) do
    with {:ok, payload} <- call_repo_api(deps, :post, "/api/v1/repos/default", %{repo_url: repo_url}) do
      {:ok, "Default repo set to #{payload["default_repo_url"] || "n/a"}"}
    end
  end

  defp repo_command(_args, _deps), do: {:error, usage_message()}

  defp call_repo_api(deps, method, path, body) do
    request = Map.get(deps, :repo_http_request, &repo_http_request/3)

    case request.(method, path, body) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, "Repository API request failed: #{inspect(reason)}"}
    end
  end

  defp format_repo_list(payload) when is_map(payload) do
    issue_lines =
      payload
      |> Map.get("issues", [])
      |> Enum.map(fn issue ->
        identifier = issue["issue_identifier"] || "n/a"
        status = issue["status"] || "n/a"
        repo_url = issue["repo_url"] || "n/a"
        "#{identifier}\t#{status}\t#{repo_url}"
      end)

    lines =
      [
        "Default repo: #{payload["default_repo_url"] || "n/a"}",
        "Active issues:"
        | case issue_lines do
            [] -> ["n/a"]
            lines -> lines
          end
      ]

    Enum.join(lines, "\n")
  end

  defp repo_http_request(method, path, body) do
    :inets.start()

    url =
      "http://127.0.0.1:#{repo_api_port()}#{path}"
      |> String.to_charlist()

    headers = [{~c"accept", ~c"application/json"}]

    request =
      case method do
        :get ->
          {url, headers}

        method when method in [:post, :put] ->
          json_body = Jason.encode!(body)
          {url, [{~c"content-type", ~c"application/json"} | headers], ~c"application/json", json_body}
      end

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
        Jason.decode(response_body)

      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:error, {:http_status, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo_api_port do
    case System.get_env("SYMPHONY_PORT") do
      nil ->
        case Application.get_env(:symphony_elixir, :server_port_override) do
          port when is_integer(port) and port >= 0 -> port
          _ -> 5050
        end

      value ->
        case Integer.parse(value) do
          {port, ""} when port >= 0 -> port
          _ -> 5050
        end
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
