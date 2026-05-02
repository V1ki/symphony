defmodule SymphonyElixir.RepoSettings do
  @moduledoc """
  Runtime repository URL settings for issue dispatch.
  """

  alias SymphonyElixir.Config

  @table :symphony_elixir_repo_settings
  @recent_key :recent_repos
  @max_recent 5

  @spec resolve_repo_url(String.t() | nil, String.t() | nil) :: String.t() | nil
  def resolve_repo_url(issue_identifier, description) do
    issue_override(issue_identifier) ||
      description_repo_url(description) ||
      default_repo_url() ||
      global_default_repo_url()
  end

  @spec issue_repo_url(String.t() | nil, String.t() | nil) :: String.t() | nil
  def issue_repo_url(issue_identifier, fallback) do
    issue_override(issue_identifier) || normalize_repo_url(fallback)
  end

  @spec put_default_repo_url(String.t() | nil) :: String.t() | nil
  def put_default_repo_url(repo_url) do
    normalized = normalize_repo_url(repo_url)

    if is_nil(normalized) do
      Application.delete_env(:symphony_elixir, :default_repo_url)
    else
      Application.put_env(:symphony_elixir, :default_repo_url, normalized)
      remember_repo(normalized)
    end

    normalized
  end

  @spec default_repo_url() :: String.t() | nil
  def default_repo_url do
    :symphony_elixir
    |> Application.get_env(:default_repo_url)
    |> normalize_repo_url()
  end

  @spec put_issue_override(String.t(), String.t() | nil) :: String.t() | nil
  def put_issue_override(issue_identifier, repo_url) when is_binary(issue_identifier) do
    normalized = normalize_repo_url(repo_url)
    table = ensure_table!()

    if is_nil(normalized) do
      :ets.delete(table, override_key(issue_identifier))
    else
      :ets.insert(table, {override_key(issue_identifier), normalized})
      remember_repo(normalized)
    end

    normalized
  end

  @spec issue_override(String.t() | nil) :: String.t() | nil
  def issue_override(issue_identifier) when is_binary(issue_identifier) do
    case :ets.lookup(ensure_table!(), override_key(issue_identifier)) do
      [{_key, repo_url}] -> repo_url
      [] -> nil
    end
  end

  def issue_override(_issue_identifier), do: nil

  @spec recent_repos() :: [String.t()]
  def recent_repos do
    case :ets.lookup(ensure_table!(), @recent_key) do
      [{@recent_key, repos}] when is_list(repos) -> repos
      [] -> []
    end
  end

  @spec description_repo_url(String.t() | nil) :: String.t() | nil
  def description_repo_url(description) when is_binary(description) do
    frontmatter_repo_url(description) || magic_line_repo_url(description)
  end

  def description_repo_url(_description), do: nil

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    Application.delete_env(:symphony_elixir, :default_repo_url)
    :ok
  end

  defp global_default_repo_url do
    case Config.settings() do
      {:ok, settings} -> normalize_repo_url(Map.get(settings, :default_repo_url))
      {:error, _reason} -> nil
    end
  end

  defp magic_line_repo_url(description) do
    description
    |> String.split(~r/\R/u, trim: false)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*Repo\s*:\s*(.+?)\s*$/iu, line) do
        [_, value] -> normalize_repo_url(value)
        _ -> nil
      end
    end)
  end

  defp frontmatter_repo_url("---\n" <> rest) do
    case String.split(rest, ~r/\R---\R/u, parts: 2) do
      [frontmatter, _body] -> repo_from_frontmatter(frontmatter)
      _ -> nil
    end
  end

  defp frontmatter_repo_url("---\r\n" <> rest) do
    case String.split(rest, ~r/\R---\R/u, parts: 2) do
      [frontmatter, _body] -> repo_from_frontmatter(frontmatter)
      _ -> nil
    end
  end

  defp frontmatter_repo_url(_description), do: nil

  defp repo_from_frontmatter(frontmatter) do
    frontmatter
    |> String.split(~r/\R/u, trim: false)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*(?:repo|repo_url)\s*:\s*(.+?)\s*$/iu, line) do
        [_, value] -> normalize_repo_url(value)
        _ -> nil
      end
    end)
  end

  defp remember_repo(repo_url) when is_binary(repo_url) do
    table = ensure_table!()

    repos =
      [repo_url | recent_repos()]
      |> Enum.uniq()
      |> Enum.take(@max_recent)

    :ets.insert(table, {@recent_key, repos})
    :ok
  end

  defp normalize_repo_url(repo_url) when is_binary(repo_url) do
    repo_url
    |> String.trim()
    |> strip_wrapping_quotes()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_repo_url(_repo_url), do: nil

  defp strip_wrapping_quotes(value) do
    cond do
      String.length(value) >= 2 and String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.length(value) >= 2 and String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end

  defp override_key(issue_identifier), do: {:issue_override, issue_identifier}

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end
end
