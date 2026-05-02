defmodule SymphonyElixir.Teambition.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepoSettings

  @status_index %{"todo" => "未完成", "done" => "已完成"}

  test "normalizes description dependencies from English and Chinese notes" do
    tasks = [
      task(100, "T-100", note: "Depends on: T-101"),
      task(101, "T-101", note: "依赖：T-102, T-103"),
      task(102, "T-102", note: ""),
      task(103, "T-103", note: "", parent_id: "T-102", pos: 1)
    ]

    issues = normalize_tasks(tasks)

    assert blockers_for(issues, "T-100") == [%{id: "T-101", identifier: "T-101", state: "未完成"}]

    assert blockers_for(issues, "T-101") == [
             %{id: "T-102", identifier: "T-102", state: "未完成"},
             %{id: "T-103", identifier: "T-103", state: "未完成"}
           ]

    assert blockers_for(issues, "T-102") == []
    assert blockers_for(issues, "T-103") == []
  end

  test "normalizes same-parent subtask dependencies by lower pos" do
    tasks = [
      task(100, "T-100", note: ""),
      task(104, "T-104", note: "", parent_id: "T-100", pos: 1),
      task(105, "T-105", note: "", parent_id: "T-100", pos: 2)
    ]

    issues = normalize_tasks(tasks)

    assert blockers_for(issues, "T-104") == []
    assert blockers_for(issues, "T-105") == [%{id: "T-104", identifier: "T-104", state: "未完成"}]
  end

  test "explicit description dependencies override subtask pos inference" do
    tasks = [
      task(100, "T-100", note: ""),
      task(104, "T-104", note: "", parent_id: "T-100", pos: 1),
      task(105, "T-105", note: "Blocked by: T-100", parent_id: "T-100", pos: 2)
    ]

    issues = normalize_tasks(tasks)

    assert blockers_for(issues, "T-105") == [%{id: "T-100", identifier: "T-100", state: "未完成"}]
  end

  test "ignores self dependency and logs a warning" do
    tasks = [task(300, "T-300", note: "Depends on: T-300")]

    log =
      capture_log(fn ->
        assert [%Issue{blocked_by: []}] = normalize_tasks(tasks)
      end)

    assert log =~ "Ignoring self dependency in Teambition task T-300"
  end

  test "keeps unresolved description blockers for candidate resolution" do
    tasks = [task(301, "T-301", note: "Depends on: T-9999")]

    assert [%Issue{blocked_by: [%{id: nil, identifier: "T-9999", state: nil}]}] = normalize_tasks(tasks)
  end

  test "normalizes Repo magic line into issue repo_url" do
    tasks = [task(401, "T-401", note: "Repo: git@github.com:V1ki/symphony.git\nBody")]

    assert [%Issue{repo_url: "git@github.com:V1ki/symphony.git"}] = normalize_tasks(tasks)
  end

  test "normalizes yaml frontmatter repo into issue repo_url" do
    tasks = [task(402, "T-402", note: "---\nrepo: https://github.com/V1ki/symphony.git\n---\nBody")]

    assert [%Issue{repo_url: "https://github.com/V1ki/symphony.git"}] = normalize_tasks(tasks)
  end

  test "repo_url precedence is description then project default then workflow global default" do
    write_workflow_file!(Workflow.workflow_file_path(), default_repo_url: "git@github.com:global/repo.git")
    Application.put_env(:symphony_elixir, :default_repo_url, "git@github.com:project/repo.git")

    assert [%Issue{repo_url: "git@github.com:description/repo.git"}] =
             normalize_tasks([task(403, "T-403", note: "Repo: git@github.com:description/repo.git")])

    assert [%Issue{repo_url: "git@github.com:project/repo.git"}] =
             normalize_tasks([task(404, "T-404", note: "No repo here")])

    Application.delete_env(:symphony_elixir, :default_repo_url)

    assert [%Issue{repo_url: "git@github.com:global/repo.git"}] =
             normalize_tasks([task(405, "T-405", note: "No repo here")])
  end

  test "repo override takes priority over description repo" do
    RepoSettings.put_issue_override("T-406", "git@github.com:override/repo.git")

    assert [%Issue{repo_url: "git@github.com:override/repo.git"}] =
             normalize_tasks([task(406, "T-406", note: "Repo: git@github.com:description/repo.git")])
  end

  defp normalize_tasks(tasks) do
    Enum.map(tasks, &Client.normalize_task_for_test(&1, @status_index, tasks))
  end

  defp blockers_for(issues, identifier) do
    issues
    |> Enum.find(&(&1.identifier == identifier))
    |> Map.fetch!(:blocked_by)
  end

  defp task(unique_id, id, opts) do
    %{
      "id" => id,
      "uniqueId" => unique_id,
      "content" => "Task #{unique_id}",
      "note" => Keyword.fetch!(opts, :note),
      "tfsId" => "todo",
      "projectId" => "project",
      "executorId" => nil,
      "pos" => Keyword.get(opts, :pos, 0)
    }
    |> maybe_put("_parentId", Keyword.get(opts, :parent_id))
  end

  defp maybe_put(task, _key, nil), do: task
  defp maybe_put(task, key, value), do: Map.put(task, key, value)
end
