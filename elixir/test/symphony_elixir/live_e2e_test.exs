defmodule SymphonyElixir.LiveE2ETest do
  @moduledoc """
  Live end-to-end test against a real Teambition org + Codex app-server.

  TODO(teambition): the original Linear-based live e2e flow has been removed
  during the Teambition migration. A Teambition-flavored replacement should:

    1. Create a disposable Teambition project under the configured org
       (`POST /v3/project`), capture its `_id` as project_slug.
    2. Create a task in that project (`POST /v3/task` or appropriate endpoint).
    3. Render WORKFLOW.md against a temp workspace and start the orchestrator.
    4. Wait until the agent posts a workpad comment and moves the task to a
       terminal status.
    5. Assert: comment exists with the expected body, task status terminal,
       project archived.

  Until that flow is wired up, this module is a placeholder so the test suite
  stays green.
  """

  use SymphonyElixir.TestSupport

  @moduletag :live_e2e

  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1",
                          do:
                            "set SYMPHONY_RUN_LIVE_E2E=1 to enable the real Teambition/Codex end-to-end test"
                        )

  @tag skip: @live_e2e_skip_reason || "Teambition live e2e flow not yet implemented"
  test "creates a real Teambition project and task with a local worker" do
    flunk("Teambition live e2e flow not yet implemented")
  end

  @tag skip: @live_e2e_skip_reason || "Teambition live e2e flow not yet implemented"
  test "creates a real Teambition project and task with an ssh worker" do
    flunk("Teambition live e2e flow not yet implemented")
  end
end
