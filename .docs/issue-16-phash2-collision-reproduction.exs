alias Runic.Workflow
alias Runic.Workflow.{Fact, Step}

require Runic

run_parallel_steps = fn workflow, left_name, right_name ->
  {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
  left_runnable = Enum.find(runnables, &(&1.node.name == left_name))
  right_runnable = Enum.find(runnables, &(&1.node.name == right_name))

  executed_left = Workflow.execute_runnable(left_runnable)
  executed_right = Workflow.execute_runnable(right_runnable)

  applied =
    workflow
    |> Workflow.apply_runnable(executed_left)
    |> Workflow.apply_runnable(executed_right)

  %{
    isolated: %{
      left: executed_left.result,
      right: executed_right.result
    },
    applied: applied,
    results: Workflow.results(applied, [left_name, right_name], facts: true, all: true)
  }
end

summarize = fn run, left_name, right_name ->
  left_isolated = run.isolated.left
  right_isolated = run.isolated.right
  left_applied = run.results[left_name] |> List.first()
  right_applied = run.results[right_name] |> List.first()

  %{
    isolated_hashes: {left_isolated.hash, right_isolated.hash},
    isolated_values: {left_isolated.value, right_isolated.value},
    applied_values: {left_applied.value, right_applied.value},
    collision?: left_isolated.hash == right_isolated.hash,
    silently_aliased?:
      left_isolated.value != right_isolated.value and
        left_applied.value == right_applied.value
  }
end

root_hash = Fact.new(value: %{}).hash

# Issue #16's OTP-specific deterministic collision, using its explicit Step.new hashes.
step_new_left =
  Step.new(
    name: "left",
    hash: "probe-step-11396",
    work: fn _input -> %{value: 11_396} end
  )

step_new_right =
  Step.new(
    name: "right",
    hash: "probe-step-19508",
    work: fn _input -> %{value: 19_508} end
  )

step_new_run =
  Workflow.new("issue_16_step_new")
  |> Workflow.add(step_new_left)
  |> Workflow.add(step_new_right)
  |> Workflow.plan_eagerly(%{})
  |> run_parallel_steps.("left", "right")

# Macro construction changes the producer hashes, so the issue's exact values do not
# collide under this ancestry. Runtime context lets us vary results without changing
# the macro-built Step identities, making a second deterministic collision search fair.
macro_left =
  Runic.step(fn _input -> %{value: context(:value)} end,
    name: :left
  )

macro_right =
  Runic.step(fn _input -> %{value: context(:value)} end,
    name: :right
  )

macro_reported_pair_run =
  Workflow.new("issue_16_macro_reported_pair")
  |> Workflow.add(macro_left)
  |> Workflow.add(macro_right)
  |> Workflow.put_run_context(%{
    left: %{value: 11_396},
    right: %{value: 19_508}
  })
  |> Workflow.plan_eagerly(%{})
  |> run_parallel_steps.(:left, :right)

search_limit = 250_000
max_phash = 4_294_967_296

left_hashes =
  Enum.reduce(0..search_limit, %{}, fn value, hashes ->
    basis = {%{value: value}, {macro_left.hash, root_hash}}
    hash = :erlang.phash2(basis, max_phash)

    Map.put_new(hashes, hash, value)
  end)

macro_collision =
  Enum.find_value(0..search_limit, fn right_value ->
    basis = {%{value: right_value}, {macro_right.hash, root_hash}}
    hash = :erlang.phash2(basis, max_phash)

    case Map.fetch(left_hashes, hash) do
      {:ok, left_value} when left_value != right_value ->
        %{hash: hash, left_value: left_value, right_value: right_value}

      _other ->
        nil
    end
  end)

macro_collision_run =
  case macro_collision do
    nil ->
      nil

    %{left_value: left_value, right_value: right_value} ->
      Workflow.new("issue_16_macro_collision")
      |> Workflow.add(macro_left)
      |> Workflow.add(macro_right)
      |> Workflow.put_run_context(%{
        left: %{value: left_value},
        right: %{value: right_value}
      })
      |> Workflow.plan_eagerly(%{})
      |> run_parallel_steps.(:left, :right)
  end

%{
  environment: %{
    elixir: System.version(),
    otp_release: :erlang.system_info(:otp_release) |> List.to_string()
  },
  step_new: summarize.(step_new_run, "left", "right"),
  macro_reported_pair: %{
    step_hashes: {macro_left.hash, macro_right.hash},
    outcome: summarize.(macro_reported_pair_run, :left, :right)
  },
  macro_collision_search: %{
    scheme: :phash2_32_primary,
    range: 0..search_limit,
    collision: macro_collision,
    outcome:
      if(macro_collision_run, do: summarize.(macro_collision_run, :left, :right), else: nil)
  }
}
