defmodule Hassock.ConnectionTest do
  use ExUnit.Case, async: true

  alias Hassock.Connection
  alias Hassock.Connection.State

  # handle_connect/2 runs in the connection process; these tests call it
  # directly, so the test process plays the connection and `controller`
  # plays the controlling process.
  setup do
    controller = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(controller, :kill) end)
    %{controller: controller}
  end

  defp monitors_of(pid) do
    {:monitors, monitors} = Process.info(self(), :monitors)
    Enum.count(monitors, &match?({:process, ^pid}, &1))
  end

  describe "handle_connect/2" do
    test "monitors the controlling process on first connect", %{controller: controller} do
      state = %State{controlling_pid: controller}

      assert {:ok, %State{controlling_monitor: ref}} = Connection.handle_connect(nil, state)
      assert is_reference(ref)
      assert monitors_of(controller) == 1
    end

    test "keeps the existing monitor on reconnect instead of stacking another",
         %{controller: controller} do
      {:ok, state} = Connection.handle_connect(nil, %State{controlling_pid: controller})

      assert {:ok, ^state} = Connection.handle_connect(nil, state)
      assert {:ok, ^state} = Connection.handle_connect(nil, state)
      assert monitors_of(controller) == 1
    end
  end

  describe "lovelace results" do
    # Calls handle_frame/2 directly; the pending entry's reply target is an
    # alias of the test process, so the reply lands in its mailbox.
    defp pending_state(kind) do
      ref = :erlang.alias()
      {ref, %State{authenticated: true, pending: %{7 => {ref, kind}}, next_id: 8}}
    end

    defp services_shaped_result(id) do
      Jason.encode!(%{
        type: "result",
        id: id,
        success: true,
        result: %{strategy: %{options: %{areas: %{}}, type: "original-states"}}
      })
    end

    test "a services-shaped dashboard config reaches the caller unchanged" do
      {ref, state} = pending_state(:lovelace_config)

      assert {:ok, %State{pending: pending}} =
               Connection.handle_frame({:text, services_shaped_result(7)}, state)

      assert pending == %{}
      assert_received {:hassock_response, ^ref, {:ok, %{"strategy" => _}}}
    end

    test "get_services keeps its shape detection" do
      {ref, state} = pending_state(:get_services)
      Connection.handle_frame({:text, services_shaped_result(7)}, state)
      assert_received {:hassock_response, ^ref, {:ok, %{"strategy" => ["options", "type"]}}}
    end

    test "a dashboard list is returned as maps" do
      {ref, state} = pending_state(:lovelace_dashboards)

      json =
        Jason.encode!(%{
          type: "result",
          id: 7,
          success: true,
          result: [%{id: "dashboard_energy", url_path: "dashboard-energy", mode: "storage"}]
        })

      Connection.handle_frame({:text, json}, state)

      assert_received {:hassock_response, ^ref,
                       {:ok, [%{"url_path" => "dashboard-energy", "mode" => "storage"}]}}
    end
  end
end
