defmodule SymphonyElixir.OrchestratorTest do
  use SymphonyElixir.TestSupport

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["未完成"],
      tracker_terminal_states: ["已完成", "已废弃"]
    )

    :ok
  end

  test "skips active issue blocked by a non-terminal predecessor" do
    t200 = issue("200", "T-200", "未完成")
    t201 = issue("201", "T-201", "未完成", blocked_by: [blocker("200", "T-200", "未完成")])

    assert Orchestrator.should_dispatch_issue_for_test(t200, state()) == true
    assert Orchestrator.should_dispatch_issue_for_test(t201, state()) == false
    assert Orchestrator.dispatchable_issue_identifiers_for_test([t200, t201], state()) == ["T-200"]
  end

  test "dispatches blocked issue after its predecessor reaches a terminal state" do
    t201 = issue("201", "T-201", "未完成", blocked_by: [blocker("200", "T-200", "已完成")])

    assert Orchestrator.should_dispatch_issue_for_test(t201, state()) == true
    assert Orchestrator.dispatchable_issue_identifiers_for_test([t201], state()) == ["T-201"]
  end

  test "self-loop and missing blockers do not permanently block dispatch after normalization" do
    t300 = issue("300", "T-300", "未完成", blocked_by: [])
    t301 = issue("301", "T-301", "未完成", blocked_by: [blocker(nil, "T-9999", "已废弃")])

    assert Orchestrator.should_dispatch_issue_for_test(t300, state()) == true
    assert Orchestrator.should_dispatch_issue_for_test(t301, state()) == true
  end

  test "DAG dispatch marker selects issues in dependency order" do
    first_round = [
      issue("a", "T-A", "未完成"),
      issue("b", "T-B", "未完成", blocked_by: [blocker("a", "T-A", "未完成")]),
      issue("c", "T-C", "未完成",
        blocked_by: [blocker("a", "T-A", "未完成"), blocker("b", "T-B", "未完成")]
      ),
      issue("d", "T-D", "未完成")
    ]

    assert Orchestrator.dispatchable_issue_identifiers_for_test(first_round, state(max_concurrent_agents: 1)) == [
             "T-A"
           ]

    second_round = [
      issue("b", "T-B", "未完成", blocked_by: [blocker("a", "T-A", "已完成")]),
      issue("c", "T-C", "未完成",
        blocked_by: [blocker("a", "T-A", "已完成"), blocker("b", "T-B", "未完成")]
      ),
      issue("d", "T-D", "未完成")
    ]

    assert Orchestrator.dispatchable_issue_identifiers_for_test(second_round, state(max_concurrent_agents: 2)) == [
             "T-B",
             "T-D"
           ]

    third_round = [
      issue("c", "T-C", "未完成",
        blocked_by: [blocker("a", "T-A", "已完成"), blocker("b", "T-B", "已完成")]
      )
    ]

    assert Orchestrator.dispatchable_issue_identifiers_for_test(third_round, state(max_concurrent_agents: 2)) == [
             "T-C"
           ]
  end

  defp state(opts \\ []) do
    %Orchestrator.State{
      max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 3),
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  defp issue(id, identifier, state, opts \\ []) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Issue #{identifier}",
      state: state,
      blocked_by: Keyword.get(opts, :blocked_by, [])
    }
  end

  defp blocker(id, identifier, state) do
    %{id: id, identifier: identifier, state: state}
  end
end
