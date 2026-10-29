Code.require_file("support.exs", __DIR__)

defmodule Runic.Bench.OwnerExecution.Policy do
  @moduledoc false

  alias Runic.Bench.OwnerExecution.Support
  alias Runic.Workflow.{CausalContext, Fact, PolicyDriver, Runnable, SchedulerPolicy, Step}

  @policy_state Runic.Workflow.Dispatch.PolicyState
  @admission Runic.Workflow.Dispatch.Admission
  @command Runic.Workflow.Dispatch.Command

  def run do
    options =
      Support.options!(
        [engine: :string, retained: :integer, attempts: :integer],
        engine: "legacy",
        retained: 1_000_000,
        attempts: 6
      )

    engine = Support.engine!(options)
    retained_count = Support.positive_integer!(options, :retained)
    attempts = Support.positive_integer!(options, :attempts)
    runnable = runnable(retained_count)
    policy = SchedulerPolicy.new(timeout_ms: 5_000)

    report =
      Support.measure(fn ->
        for _attempt <- 1..attempts, do: execute(engine, runnable, policy)
      end)

    unless Enum.all?(report.result, &(&1.status == :completed and &1.result.value == 42)) do
      raise "policy benchmark did not complete"
    end

    Support.print(
      "Owner execution policy memory",
      [engine: engine, retained: retained_count, attempts: attempts],
      report
    )
  end

  defp runnable(retained_count) do
    node = Step.new(work: fn selected -> selected * 2 end, name: :owner_policy_bench)
    fact = Fact.new(value: 21)

    context =
      node.hash
      |> CausalContext.basic(fact, 0)
      |> Map.put(:meta_context, %{retained: Enum.to_list(1..retained_count)})

    Runnable.new(node, fact, context)
  end

  defp execute(:legacy, runnable, policy), do: PolicyDriver.execute(runnable, policy)

  defp execute(:owner, runnable, policy) do
    state = apply(@policy_state, :new, [policy, []])
    {:dispatch, attempted, state, _timeout} = apply(@policy_state, :prepare, [state, runnable])
    {:ok, admission, command} = apply(@admission, :prepare, [attempted, [policy: policy]])
    {:ok, executed} = apply(@admission, :accept, [admission, apply(@command, :run, [command])])
    {:terminal, final, []} = apply(@policy_state, :transition, [state, executed])
    final
  end
end

Runic.Bench.OwnerExecution.Policy.run()
