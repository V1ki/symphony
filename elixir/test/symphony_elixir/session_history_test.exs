defmodule SymphonyElixir.SessionHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SessionHistory

  setup do
    SessionHistory.reset_cache()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "69f47f9e6fac7a5800b5d4d5",
      identifier: "T-11",
      title: "Time tracking smoke test",
      state: "Done",
      url: "https://www.teambition.com/project/p/tasks/69f47f9e6fac7a5800b5d4d5"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    root =
      Path.join(System.tmp_dir!(), "symphony-history-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "2026/05/01"))

    on_exit(fn ->
      SessionHistory.reset_cache()
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "lists, reads, and summarizes a Symphony rollout", %{root: root} do
    path =
      Path.join(
        root,
        "2026/05/01/rollout-2026-05-01T10-25-45-019de312-ae17-75d0-a0b4-0edb6ff1a687.jsonl"
      )

    File.cp!("test/fixtures/sample_rollout.jsonl", path)

    assert [
             %{
               session_id: "019de312-ae17-75d0-a0b4-0edb6ff1a687",
               issue_identifier: "T-11",
               issue_title: "Time tracking smoke test",
               issue_state: "Done",
               running: false,
               token_usage: %{total: 193_798, cached_input: 168_448}
             }
           ] =
             SessionHistory.list_sessions(
               sessions_root: root,
               originator: "symphony-orchestrator"
             )

    assert {:ok, events} =
             SessionHistory.get_session("019de312-ae17-75d0-a0b4-0edb6ff1a687",
               sessions_root: root
             )

    assert length(events) == 8

    assert {:ok, summary} =
             SessionHistory.summarize_session("019de312-ae17-75d0-a0b4-0edb6ff1a687",
               sessions_root: root
             )

    assert summary.issue_id == "69f47f9e6fac7a5800b5d4d5"
    assert summary.duration_ms == 47_487
    assert summary.turns == 1
    assert summary.model == "gpt-5"
    assert summary.model_provider == "openai"
    assert summary.tool_calls == [%{name: "exec_command", count: 1}]
  end

  test "supports old item-wrapped response items and ignores non-workspace cwd", %{root: root} do
    path =
      Path.join(
        root,
        "2026/05/01/rollout-2026-05-01T11-00-00-019de333-ae17-75d0-a0b4-0edb6ff1a687.jsonl"
      )

    File.write!(path, """
    {"timestamp":"2026-05-01T11:00:00Z","type":"session_meta","payload":{"id":"019de333-ae17-75d0-a0b4-0edb6ff1a687","timestamp":"2026-05-01T11:00:00Z","cwd":"/tmp/manual","originator":"symphony-orchestrator"}}
    {"timestamp":"2026-05-01T11:00:01Z","type":"response_item","payload":{"item":{"type":"function_call","name":"shell","arguments":"{}","call_id":"call-old"}}}
    {"timestamp":"2026-05-01T11:00:02Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":2000}}
    """)

    assert [session] =
             SessionHistory.list_sessions(
               sessions_root: root,
               originator: "symphony-orchestrator"
             )

    assert session.issue_identifier == nil

    assert {:ok, summary} =
             SessionHistory.summarize_session("019de333-ae17-75d0-a0b4-0edb6ff1a687",
               sessions_root: root
             )

    assert summary.tool_calls == [%{name: "shell", count: 1}]
  end

  test "malformed jsonl appears as a failed row instead of crashing", %{root: root} do
    path =
      Path.join(
        root,
        "2026/05/01/rollout-2026-05-01T12-00-00-019de444-ae17-75d0-a0b4-0edb6ff1a687.jsonl"
      )

    File.write!(path, "not json\n")

    assert [%{issue_title: "(failed to parse)", issue_state: "error", parse_error: parse_error}] =
             SessionHistory.list_sessions(sessions_root: root)

    assert parse_error =~ "DecodeError"
  end

  test "pairs function calls with their matching outputs" do
    call = %{
      timestamp: ~U[2026-05-01 10:00:00Z],
      type: "response_item",
      payload: %{"type" => "function_call", "name" => "exec_command", "arguments" => ~s({"cmd":"mix test"}), "call_id" => "call-1"}
    }

    output = %{
      timestamp: ~U[2026-05-01 10:00:02Z],
      type: "response_item",
      payload: %{"type" => "function_call_output", "call_id" => "call-1", "output" => "ok\n"}
    }

    user_message = %{
      timestamp: ~U[2026-05-01 09:59:59Z],
      type: "response_item",
      payload: %{"type" => "message", "role" => "user", "content" => "run tests"}
    }

    assert [
             ^user_message,
             %{
               type: "logical_function_call",
               payload: %{
                 "type" => "function_call_pair",
                 "name" => "exec_command",
                 "call_id" => "call-1",
                 "arguments" => ~s({"cmd":"mix test"}),
                 "output" => "ok\n",
                 "duration_ms" => 2000
               }
             }
           ] = SessionHistory.pair_calls_with_outputs([user_message, call, output])
  end

  test "parses apply_patch add update and delete blocks" do
    patch = """
    *** Begin Patch
    *** Add File: lib/new.ex
    +defmodule New do
    +end
    *** Update File: lib/existing.ex
    @@
    -old
    +new
     keep
    *** Delete File: lib/old.ex
    *** End Patch
    """

    assert [
             %{op: :add, path: "lib/new.ex", hunks: [%{lines: [%{kind: :add, text: "defmodule New do"}, %{kind: :add, text: "end"}]}]},
             %{
               op: :update,
               path: "lib/existing.ex",
               hunks: [
                 %{
                   search: [%{kind: :remove, text: "old"}, %{kind: :context, text: "keep"}],
                   replace: [%{kind: :add, text: "new"}, %{kind: :context, text: "keep"}]
                 }
               ]
             },
             %{op: :delete, path: "lib/old.ex"}
           ] = SessionHistory.parse_apply_patch(patch)
  end
end
