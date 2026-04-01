defmodule Hermes.Server.DeferredReplyTest do
  use Hermes.MCP.Case, async: false

  alias Hermes.MCP.Message
  alias Hermes.Server.Base
  alias Hermes.Server.Session

  require Message

  @moduletag capture_log: true

  describe "deferred reply" do
    setup :deferred_server

    test "resolves successfully", %{server: server, session_id: session_id} do
      task =
        Task.async(fn ->
          request = build_request("tools/call", %{"name" => "deferred_tool", "arguments" => %{}})
          GenServer.call(server, {:request, request, session_id, %{}})
        end)

      # Wait for the deferred reply to be registered
      assert_receive {:deferred_registered, ref}, 1000

      # Verify the deferred reply is tracked in state
      state = :sys.get_state(server)
      assert Map.has_key?(state.deferred_replies, ref)

      # Resolve the deferred reply
      result = %{"content" => [%{"type" => "text", "text" => "done"}], "isError" => false}
      Hermes.Server.deferred_reply(server, ref, %{"result" => result})

      # The blocked caller should now get the response
      response = Task.await(task, 2000)
      assert {:ok, encoded} = response
      assert {:ok, [decoded]} = Message.decode(encoded)
      assert decoded["result"] == result

      # Deferred entry should be cleaned up
      state = :sys.get_state(server)
      refute Map.has_key?(state.deferred_replies, ref)
    end

    test "resolves with error response", %{server: server, session_id: session_id} do
      task =
        Task.async(fn ->
          request = build_request("tools/call", %{"name" => "deferred_tool", "arguments" => %{}})
          GenServer.call(server, {:request, request, session_id, %{}})
        end)

      assert_receive {:deferred_registered, ref}, 1000

      # Resolve with an error
      error = %{"code" => -32_000, "message" => "Something went wrong"}
      Hermes.Server.deferred_reply(server, ref, %{"error" => error})

      response = Task.await(task, 2000)
      assert {:ok, encoded} = response
      assert {:ok, [decoded]} = Message.decode(encoded)
      assert decoded["error"]["code"] == -32_000
      assert decoded["error"]["message"] == "Something went wrong"
    end

    test "cancel sends error and notifies cancel_notify pid", %{
      server: server,
      session_id: session_id
    } do
      task =
        Task.async(fn ->
          request =
            build_request("tools/call", %{
              "name" => "deferred_tool_with_cancel",
              "arguments" => %{}
            })

          GenServer.call(server, {:request, request, session_id, %{}})
        end)

      assert_receive {:deferred_registered, ref}, 1000

      # Cancel the deferred reply
      Hermes.Server.cancel_deferred(server, ref)

      # The blocked caller should get an error
      response = Task.await(task, 2000)
      assert {:error, :cancelled} = response

      # cancel_notify pid should receive notification
      assert_receive {:deferred_cancelled, ^ref}, 1000

      # Deferred entry should be cleaned up
      state = :sys.get_state(server)
      refute Map.has_key?(state.deferred_replies, ref)
    end

    test "second deferred_reply on same ref is a no-op", %{
      server: server,
      session_id: session_id
    } do
      task =
        Task.async(fn ->
          request = build_request("tools/call", %{"name" => "deferred_tool", "arguments" => %{}})
          GenServer.call(server, {:request, request, session_id, %{}})
        end)

      assert_receive {:deferred_registered, ref}, 1000

      # First resolve
      result = %{"content" => [%{"type" => "text", "text" => "done"}], "isError" => false}
      Hermes.Server.deferred_reply(server, ref, %{"result" => result})

      # Wait for response
      _response = Task.await(task, 2000)

      # Second resolve should be a no-op (no crash)
      Hermes.Server.deferred_reply(server, ref, %{"result" => result})

      # Give it time to process
      Process.sleep(50)

      # Server should still be alive
      assert Process.alive?(server)
    end

    test "second cancel on same ref is a no-op", %{
      server: server,
      session_id: session_id
    } do
      task =
        Task.async(fn ->
          request =
            build_request("tools/call", %{
              "name" => "deferred_tool_with_cancel",
              "arguments" => %{}
            })

          GenServer.call(server, {:request, request, session_id, %{}})
        end)

      assert_receive {:deferred_registered, ref}, 1000

      Hermes.Server.cancel_deferred(server, ref)

      _response = Task.await(task, 2000)

      # Second cancel should be a no-op
      Hermes.Server.cancel_deferred(server, ref)
      Process.sleep(50)
      assert Process.alive?(server)
    end

    test "caller death triggers cleanup and cancel notification", %{
      server: server,
      session_id: session_id
    } do
      caller_pid =
        spawn(fn ->
          request =
            build_request("tools/call", %{
              "name" => "deferred_tool_with_cancel",
              "arguments" => %{}
            })

          GenServer.call(server, {:request, request, session_id, %{}})
        end)

      # Wait for the deferred reply to be registered
      assert_receive {:deferred_registered, ref}, 1000

      # Verify it's tracked
      state = :sys.get_state(server)
      assert Map.has_key?(state.deferred_replies, ref)

      # Kill the caller
      Process.exit(caller_pid, :kill)

      # Wait for DOWN to be processed
      Process.sleep(100)

      # cancel_notify should receive notification
      assert_receive {:deferred_cancelled, ^ref}, 1000

      # Deferred entry should be cleaned up
      state = :sys.get_state(server)
      refute Map.has_key?(state.deferred_replies, ref)
    end

    test "server_pid is available in frame private", %{
      server: server,
      session_id: session_id
    } do
      task =
        Task.async(fn ->
          request =
            build_request("tools/call", %{
              "name" => "deferred_tool_check_pid",
              "arguments" => %{}
            })

          GenServer.call(server, {:request, request, session_id, %{}})
        end)

      assert_receive {:server_pid, received_pid}, 1000
      assert received_pid == server

      # Wait for deferred registration then clean up
      assert_receive {:deferred_registered, ref}, 1000
      Hermes.Server.deferred_reply(server, ref, %{"result" => %{}})
      Task.await(task, 2000)
    end
  end

  # Setup helper

  defp deferred_server(_ctx) do
    session_id = "test-session-#{System.unique_integer([:positive])}"
    info = %{"name" => "TestClient", "version" => "1.0.0"}

    start_supervised!(Hermes.Server.Registry)

    start_supervised!(
      {Session.Supervisor, server: DeferredStubServer, registry: Hermes.Server.Registry}
    )

    transport = start_supervised!(StubTransport)

    server_opts = [
      module: DeferredStubServer,
      name: Hermes.Server.Registry.server(DeferredStubServer),
      registry: Hermes.Server.Registry,
      transport: [layer: StubTransport, name: transport]
    ]

    server = start_supervised!({Base, server_opts})

    # Initialize the session
    request = init_request(nil, info)
    assert {:ok, _} = GenServer.call(server, {:request, request, session_id, %{}})
    notification = build_notification("notifications/initialized", %{})
    assert :ok = GenServer.cast(server, {:notification, notification, session_id, %{}})

    Process.sleep(50)

    # Register the test pid for the deferred server
    DeferredStubServer.register_test_pid(self())

    %{
      transport: transport,
      server: server,
      session_id: session_id
    }
  end
end
