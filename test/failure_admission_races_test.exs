defmodule Runic.FailureAdmissionRacesTest do
  # Holding the scope through its real timer must not compete with unrelated
  # asynchronous suites that have short completion deadlines.
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  require Runic
  alias Runic.Workflow

  for order <- [:result_first, :cancel_first] do
    test "outer timeout preserves the #{order} order at scope acknowledgement" do
      observer = self()
      token = make_ref()
      counts = :atomics.new(1, [])

      step =
        Runic.step(
          fn value ->
            :atomics.add(counts, 1, 1)
            Process.flag(:trap_exit, true)
            send(observer, {token, :held, self(), Runic.TaskScope.current()})
            receive do: (:release -> value + 1)
          end,
          name: :race
        )

      workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()

      {caller, caller_ref} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)
          send(self(), {:keep, token})
          result = Workflow.react_until_satisfied(workflow, 1, async: true, timeout: 1_000)
          send(observer, {token, :returned, result, Process.info(self(), :messages)})
        end)

      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
      assert_receive {^token, :held, work, scope}, 2_000
      work_ref = Process.monitor(work)
      scope_ref = Process.monitor(scope)
      supervisor = :sys.get_state(scope).supervisor
      supervisor_ref = Process.monitor(supervisor)
      :ok = :sys.suspend(scope)

      on_exit(fn ->
        if Process.alive?(scope), do: :sys.resume(scope)
        if Process.alive?(work), do: Process.exit(work, :kill)
      end)

      # Freeze the scope, then observe the actual queued requests. The timer
      # triggers cancellation; queue barriers, not a sleep, establish order.
      if unquote(order) == :result_first do
        send(work, :release)
        assert_receive {:DOWN, ^work_ref, :process, ^work, :normal}, 2_000
        wait_for_message(scope, fn message -> match?({:result, _, _}, message) end)
      end

      {_, _, {:cancel, handle}} =
        wait_for_message(scope, fn message -> match?({:"$gen_call", _, {:cancel, _}}, message) end)

      if unquote(order) == :cancel_first do
        send(work, :release)
        assert_receive {:DOWN, ^work_ref, :process, ^work, :normal}, 2_000
      end

      wait_for_message(scope, fn message -> match?({:result, ^handle, _}, message) end)
      {:messages, queued} = Process.info(scope, :messages)
      result_index = Enum.find_index(queued, &match?({:result, ^handle, _}, &1))
      cancel_index = Enum.find_index(queued, &match?({:"$gen_call", _, {:cancel, ^handle}}, &1))
      assert result_index < cancel_index == (unquote(order) == :result_first)
      :ok = :sys.resume(scope)

      assert_receive {^token, :returned, result, {:messages, [{:keep, ^token}]}}, 2_000
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 2_000
      assert_receive {:DOWN, ^scope_ref, :process, ^scope, :normal}, 2_000
      assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _}, 2_000
      assert :atomics.get(counts, 1) == 1
      assert result.runnable_events == []

      if unquote(order) == :result_first do
        assert Workflow.raw_productions(result) == [2]
        refute Workflow.is_runnable?(result)
      else
        assert Workflow.raw_productions(result) == []
        assert Workflow.is_runnable?(result)
      end
    end
  end

  defp wait_for_message(pid, predicate, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    {:messages, messages} = Process.info(pid, :messages)

    case Enum.find(messages, predicate) do
      nil ->
        assert System.monotonic_time(:millisecond) < deadline, "expected request was not queued"
        :erlang.yield()
        wait_for_message(pid, predicate, deadline)

      message ->
        message
    end
  end
end
