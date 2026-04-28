defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.

  Exposes a single `teambition_api` tool: a REST passthrough to Teambition
  Open API v3 using Symphony's configured tenant/auth.
  """

  alias SymphonyElixir.Teambition.Client

  @teambition_api_tool "teambition_api"

  @teambition_api_description """
  Make a REST call against Teambition Open API v3 using Symphony's configured auth.
  Provide the path (must start with `/v3/...`), HTTP method, and an optional JSON body.
  """

  @teambition_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["path"],
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" =>
          "API path under the configured endpoint, must start with `/v3/...` (e.g. `/v3/task/abc`)."
      },
      "method" => %{
        "type" => "string",
        "enum" => ["GET", "POST", "PUT", "DELETE"],
        "description" => "HTTP method, defaults to `GET`."
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON body for write requests.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @teambition_api_tool ->
        execute_teambition_api(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => Enum.map(tool_specs(), & &1["name"])
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @teambition_api_tool,
        "description" => @teambition_api_description,
        "inputSchema" => @teambition_api_input_schema
      }
    ]
  end

  defp execute_teambition_api(arguments, opts) do
    teambition_client = Keyword.get(opts, :teambition_client, &Client.request/4)

    with {:ok, path, method, body} <- normalize_arguments(arguments),
         {:ok, response} <- teambition_client.(path, method, body, []) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, path} <- fetch_path(arguments),
         {:ok, method} <- fetch_method(arguments),
         {:ok, body} <- fetch_body(arguments) do
      {:ok, path, method, body}
    end
  end

  defp normalize_arguments(_), do: {:error, :invalid_arguments}

  defp fetch_path(args) do
    case Map.get(args, "path") || Map.get(args, :path) do
      "/" <> _ = p -> {:ok, p}
      _ -> {:error, :missing_path}
    end
  end

  defp fetch_method(args) do
    raw = Map.get(args, "method") || Map.get(args, :method) || "GET"

    case raw |> to_string() |> String.upcase() do
      "GET" -> {:ok, :get}
      "POST" -> {:ok, :post}
      "PUT" -> {:ok, :put}
      "DELETE" -> {:ok, :delete}
      other -> {:error, {:invalid_method, other}}
    end
  end

  defp fetch_body(args) do
    case Map.get(args, "body") || Map.get(args, :body) do
      nil -> {:ok, %{}}
      body when is_map(body) -> {:ok, body}
      _ -> {:error, :invalid_body}
    end
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp encode_payload(payload) when is_map(payload) or is_list(payload),
    do: Jason.encode!(payload, pretty: true)

  defp encode_payload(payload), do: inspect(payload)

  defp error_payload(:missing_path),
    do: %{"error" => %{"message" => "`teambition_api.path` must start with `/v3/...`."}}

  defp error_payload({:invalid_method, m}),
    do: %{"error" => %{"message" => "Unsupported method: #{m}. Use GET / POST / PUT / DELETE."}}

  defp error_payload(:invalid_arguments),
    do: %{"error" => %{"message" => "`teambition_api` expects an object with at least `path`."}}

  defp error_payload(:invalid_body),
    do: %{"error" => %{"message" => "`teambition_api.body` must be a JSON object when provided."}}

  defp error_payload(:missing_teambition_access_token),
    do: %{
      "error" => %{
        "message" =>
          "Symphony is missing Teambition auth. Set `tracker.api_key` in WORKFLOW.md or export `TEAMBITION_ACCESS_TOKEN`."
      }
    }

  defp error_payload({:teambition_api_status, status}),
    do: %{"error" => %{"message" => "Teambition request failed HTTP #{status}.", "status" => status}}

  defp error_payload(reason),
    do: %{"error" => %{"message" => "Teambition tool failure.", "reason" => inspect(reason)}}
end
