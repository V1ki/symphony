defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the teambition_api input contract" do
    assert [%{"name" => "teambition_api", "description" => description, "inputSchema" => schema}] =
             DynamicTool.tool_specs()

    assert description =~ "Teambition Open API"
    assert schema["type"] == "object"
    assert schema["required"] == ["path"]
  end

  test "execute returns failure for unsupported tool" do
    response = DynamicTool.execute("unknown_tool", %{})
    assert response["success"] == false
    assert response["output"] =~ "Unsupported dynamic tool"
  end

  test "teambition_api rejects missing path" do
    response = DynamicTool.execute("teambition_api", %{"method" => "GET"})
    assert response["success"] == false
    assert response["output"] =~ "must start with `/v3/...`"
  end

  test "teambition_api rejects bad method" do
    response = DynamicTool.execute("teambition_api", %{"path" => "/v3/task/x", "method" => "PATCH"})
    assert response["success"] == false
    assert response["output"] =~ "Unsupported method"
  end

  test "teambition_api dispatches to the configured client and returns success" do
    fake_client = fn "/v3/task/abc", :get, %{}, [] ->
      {:ok, %{"result" => %{"_id" => "abc", "content" => "demo"}}}
    end

    response =
      DynamicTool.execute(
        "teambition_api",
        %{"path" => "/v3/task/abc"},
        teambition_client: fake_client
      )

    assert response["success"] == true
    assert response["output"] =~ "\"_id\": \"abc\""
  end

  test "teambition_api surfaces upstream errors" do
    fake_client = fn _, _, _, _ -> {:error, {:teambition_api_status, 401}} end

    response =
      DynamicTool.execute(
        "teambition_api",
        %{"path" => "/v3/task/abc"},
        teambition_client: fake_client
      )

    assert response["success"] == false
    assert response["output"] =~ "HTTP 401"
  end
end
