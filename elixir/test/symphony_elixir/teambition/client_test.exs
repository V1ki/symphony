defmodule SymphonyElixir.Teambition.ClientTest do
  use SymphonyElixir.TestSupport

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
