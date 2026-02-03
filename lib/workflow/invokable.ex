defprotocol Runic.Workflow.Invokable do
  @moduledoc """
  Protocol defining how workflow nodes execute within a workflow context.

  The `Invokable` protocol is the runtime heart of Runic. It defines how each node type
  (Step, Condition, Rule, Accumulator, etc.) executes within the context of a workflow,
  enabling extension of Runic's runtime with nodes that have different execution properties
  and evaluation semantics.

  ## Three-Phase Execution Model

  All workflow execution uses a three-phase model that enables parallel execution
  and external scheduler integration:

  ```
  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
  │   PREPARE   │ ───► │   EXECUTE   │ ───► │    APPLY    │
  │  (Phase 1)  │      │  (Phase 2)  │      │  (Phase 3)  │
  └─────────────┘      └─────────────┘      └─────────────┘
        │                    │                    │
        ▼                    ▼                    ▼
   Extract context      Run work fn         Reduce results
   from workflow        in isolation         into workflow
   → %Runnable{}        (parallelizable)     (sequential)
  ```

  1. **Prepare** (`prepare/3`) - Extract minimal context from workflow into a `%Runnable{}` struct
  2. **Execute** (`execute/2`) - Run the node's work function in isolation (can be parallelized)
  3. **Apply** - The `apply_fn` on the Runnable reduces results back into the workflow

  This separation enables:

  - **Parallel execution** of independent nodes (Phase 2 has no workflow access)
  - **External scheduler integration** via `prepare_for_dispatch/1` and `apply_runnable/2`
  - **Distributed execution** by dispatching Runnables to remote workers
  - **Separation of concerns** between pure computation and stateful workflow updates

  ## Protocol Functions

  | Function | Purpose |
  |----------|---------|
  | `match_or_execute/1` | Declares whether node is a `:match` (predicate) or `:execute` (produces facts) |
  | `invoke/3` | High-level API that runs all three phases internally |
  | `prepare/3` | Phase 1: Extract context from workflow, build a `%Runnable{}` |
  | `execute/2` | Phase 2: Run the work function using only Runnable context |

  ## Return Types

  - `prepare/3` returns:
    - `{:ok, %Runnable{}}` - Ready for execution
    - `{:skip, (Workflow.t() -> Workflow.t())}` - Skip with reducer function
    - `{:defer, (Workflow.t() -> Workflow.t())}` - Defer with reducer function

  - `execute/2` returns a `%Runnable{}` with:
    - `status: :completed` - With `result` and `apply_fn` populated
    - `status: :failed` - With `error` populated
    - `status: :skipped` - With `apply_fn` for skip handling

  ## Built-in Implementations

  Runic provides `Invokable` implementations for all core node types:

  | Node Type | Match/Execute | Description |
  |-----------|---------------|-------------|
  | `Runic.Workflow.Root` | `:match` | Entry point for facts into the workflow |
  | `Runic.Workflow.Condition` | `:match` | Boolean predicate check |
  | `Runic.Workflow.Step` | `:execute` | Transform input fact to output fact |
  | `Runic.Workflow.Conjunction` | `:match` | Logical AND of multiple conditions |
  | `Runic.Workflow.MemoryAssertion` | `:match` | Check for facts in workflow memory |
  | `Runic.Workflow.StateCondition` | `:match` | Check accumulator state |
  | `Runic.Workflow.StateReaction` | `:execute` | Produce facts based on accumulator state |
  | `Runic.Workflow.Accumulator` | `:execute` | Stateful reducer across invocations |
  | `Runic.Workflow.Join` | `:execute` | Wait for multiple parent facts before firing |
  | `Runic.Workflow.FanOut` | `:execute` | Spread enumerable into parallel branches |
  | `Runic.Workflow.FanIn` | `:execute` | Collect parallel results back together |

  ## External Scheduler Integration

  The three-phase model enables integration with custom schedulers:

      # Phase 1: Prepare runnables for dispatch
      workflow = Workflow.plan_eagerly(workflow, input)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Phase 2: Execute (dispatch to worker pool, external service, etc.)
      executed = Task.async_stream(runnables, fn runnable ->
        Runic.Workflow.Invokable.execute(runnable.node, runnable)
      end, timeout: :infinity)

      # Phase 3: Apply results back to workflow
      workflow = Enum.reduce(executed, workflow, fn {:ok, runnable}, wrk ->
        Workflow.apply_runnable(wrk, runnable)
      end)

  ## Implementing Custom Invokable

  To create a custom node type, implement the protocol:

      defmodule MyApp.CustomNode do
        defstruct [:hash, :name, :work]
      end

      defimpl Runic.Workflow.Invokable, for: MyApp.CustomNode do
        alias Runic.Workflow
        alias Runic.Workflow.{Fact, Runnable, CausalContext}

        def match_or_execute(_node), do: :execute

        def invoke(%MyApp.CustomNode{} = node, workflow, fact) do
          result = node.work.(fact.value)
          result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

          workflow
          |> Workflow.log_fact(result_fact)
          |> Workflow.draw_connection(node, result_fact, :produced)
          |> Workflow.mark_runnable_as_ran(node, fact)
          |> Workflow.prepare_next_runnables(node, result_fact)
        end

        def prepare(%MyApp.CustomNode{} = node, workflow, fact) do
          context = CausalContext.new(
            node_hash: node.hash,
            input_fact: fact,
            ancestry_depth: Workflow.ancestry_depth(workflow, fact)
          )

          {:ok, Runnable.new(node, fact, context)}
        end

        def execute(%MyApp.CustomNode{} = node, %Runnable{input_fact: fact} = runnable) do
          result = node.work.(fact.value)
          result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

          apply_fn = fn workflow ->
            workflow
            |> Workflow.log_fact(result_fact)
            |> Workflow.draw_connection(node, result_fact, :produced)
            |> Workflow.mark_runnable_as_ran(node, fact)
            |> Workflow.prepare_next_runnables(node, result_fact)
          end

          Runnable.complete(runnable, result_fact, apply_fn)
        end
      end

  See the [Protocols Guide](protocols.html) for more details and examples.
  """

  alias Runic.Workflow.Runnable

  @doc """
  Returns whether this node is a match (predicate/gate) or execute (produces facts) node.
  """
  @spec match_or_execute(node :: struct()) :: :match | :execute
  def match_or_execute(node)

  @doc """
  Legacy invoke function - activates a node in context of a workflow and input fact.
  Returns a new workflow with the node's effects applied.

  During migration, this may delegate to the three-phase prepare/execute/apply cycle.
  """
  @spec invoke(node :: struct(), workflow :: Runic.Workflow.t(), fact :: Runic.Workflow.Fact.t()) ::
          Runic.Workflow.t()
  def invoke(node, workflow, fact)

  @doc """
  Phase 1: Prepare a runnable for execution.

  Extracts minimal context from the workflow needed to execute this node.
  Returns a `%Runnable{}` struct that can be executed independently of the workflow.

  ## Returns

  - `{:ok, %Runnable{}}` - Node is ready for execution
  - `{:skip, reducer_fn}` - Node should be skipped, apply reducer to workflow
  - `{:defer, reducer_fn}` - Node should be deferred, apply reducer to workflow
  """
  @spec prepare(
          node :: struct(),
          workflow :: Runic.Workflow.t(),
          fact :: Runic.Workflow.Fact.t()
        ) ::
          {:ok, Runnable.t()}
          | {:skip, (Runic.Workflow.t() -> Runic.Workflow.t())}
          | {:defer, (Runic.Workflow.t() -> Runic.Workflow.t())}
  def prepare(node, workflow, fact)

  @doc """
  Phase 2: Execute a prepared runnable.

  Runs the node's work function using only the context captured in the Runnable.
  No workflow access is allowed during this phase (enables parallelization).

  Returns the Runnable with:
  - `status` updated to `:completed`, `:failed`, or `:skipped`
  - `result` populated with the execution result
  - `apply_fn` populated with a function to reduce results into the workflow
  """
  @spec execute(node :: struct(), runnable :: Runnable.t()) :: Runnable.t()
  def execute(node, runnable)
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Root do
  alias Runic.Workflow.Root
  alias Runic.Workflow.Fact
  alias Runic.Workflow
  alias Runic.Workflow.{Runnable, CausalContext}

  def match_or_execute(_root), do: :match

  def invoke(%Root{} = root, workflow, fact) do
    workflow
    |> Workflow.log_fact(fact)
    |> Workflow.prepare_next_runnables(root, fact)
  end

  def prepare(%Root{} = root, _workflow, %Fact{} = fact) do
    context =
      CausalContext.new(
        node_hash: nil,
        input_fact: fact,
        ancestry_depth: 0
      )

    {:ok, Runnable.new(nil, root, fact, context)}
  end

  def execute(%Root{} = root, %Runnable{input_fact: fact, context: _ctx} = runnable) do
    apply_fn = fn workflow ->
      workflow
      |> Workflow.log_fact(fact)
      |> Workflow.prepare_next_runnables(root, fact)
    end

    Runnable.complete(runnable, fact, apply_fn)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Condition do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Condition,
    Runnable,
    CausalContext,
    HookRunner
  }

  def match_or_execute(_condition), do: :match

  def invoke(
        %Condition{} = condition,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    if Condition.check(condition, fact) do
      workflow
      |> Workflow.prepare_next_runnables(condition, fact)
      |> Workflow.draw_connection(fact, condition, :satisfied)
      |> Workflow.mark_runnable_as_ran(condition, fact)
      |> Workflow.run_after_hooks(condition, fact)
    else
      workflow
      |> Workflow.mark_runnable_as_ran(condition, fact)
      |> Workflow.run_after_hooks(condition, fact)
    end
  end

  def prepare(%Condition{} = condition, %Workflow{} = workflow, %Fact{} = fact) do
    context =
      CausalContext.new(
        node_hash: condition.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, condition.hash)
      )

    {:ok, Runnable.new(condition, fact, context)}
  end

  def execute(%Condition{} = condition, %Runnable{input_fact: fact, context: ctx} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, condition, fact) do
      satisfied = Condition.check(condition, fact)

      case HookRunner.run_after(ctx, condition, fact, satisfied) do
        {:ok, after_apply_fns} ->
          apply_fn = fn workflow ->
            workflow = Workflow.apply_hook_fns(workflow, before_apply_fns)

            if satisfied do
              workflow
              |> Workflow.prepare_next_runnables(condition, fact)
              |> Workflow.draw_connection(fact, condition, :satisfied)
              |> Workflow.mark_runnable_as_ran(condition, fact)
              |> Workflow.apply_hook_fns(after_apply_fns)
            else
              workflow
              |> Workflow.mark_runnable_as_ran(condition, fact)
              |> Workflow.apply_hook_fns(after_apply_fns)
            end
          end

          Runnable.complete(runnable, satisfied, apply_fn)

        {:error, reason} ->
          Runnable.fail(runnable, {:hook_error, reason})
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Step do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Step,
    Components,
    Runnable,
    CausalContext,
    HookRunner
  }

  def match_or_execute(_step), do: :execute

  def invoke(
        %Step{} = step,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    result = Components.run(step.work, fact.value, Components.arity_of(step.work))

    result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})

    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(step, result_fact, :produced, weight: causal_depth)
    |> Workflow.mark_runnable_as_ran(step, fact)
    |> Workflow.run_after_hooks(step, result_fact)
    |> Workflow.prepare_next_runnables(step, result_fact)
    |> maybe_prepare_map_reduce(step, result_fact)
  end

  def prepare(%Step{} = step, %Workflow{} = workflow, %Fact{} = fact) do
    fan_out_context = build_fan_out_context(workflow, step, fact)

    context =
      CausalContext.new(
        node_hash: step.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, step.hash),
        fan_out_context: fan_out_context
      )

    {:ok, Runnable.new(step, fact, context)}
  end

  def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, step, fact) do
      try do
        result = Components.run(step.work, fact.value, Components.arity_of(step.work))
        result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})

        case HookRunner.run_after(ctx, step, fact, result_fact) do
          {:ok, after_apply_fns} ->
            apply_fn =
              build_apply_fn(step, fact, result_fact, ctx, before_apply_fns, after_apply_fns)

            Runnable.complete(runnable, result_fact, apply_fn)

          {:error, reason} ->
            Runnable.fail(runnable, {:hook_error, reason})
        end
      rescue
        e ->
          Runnable.fail(runnable, e)
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end

  defp build_apply_fn(step, input_fact, result_fact, ctx, before_apply_fns, after_apply_fns) do
    fn workflow ->
      workflow
      |> Workflow.apply_hook_fns(before_apply_fns)
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(step, result_fact, :produced, weight: ctx.ancestry_depth + 1)
      |> Workflow.mark_runnable_as_ran(step, input_fact)
      |> Workflow.apply_hook_fns(after_apply_fns)
      |> Workflow.prepare_next_runnables(step, result_fact)
      |> maybe_prepare_map_reduce(step, result_fact)
    end
  end

  defp build_fan_out_context(workflow, step, fact) do
    if is_reduced_in_map?(workflow, step) do
      case find_fan_out_info(workflow, fact) do
        {source_fact_hash, fan_out_hash, fan_out_fact_hash} ->
          %{
            is_reduced: true,
            source_fact_hash: source_fact_hash,
            fan_out_hash: fan_out_hash,
            fan_out_fact_hash: fan_out_fact_hash
          }

        nil ->
          nil
      end
    else
      nil
    end
  end

  defp is_reduced_in_map?(workflow, step) do
    MapSet.member?(workflow.mapped.mapped_paths, step.hash)
  end

  defp maybe_prepare_map_reduce(workflow, step, fact) do
    if is_reduced_in_map?(workflow, step) do
      # Find the fan_out info: {source_fact_hash, fan_out_hash, fan_out_fact_hash}
      case find_fan_out_info(workflow, fact) do
        {source_fact_hash, fan_out_hash, fan_out_fact_hash} ->
          # Key using source_fact.hash (the input to FanOut) - stable across merges
          key = {source_fact_hash, step.hash}
          seen = workflow.mapped[key] || %{}

          # Track which fan_out fact produced this step output
          seen = Map.put(seen, fan_out_fact_hash, fact.hash)

          # Also store the fan_out_hash so FanIn can find the expected list
          workflow = store_fan_out_hash_for_batch(workflow, source_fact_hash, fan_out_hash)

          Map.put(workflow, :mapped, Map.put(workflow.mapped, key, seen))

        nil ->
          workflow
      end
    else
      workflow
    end
  end

  # Store the fan_out hash for a batch so FanIn can look up the expected list
  defp store_fan_out_hash_for_batch(workflow, source_fact_hash, fan_out_hash) do
    key = {:fan_out_for_batch, source_fact_hash}
    Map.put(workflow, :mapped, Map.put(workflow.mapped, key, fan_out_hash))
  end

  @doc false
  def fan_out_origin_fact_hash(workflow, %Runic.Workflow.Fact{
        ancestry: {_producer_hash, input_fact_hash}
      }) do
    # Walk up the ancestry chain to find the fact that was produced by a FanOut
    find_fan_out_origin(workflow, input_fact_hash)
  end

  def fan_out_origin_fact_hash(_workflow, _fact), do: nil

  # Returns {source_fact_hash, fan_out_hash, fan_out_fact_hash} or nil
  defp find_fan_out_info(workflow, %Runic.Workflow.Fact{
         ancestry: {_producer_hash, input_fact_hash}
       }) do
    do_find_fan_out_info(workflow, input_fact_hash)
  end

  defp find_fan_out_info(_workflow, _fact), do: nil

  defp do_find_fan_out_info(_workflow, nil), do: nil

  defp do_find_fan_out_info(workflow, fact_hash) do
    fact = workflow.graph.vertices[fact_hash]

    case fact do
      %Runic.Workflow.Fact{ancestry: {producer_hash, parent_fact_hash}} ->
        producer = workflow.graph.vertices[producer_hash]

        case producer do
          %Runic.Workflow.FanOut{} = fan_out ->
            # This fact was produced by a FanOut
            # parent_fact_hash is the source_fact that triggered the FanOut
            {parent_fact_hash, fan_out.hash, fact_hash}

          _ ->
            # Keep walking up the ancestry chain
            do_find_fan_out_info(workflow, parent_fact_hash)
        end

      _ ->
        nil
    end
  end

  defp find_fan_out_origin(_workflow, nil), do: nil

  defp find_fan_out_origin(workflow, fact_hash) do
    fact = workflow.graph.vertices[fact_hash]

    case fact do
      %Runic.Workflow.Fact{ancestry: {producer_hash, parent_fact_hash}} ->
        producer = workflow.graph.vertices[producer_hash]

        case producer do
          %Runic.Workflow.FanOut{} ->
            # This fact was produced by a FanOut - this is the origin we want
            fact_hash

          _ ->
            # Keep walking up the ancestry chain
            find_fan_out_origin(workflow, parent_fact_hash)
        end

      _ ->
        nil
    end
  end

  # def runnable_connection(_step), do: :runnable
  # def resolved_connection(_step), do: :ran
  # def causal_connection(_step), do: :produced
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Conjunction do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Conjunction,
    Runnable,
    CausalContext
  }

  def match_or_execute(_conjunction), do: :match

  def invoke(
        %Conjunction{} = conj,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    satisfied_conditions = Workflow.satisfied_condition_hashes(workflow, fact)

    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    if conj.hash not in satisfied_conditions and
         Enum.all?(conj.condition_hashes, &(&1 in satisfied_conditions)) do
      workflow
      |> Workflow.prepare_next_runnables(conj, fact)
      |> Workflow.draw_connection(fact, conj, :satisfied, weight: causal_depth)
      |> Workflow.mark_runnable_as_ran(conj, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, conj, fact)
    end
  end

  def prepare(%Conjunction{} = conj, %Workflow{} = workflow, %Fact{} = fact) do
    satisfied_conditions = Workflow.satisfied_condition_hashes(workflow, fact)

    context =
      CausalContext.new(
        node_hash: conj.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        satisfied_conditions: MapSet.new(satisfied_conditions)
      )

    {:ok, Runnable.new(conj, fact, context)}
  end

  def execute(%Conjunction{} = conj, %Runnable{input_fact: fact, context: ctx} = runnable) do
    satisfied_conditions = ctx.satisfied_conditions

    all_satisfied =
      conj.hash not in satisfied_conditions and
        Enum.all?(conj.condition_hashes, &(&1 in satisfied_conditions))

    apply_fn = fn workflow ->
      if all_satisfied do
        workflow
        |> Workflow.prepare_next_runnables(conj, fact)
        |> Workflow.draw_connection(fact, conj, :satisfied, weight: ctx.ancestry_depth + 1)
        |> Workflow.mark_runnable_as_ran(conj, fact)
      else
        Workflow.mark_runnable_as_ran(workflow, conj, fact)
      end
    end

    Runnable.complete(runnable, all_satisfied, apply_fn)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.MemoryAssertion do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    MemoryAssertion,
    Runnable,
    CausalContext
  }

  def match_or_execute(_memory_assertion), do: :match

  def invoke(
        %MemoryAssertion{} = ma,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    if ma.memory_assertion.(workflow, fact) do
      causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

      workflow
      |> Workflow.draw_connection(fact, ma, :satisfied, weight: causal_depth)
      |> Workflow.mark_runnable_as_ran(ma, fact)
      |> Workflow.prepare_next_runnables(ma, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, ma, fact)
    end
  end

  # MemoryAssertion requires full workflow access, so we execute the assertion
  # during the prepare phase (not parallelizable)
  def prepare(%MemoryAssertion{} = ma, %Workflow{} = workflow, %Fact{} = fact) do
    # Execute the assertion during prepare since it needs full workflow
    assertion_result = ma.memory_assertion.(workflow, fact)

    context =
      CausalContext.new(
        node_hash: ma.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact)
      )

    # Store the pre-computed result in the context via a custom field
    context = Map.put(context, :memory_snapshot, assertion_result)

    {:ok, Runnable.new(ma, fact, context)}
  end

  def execute(%MemoryAssertion{} = _ma, %Runnable{context: ctx} = runnable) do
    # Result was already computed in prepare phase
    satisfied = Map.get(ctx, :memory_snapshot, false)

    apply_fn = fn workflow ->
      if satisfied do
        workflow
        |> Workflow.draw_connection(ctx.input_fact, runnable.node, :satisfied,
          weight: ctx.ancestry_depth + 1
        )
        |> Workflow.mark_runnable_as_ran(runnable.node, ctx.input_fact)
        |> Workflow.prepare_next_runnables(runnable.node, ctx.input_fact)
      else
        Workflow.mark_runnable_as_ran(workflow, runnable.node, ctx.input_fact)
      end
    end

    Runnable.complete(runnable, satisfied, apply_fn)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.StateReaction do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Components,
    StateReaction,
    Runnable,
    CausalContext,
    HookRunner
  }

  def match_or_execute(_state_reaction), do: :execute

  def invoke(
        %StateReaction{} = sr,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    last_known_state = Workflow.last_known_state(workflow, sr)

    result = Components.run(sr.work, last_known_state, sr.arity)

    unless result == {:error, :no_match_of_lhs_in_reactor_fn} do
      result_fact = Fact.new(value: result, ancestry: {sr.hash, fact.hash})

      causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

      workflow
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(sr, result_fact, :produced, weight: causal_depth)
      |> Workflow.run_after_hooks(sr, result_fact)
      |> Workflow.prepare_next_runnables(sr, result_fact)
      |> Workflow.mark_runnable_as_ran(sr, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, sr, fact)
    end
  end

  def prepare(%StateReaction{} = sr, %Workflow{} = workflow, %Fact{} = fact) do
    last_known_state = Workflow.last_known_state(workflow, sr)

    context =
      CausalContext.new(
        node_hash: sr.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, sr.hash),
        last_known_state: last_known_state,
        is_state_initialized: not is_nil(last_known_state),
        mergeable: sr.mergeable
      )

    {:ok, Runnable.new(sr, fact, context)}
  end

  def execute(%StateReaction{} = sr, %Runnable{input_fact: fact, context: ctx} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, sr, fact) do
      result = Components.run(sr.work, ctx.last_known_state, sr.arity)

      if result == {:error, :no_match_of_lhs_in_reactor_fn} do
        apply_fn = fn workflow ->
          Workflow.mark_runnable_as_ran(workflow, sr, fact)
        end

        Runnable.complete(runnable, :no_match, apply_fn)
      else
        result_fact = Fact.new(value: result, ancestry: {sr.hash, fact.hash})

        case HookRunner.run_after(ctx, sr, fact, result_fact) do
          {:ok, after_apply_fns} ->
            apply_fn = fn workflow ->
              workflow
              |> Workflow.apply_hook_fns(before_apply_fns)
              |> Workflow.log_fact(result_fact)
              |> Workflow.draw_connection(sr, result_fact, :produced,
                weight: ctx.ancestry_depth + 1
              )
              |> Workflow.apply_hook_fns(after_apply_fns)
              |> Workflow.prepare_next_runnables(sr, result_fact)
              |> Workflow.mark_runnable_as_ran(sr, fact)
            end

            Runnable.complete(runnable, result_fact, apply_fn)

          {:error, reason} ->
            Runnable.fail(runnable, {:hook_error, reason})
        end
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.StateCondition do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    StateCondition,
    Runnable,
    CausalContext
  }

  def match_or_execute(_state_condition), do: :match

  def invoke(
        %StateCondition{} = sc,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    last_known_state = Workflow.last_known_state(workflow, sc)

    sc_result = sc.work.(fact.value, last_known_state)

    if sc_result do
      causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

      workflow
      |> Workflow.prepare_next_runnables(sc, fact)
      |> Workflow.draw_connection(fact, sc, :satisfied, weight: causal_depth)
      |> Workflow.mark_runnable_as_ran(sc, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, sc, fact)
    end
  end

  def prepare(%StateCondition{} = sc, %Workflow{} = workflow, %Fact{} = fact) do
    last_known_state = Workflow.last_known_state(workflow, sc)

    context =
      CausalContext.new(
        node_hash: sc.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        last_known_state: last_known_state,
        is_state_initialized: not is_nil(last_known_state)
      )

    {:ok, Runnable.new(sc, fact, context)}
  end

  def execute(%StateCondition{} = sc, %Runnable{input_fact: fact, context: ctx} = runnable) do
    satisfied = sc.work.(fact.value, ctx.last_known_state)

    apply_fn = fn workflow ->
      if satisfied do
        workflow
        |> Workflow.prepare_next_runnables(sc, fact)
        |> Workflow.draw_connection(fact, sc, :satisfied, weight: ctx.ancestry_depth + 1)
        |> Workflow.mark_runnable_as_ran(sc, fact)
      else
        Workflow.mark_runnable_as_ran(workflow, sc, fact)
      end
    end

    Runnable.complete(runnable, satisfied, apply_fn)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Accumulator do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Components,
    Accumulator,
    Runnable,
    CausalContext,
    HookRunner
  }

  def match_or_execute(_state_reactor), do: :execute

  def invoke(
        %Accumulator{} = acc,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    last_known_state = last_known_state(workflow, acc)

    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    unless is_nil(last_known_state) do
      next_state = apply(acc.reducer, [fact.value, last_known_state.value])

      next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

      workflow
      |> Workflow.log_fact(next_state_produced_fact)
      |> Workflow.draw_connection(acc, fact, :state_produced, weight: causal_depth)
      |> Workflow.mark_runnable_as_ran(acc, fact)
      |> Workflow.run_after_hooks(acc, next_state_produced_fact)
      |> Workflow.prepare_next_runnables(acc, next_state_produced_fact)
    else
      init_fact = init_fact(acc)

      next_state = apply(acc.reducer, [fact.value, init_fact.value])

      next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

      workflow
      |> Workflow.log_fact(init_fact)
      |> Workflow.draw_connection(acc, init_fact, :state_initiated, weight: causal_depth)
      |> Workflow.log_fact(next_state_produced_fact)
      |> Workflow.draw_connection(acc, next_state_produced_fact, :state_produced,
        weight: causal_depth
      )
      |> Workflow.mark_runnable_as_ran(acc, fact)
      |> Workflow.run_after_hooks(acc, next_state_produced_fact)
      |> Workflow.prepare_next_runnables(acc, next_state_produced_fact)
    end
  end

  def prepare(%Accumulator{} = acc, %Workflow{} = workflow, %Fact{} = fact) do
    last_state_fact = last_known_state(workflow, acc)

    context =
      CausalContext.new(
        node_hash: acc.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, acc.hash),
        last_known_state: if(last_state_fact, do: last_state_fact.value, else: nil),
        is_state_initialized: not is_nil(last_state_fact),
        mergeable: acc.mergeable
      )

    {:ok, Runnable.new(acc, fact, context)}
  end

  def execute(%Accumulator{} = acc, %Runnable{input_fact: fact, context: ctx} = runnable) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, acc, fact) do
      if ctx.is_state_initialized do
        next_state = apply(acc.reducer, [fact.value, ctx.last_known_state])
        next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

        case HookRunner.run_after(ctx, acc, fact, next_state_produced_fact) do
          {:ok, after_apply_fns} ->
            apply_fn =
              build_apply_fn_initialized(
                acc,
                fact,
                next_state_produced_fact,
                ctx,
                before_apply_fns,
                after_apply_fns
              )

            Runnable.complete(runnable, next_state_produced_fact, apply_fn)

          {:error, reason} ->
            Runnable.fail(runnable, {:hook_error, reason})
        end
      else
        init_fact_val = acc.init.()

        init_fact =
          Fact.new(
            value: init_fact_val,
            ancestry: {acc.hash, Components.fact_hash(init_fact_val)}
          )

        next_state = apply(acc.reducer, [fact.value, init_fact_val])
        next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

        case HookRunner.run_after(ctx, acc, fact, next_state_produced_fact) do
          {:ok, after_apply_fns} ->
            apply_fn =
              build_apply_fn_uninitialized(
                acc,
                fact,
                init_fact,
                next_state_produced_fact,
                ctx,
                before_apply_fns,
                after_apply_fns
              )

            Runnable.complete(runnable, next_state_produced_fact, apply_fn)

          {:error, reason} ->
            Runnable.fail(runnable, {:hook_error, reason})
        end
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end

  defp build_apply_fn_initialized(
         acc,
         input_fact,
         result_fact,
         ctx,
         before_apply_fns,
         after_apply_fns
       ) do
    fn workflow ->
      workflow
      |> Workflow.apply_hook_fns(before_apply_fns)
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(acc, input_fact, :state_produced,
        weight: ctx.ancestry_depth + 1
      )
      |> Workflow.mark_runnable_as_ran(acc, input_fact)
      |> Workflow.apply_hook_fns(after_apply_fns)
      |> Workflow.prepare_next_runnables(acc, result_fact)
    end
  end

  defp build_apply_fn_uninitialized(
         acc,
         input_fact,
         init_fact,
         result_fact,
         ctx,
         before_apply_fns,
         after_apply_fns
       ) do
    fn workflow ->
      workflow
      |> Workflow.apply_hook_fns(before_apply_fns)
      |> Workflow.log_fact(init_fact)
      |> Workflow.draw_connection(acc, init_fact, :state_initiated,
        weight: ctx.ancestry_depth + 1
      )
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(acc, result_fact, :state_produced,
        weight: ctx.ancestry_depth + 1
      )
      |> Workflow.mark_runnable_as_ran(acc, input_fact)
      |> Workflow.apply_hook_fns(after_apply_fns)
      |> Workflow.prepare_next_runnables(acc, result_fact)
    end
  end

  defp last_known_state(workflow, accumulator) do
    workflow.graph
    |> Graph.out_edges(accumulator, by: :state_produced)
    |> List.first(%{})
    |> Map.get(:v2)
  end

  defp init_fact(%Accumulator{init: init, hash: hash}) do
    init = init.()
    Fact.new(value: init, ancestry: {hash, Components.fact_hash(init)})
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Join do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Join,
    Runnable,
    CausalContext
  }

  def match_or_execute(_join), do: :execute

  def invoke(
        %Join{} = join,
        %Workflow{} = workflow,
        %Fact{ancestry: {_parent_hash, _value_hash}} = fact
      ) do
    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    workflow =
      Workflow.draw_connection(workflow, fact, join, :joined, weight: causal_depth)

    join_order_weights =
      join.joins
      |> Enum.with_index()
      |> Map.new()

    joined_edges =
      workflow.graph
      |> Graph.in_edges(join)
      |> Enum.filter(&(&1.label == :joined))

    possible_priors_by_parent =
      joined_edges
      |> Enum.reduce(%{}, fn edge, acc ->
        parent_hash = elem(edge.v1.ancestry, 0)

        if Map.has_key?(join_order_weights, parent_hash) and not Map.has_key?(acc, parent_hash) do
          Map.put(acc, parent_hash, edge.v1)
        else
          acc
        end
      end)

    possible_priors =
      join.joins
      |> Enum.map(&Map.get(possible_priors_by_parent, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.value)

    if Enum.count(join.joins) == Enum.count(possible_priors) do
      join_bindings_fact = Fact.new(value: possible_priors, ancestry: {join.hash, fact.hash})

      workflow =
        workflow
        |> Workflow.log_fact(join_bindings_fact)
        |> Workflow.prepare_next_runnables(join, join_bindings_fact)

      workflow.graph
      |> Graph.in_edges(join)
      |> Enum.filter(&(&1.label in [:runnable, :joined]))
      |> Enum.reduce(workflow, fn
        %{v1: v1, label: :runnable}, wrk ->
          Workflow.mark_runnable_as_ran(wrk, join, v1)

        %{v1: v1, v2: v2, label: :joined}, wrk ->
          %Workflow{
            wrk
            | graph:
                wrk.graph |> Graph.update_labelled_edge(v1, v2, :joined, label: :join_satisfied)
          }
      end)
      |> Workflow.draw_connection(join, join_bindings_fact, :produced, weight: causal_depth)
      |> Workflow.run_after_hooks(join, join_bindings_fact)
    else
      Workflow.mark_runnable_as_ran(workflow, join, fact)
    end
  end

  def prepare(%Join{} = join, %Workflow{} = workflow, %Fact{} = fact) do
    join_order_weights =
      join.joins
      |> Enum.with_index()
      |> Map.new()

    # Get current join state from graph
    joined_edges =
      workflow.graph
      |> Graph.in_edges(join)
      |> Enum.filter(&(&1.label == :joined))

    # Collect satisfied facts by parent
    satisfied_by_parent =
      joined_edges
      |> Enum.reduce(%{}, fn edge, acc ->
        parent_hash = elem(edge.v1.ancestry, 0)

        if Map.has_key?(join_order_weights, parent_hash) and not Map.has_key?(acc, parent_hash) do
          Map.put(acc, parent_hash, edge.v1)
        else
          acc
        end
      end)

    # Check if adding this fact would complete the join
    current_fact_parent = elem(fact.ancestry, 0)

    satisfied_with_current =
      if Map.has_key?(join_order_weights, current_fact_parent) do
        Map.put(satisfied_by_parent, current_fact_parent, fact)
      else
        satisfied_by_parent
      end

    would_complete = map_size(satisfied_with_current) >= length(join.joins)

    # Collect values in order if would complete
    collected_values =
      if would_complete do
        join.joins
        |> Enum.map(&Map.get(satisfied_with_current, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.value)
      else
        nil
      end

    context =
      CausalContext.new(
        node_hash: join.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, join.hash),
        join_context: %{
          joins: join.joins,
          satisfied: satisfied_by_parent,
          would_complete: would_complete,
          values: collected_values
        }
      )

    {:ok, Runnable.new(join, fact, context)}
  end

  def execute(%Join{} = join, %Runnable{input_fact: fact, context: ctx} = runnable) do
    if ctx.join_context.would_complete do
      join_fact = Fact.new(value: ctx.join_context.values, ancestry: {join.hash, fact.hash})

      apply_fn = fn workflow ->
        workflow
        |> Workflow.run_before_hooks(join, fact)
        |> Workflow.draw_connection(fact, join, :joined, weight: ctx.ancestry_depth + 1)
        |> Workflow.log_fact(join_fact)
        |> Workflow.prepare_next_runnables(join, join_fact)
        |> mark_all_joined_edges(join)
        |> Workflow.draw_connection(join, join_fact, :produced, weight: ctx.ancestry_depth + 1)
        |> Workflow.run_after_hooks(join, join_fact)
      end

      Runnable.complete(runnable, join_fact, apply_fn)
    else
      apply_fn = fn workflow ->
        # Draw the joined edge first
        workflow =
          Workflow.draw_connection(workflow, fact, join, :joined, weight: ctx.ancestry_depth + 1)

        # Recheck if join can complete now (handles parallel execution case)
        # where multiple facts arrive at the same join in the same batch
        join_order_weights =
          join.joins
          |> Enum.with_index()
          |> Map.new()

        joined_edges =
          workflow.graph
          |> Graph.in_edges(join)
          |> Enum.filter(&(&1.label == :joined))

        satisfied_by_parent =
          joined_edges
          |> Enum.reduce(%{}, fn edge, acc ->
            parent_hash = elem(edge.v1.ancestry, 0)

            if Map.has_key?(join_order_weights, parent_hash) and
                 not Map.has_key?(acc, parent_hash) do
              Map.put(acc, parent_hash, edge.v1)
            else
              acc
            end
          end)

        can_complete_now = map_size(satisfied_by_parent) >= length(join.joins)

        if can_complete_now do
          collected_values =
            join.joins
            |> Enum.map(&Map.get(satisfied_by_parent, &1))
            |> Enum.reject(&is_nil/1)
            |> Enum.map(& &1.value)

          join_fact = Fact.new(value: collected_values, ancestry: {join.hash, fact.hash})

          workflow
          |> Workflow.run_before_hooks(join, fact)
          |> Workflow.log_fact(join_fact)
          |> Workflow.prepare_next_runnables(join, join_fact)
          |> mark_all_joined_edges(join)
          |> Workflow.draw_connection(join, join_fact, :produced, weight: ctx.ancestry_depth + 1)
          |> Workflow.run_after_hooks(join, join_fact)
        else
          Workflow.mark_runnable_as_ran(workflow, join, fact)
        end
      end

      Runnable.complete(runnable, :waiting, apply_fn)
    end
  end

  defp mark_all_joined_edges(workflow, join) do
    workflow.graph
    |> Graph.in_edges(join)
    |> Enum.filter(&(&1.label in [:runnable, :joined]))
    |> Enum.reduce(workflow, fn
      %{v1: v1, label: :runnable}, wrk ->
        Workflow.mark_runnable_as_ran(wrk, join, v1)

      %{v1: v1, v2: v2, label: :joined}, wrk ->
        %Workflow{
          wrk
          | graph:
              wrk.graph |> Graph.update_labelled_edge(v1, v2, :joined, label: :join_satisfied)
        }
    end)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.FanOut do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    FanOut,
    Runnable,
    CausalContext
  }

  def match_or_execute(_fan_out), do: :execute

  def invoke(
        %FanOut{} = fan_out,
        %Workflow{} = workflow,
        %Fact{} = source_fact
      ) do
    unless is_nil(Enumerable.impl_for(source_fact.value)) do
      is_reduced? = is_reduced?(workflow, fan_out)

      causal_depth = Workflow.ancestry_depth(workflow, source_fact) + 1

      Enum.reduce(source_fact.value, workflow, fn value, wrk ->
        fact =
          Fact.new(value: value, ancestry: {fan_out.hash, source_fact.hash})

        wrk
        |> Workflow.log_fact(fact)
        |> Workflow.prepare_next_runnables(fan_out, fact)
        |> Workflow.draw_connection(fan_out, fact, :fan_out, weight: causal_depth)
        |> maybe_prepare_map_reduce(is_reduced?, fan_out, fact, source_fact)
      end)
      |> Workflow.mark_runnable_as_ran(fan_out, source_fact)
    else
      Workflow.mark_runnable_as_ran(workflow, fan_out, source_fact)
    end
  end

  def prepare(%FanOut{} = fan_out, %Workflow{} = workflow, %Fact{} = fact) do
    if is_nil(Enumerable.impl_for(fact.value)) do
      {:skip, fn wf -> Workflow.mark_runnable_as_ran(wf, fan_out, fact) end}
    else
      is_reduced = is_reduced?(workflow, fan_out)

      context =
        CausalContext.new(
          node_hash: fan_out.hash,
          input_fact: fact,
          ancestry_depth: Workflow.ancestry_depth(workflow, fact),
          fan_out_context: %{
            is_reduced: is_reduced,
            source_fact_hash: fact.hash
          }
        )

      {:ok, Runnable.new(fan_out, fact, context)}
    end
  end

  def execute(%FanOut{} = fan_out, %Runnable{input_fact: source_fact, context: ctx} = runnable) do
    values = Enum.to_list(source_fact.value)

    apply_fn = fn workflow ->
      is_reduced = ctx.fan_out_context.is_reduced

      Enum.reduce(values, workflow, fn value, wrk ->
        fact = Fact.new(value: value, ancestry: {fan_out.hash, source_fact.hash})

        wrk
        |> Workflow.log_fact(fact)
        |> Workflow.prepare_next_runnables(fan_out, fact)
        |> Workflow.draw_connection(fan_out, fact, :fan_out, weight: ctx.ancestry_depth + 1)
        |> maybe_prepare_map_reduce(is_reduced, fan_out, fact, source_fact)
      end)
      |> Workflow.mark_runnable_as_ran(fan_out, source_fact)
    end

    Runnable.complete(runnable, values, apply_fn)
  end

  defp maybe_prepare_map_reduce(workflow, true, fan_out, fan_out_fact, source_fact) do
    key = {source_fact.hash, fan_out.hash}
    sister_facts = workflow.mapped[key] || []

    Map.put(workflow, :mapped, Map.put(workflow.mapped, key, [fan_out_fact.hash | sister_facts]))
  end

  defp maybe_prepare_map_reduce(workflow, false, _fan_out, _fan_out_fact, _source_fact) do
    workflow
  end

  def is_reduced?(workflow, fan_out) do
    Graph.out_edges(workflow.graph, fan_out) |> Enum.any?(&(&1.label == :fan_in))
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.FanIn do
  alias Runic.Workflow.FanOut
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    FanIn,
    Runnable,
    CausalContext,
    HookRunner
  }

  def match_or_execute(_fan_in), do: :execute

  def invoke(
        %FanIn{} = fan_in,
        %Workflow{} = workflow,
        %Fact{ancestry: {parent_step_hash, _parent_fact_hash}} = fact
      ) do
    fan_out =
      workflow.graph
      |> Graph.in_edges(fan_in)
      |> Enum.filter(&(&1.label == :fan_in))
      |> List.first(%{})
      |> Map.get(:v1)

    causal_depth = Workflow.ancestry_depth(workflow, fact) + 1

    case fan_out do
      nil ->
        # basic step w/ enumerable output -> fan_in
        reduced_value = reduce_with_while(fact.value, fan_in.init.(), fan_in.reducer)

        reduced_fact =
          Fact.new(value: reduced_value, ancestry: {fan_in.hash, fact.hash})

        workflow
        |> Workflow.log_fact(reduced_fact)
        |> Workflow.draw_connection(fan_in, reduced_fact, :reduced, weight: causal_depth)
        |> Workflow.run_after_hooks(fan_in, reduced_fact)
        |> Workflow.prepare_next_runnables(fan_in, reduced_fact)
        |> Workflow.mark_runnable_as_ran(fan_in, fact)

      %FanOut{} ->
        # Find the source_fact_hash that triggered the FanOut batch
        # This is stable across workflow merges and re-planning
        source_fact_hash = find_fan_out_source_fact_hash(workflow, fact)

        # Check if this batch has already been reduced by looking for a :reduced edge
        # This is more robust than checking mapped data which may not survive merges
        already_completed? = has_reduced_output?(workflow, fan_in, source_fact_hash)

        # Also check mapped data as a fallback
        completed_key = {:fan_in_completed, source_fact_hash, fan_in.hash}
        already_completed? = already_completed? or Map.get(workflow.mapped, completed_key, false)

        # Use source_fact_hash based keys (stable across merges)
        expected_key = {source_fact_hash, fan_out.hash}
        seen_key = {source_fact_hash, parent_step_hash}

        expected_list = workflow.mapped[expected_key] || []
        expected_set = MapSet.new(expected_list)

        seen_map = workflow.mapped[seen_key] || %{}
        seen_set = MapSet.new(Map.keys(seen_map))

        ready? =
          not already_completed? and
            not Enum.empty?(expected_set) and
            MapSet.equal?(expected_set, seen_set)

        # DEBUG: Uncomment to trace FanIn readiness issues
        # IO.inspect(%{
        #   fan_in_map: fan_in.map,
        #   source_fact_hash: source_fact_hash,
        #   expected_list_size: length(expected_list),
        #   seen_map_size: map_size(seen_map),
        #   ready?: ready?,
        #   already_completed?: already_completed?,
        #   fact_hash: fact.hash
        # }, label: "FanIn.invoke DEBUG")

        if ready? do
          # reduce in FanOut emission order (list was prepended, so reverse)
          expected_in_order = Enum.reverse(expected_list)

          sister_fact_values =
            for origin <- expected_in_order do
              sister_hash = seen_map[origin]
              workflow.graph.vertices[sister_hash].value
            end

          reduced_value = reduce_with_while(sister_fact_values, fan_in.init.(), fan_in.reducer)

          reduced_fact =
            Fact.new(value: reduced_value, ancestry: {fan_in.hash, fact.hash})

          sister_facts =
            for origin <- expected_in_order do
              sister_hash = seen_map[origin]
              workflow.graph.vertices[sister_hash]
            end

          workflow =
            Enum.reduce(sister_facts, workflow, fn sister_fact, wrk ->
              Workflow.mark_runnable_as_ran(wrk, fan_in, sister_fact)
            end)

          workflow
          |> Workflow.log_fact(reduced_fact)
          |> Workflow.draw_connection(fan_in, reduced_fact, :reduced, weight: causal_depth)
          |> Workflow.run_after_hooks(fan_in, reduced_fact)
          |> Workflow.prepare_next_runnables(fan_in, reduced_fact)
          |> Workflow.mark_runnable_as_ran(fan_in, reduced_fact)
          |> mark_fan_in_completed(completed_key)
          |> cleanup_mapped(expected_key, seen_key, source_fact_hash)
        else
          workflow
          |> Workflow.mark_runnable_as_ran(fan_in, fact)
        end
    end
  end

  # Find the source_fact hash that triggered the FanOut
  # This walks up the ancestry chain from the current fact to find the FanOut producer,
  # then returns its parent (the source_fact that was input to the FanOut)
  defp find_fan_out_source_fact_hash(workflow, %Fact{ancestry: {_producer_hash, input_fact_hash}}) do
    do_find_fan_out_source(workflow, input_fact_hash)
  end

  defp do_find_fan_out_source(_workflow, nil), do: nil

  defp do_find_fan_out_source(workflow, fact_hash) do
    fact = workflow.graph.vertices[fact_hash]

    case fact do
      %Fact{ancestry: {producer_hash, parent_fact_hash}} ->
        producer = workflow.graph.vertices[producer_hash]

        case producer do
          %FanOut{} ->
            # This fact was produced by a FanOut
            # Return the parent_fact_hash which is the source_fact that triggered FanOut
            parent_fact_hash

          _ ->
            # Keep walking up the ancestry chain
            do_find_fan_out_source(workflow, parent_fact_hash)
        end

      _ ->
        nil
    end
  end

  # Mark that this FanIn has completed for this batch - survives merges
  defp mark_fan_in_completed(workflow, completed_key) do
    Map.put(workflow, :mapped, Map.put(workflow.mapped, completed_key, true))
  end

  # Check if FanIn has already produced a :reduced output for this batch
  # by checking if there's a fact with ancestry matching (fan_in.hash, _) 
  # that traces back to this source_fact_hash
  defp has_reduced_output?(workflow, fan_in, source_fact_hash) do
    workflow.graph
    |> Graph.out_edges(fan_in)
    |> Enum.any?(fn edge ->
      edge.label == :reduced and
        traces_to_source_fact?(workflow, edge.v2, source_fact_hash)
    end)
  end

  defp traces_to_source_fact?(_workflow, %Fact{ancestry: nil}, _source_fact_hash), do: false

  defp traces_to_source_fact?(
         workflow,
         %Fact{ancestry: {_producer_hash, parent_fact_hash}},
         source_fact_hash
       ) do
    cond do
      parent_fact_hash == source_fact_hash ->
        true

      is_nil(parent_fact_hash) ->
        false

      true ->
        # Check if parent fact is the source or traces to it
        parent_fact = workflow.graph.vertices[parent_fact_hash]

        if is_nil(parent_fact) do
          false
        else
          case parent_fact do
            %Fact{ancestry: {parent_producer, _}} ->
              parent_producer_node = workflow.graph.vertices[parent_producer]

              case parent_producer_node do
                %FanOut{} ->
                  # Found FanOut, check its parent fact
                  parent_fact.ancestry |> elem(1) == source_fact_hash

                _ ->
                  traces_to_source_fact?(workflow, parent_fact, source_fact_hash)
              end

            _ ->
              false
          end
        end
    end
  end

  defp traces_to_source_fact?(_workflow, _fact, _source_fact_hash), do: false

  defp reduce_with_while(enumerable, acc, reducer) do
    Enum.reduce_while(enumerable, acc, fn value, acc ->
      case reducer.(value, acc) do
        {:cont, new_acc} -> {:cont, new_acc}
        {:halt, new_acc} -> {:halt, new_acc}
        new_acc -> {:cont, new_acc}
      end
    end)
  end

  defp cleanup_mapped(workflow, expected_key, seen_key, source_fact_hash) do
    mapped =
      workflow.mapped
      |> Map.delete(expected_key)
      |> Map.delete(seen_key)
      |> Map.delete({:fan_out_for_batch, source_fact_hash})

    Map.put(workflow, :mapped, mapped)
  end

  def prepare(
        %FanIn{} = fan_in,
        %Workflow{} = workflow,
        %Fact{ancestry: {parent_step_hash, _}} = fact
      ) do
    fan_out = find_upstream_fan_out(workflow, fan_in)

    case fan_out do
      nil ->
        # Simple reduce mode - no FanOut upstream
        context =
          CausalContext.new(
            node_hash: fan_in.hash,
            input_fact: fact,
            ancestry_depth: Workflow.ancestry_depth(workflow, fact),
            hooks: Workflow.get_hooks(workflow, fan_in.hash),
            mergeable: fan_in.mergeable,
            fan_in_context: %{mode: :simple}
          )

        {:ok, Runnable.new(fan_in, fact, context)}

      %FanOut{} ->
        source_fact_hash = find_fan_out_source_fact_hash(workflow, fact)

        already_completed = has_reduced_output?(workflow, fan_in, source_fact_hash)
        completed_key = {:fan_in_completed, source_fact_hash, fan_in.hash}
        already_completed = already_completed or Map.get(workflow.mapped, completed_key, false)

        expected_key = {source_fact_hash, fan_out.hash}
        seen_key = {source_fact_hash, parent_step_hash}

        expected_list = workflow.mapped[expected_key] || []
        expected_set = MapSet.new(expected_list)
        seen_map = workflow.mapped[seen_key] || %{}
        seen_set = MapSet.new(Map.keys(seen_map))

        ready =
          not already_completed and
            not Enum.empty?(expected_set) and
            MapSet.equal?(expected_set, seen_set)

        # Collect sister values in order if ready
        sister_values =
          if ready do
            expected_in_order = Enum.reverse(expected_list)

            for origin <- expected_in_order do
              sister_hash = seen_map[origin]
              workflow.graph.vertices[sister_hash].value
            end
          else
            nil
          end

        context =
          CausalContext.new(
            node_hash: fan_in.hash,
            input_fact: fact,
            ancestry_depth: Workflow.ancestry_depth(workflow, fact),
            hooks: Workflow.get_hooks(workflow, fan_in.hash),
            mergeable: fan_in.mergeable,
            fan_in_context: %{
              mode: :fan_out_reduce,
              source_fact_hash: source_fact_hash,
              fan_out_hash: fan_out.hash,
              ready: ready,
              already_completed: already_completed,
              sister_values: sister_values,
              expected_key: expected_key,
              seen_key: seen_key,
              expected_list: expected_list,
              seen_map: seen_map
            }
          )

        {:ok, Runnable.new(fan_in, fact, context)}
    end
  end

  def prepare(%FanIn{} = fan_in, %Workflow{} = _workflow, %Fact{ancestry: nil} = fact) do
    # Root fact - shouldn't happen normally but handle gracefully
    context =
      CausalContext.new(
        node_hash: fan_in.hash,
        input_fact: fact,
        ancestry_depth: 0,
        hooks: {[], []},
        mergeable: fan_in.mergeable,
        fan_in_context: %{mode: :simple}
      )

    {:ok, Runnable.new(fan_in, fact, context)}
  end

  def execute(
        %FanIn{init: init, reducer: reducer} = fan_in,
        %Runnable{input_fact: fact, context: ctx} = runnable
      ) do
    with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, fan_in, fact) do
      case ctx.fan_in_context.mode do
        :simple ->
          reduced = reduce_with_while(fact.value, init.(), reducer)
          reduced_fact = Fact.new(value: reduced, ancestry: {fan_in.hash, fact.hash})

          case HookRunner.run_after(ctx, fan_in, fact, reduced_fact) do
            {:ok, after_apply_fns} ->
              apply_fn = fn workflow ->
                workflow
                |> Workflow.apply_hook_fns(before_apply_fns)
                |> Workflow.log_fact(reduced_fact)
                |> Workflow.draw_connection(fan_in, reduced_fact, :reduced,
                  weight: ctx.ancestry_depth + 1
                )
                |> Workflow.apply_hook_fns(after_apply_fns)
                |> Workflow.prepare_next_runnables(fan_in, reduced_fact)
                |> Workflow.mark_runnable_as_ran(fan_in, fact)
              end

              Runnable.complete(runnable, reduced_fact, apply_fn)

            {:error, reason} ->
              Runnable.fail(runnable, {:hook_error, reason})
          end

        :fan_out_reduce ->
          if ctx.fan_in_context.ready do
            reduced = reduce_with_while(ctx.fan_in_context.sister_values, init.(), reducer)
            reduced_fact = Fact.new(value: reduced, ancestry: {fan_in.hash, fact.hash})

            case HookRunner.run_after(ctx, fan_in, fact, reduced_fact) do
              {:ok, after_apply_fns} ->
                apply_fn = fn workflow ->
                  # Mark all sister facts as ran
                  expected_in_order = Enum.reverse(ctx.fan_in_context.expected_list)
                  seen_map = ctx.fan_in_context.seen_map

                  sister_facts =
                    for origin <- expected_in_order do
                      sister_hash = seen_map[origin]
                      workflow.graph.vertices[sister_hash]
                    end

                  workflow =
                    Enum.reduce(sister_facts, workflow, fn sister_fact, wrk ->
                      Workflow.mark_runnable_as_ran(wrk, fan_in, sister_fact)
                    end)

                  completed_key =
                    {:fan_in_completed, ctx.fan_in_context.source_fact_hash, fan_in.hash}

                  workflow
                  |> Workflow.apply_hook_fns(before_apply_fns)
                  |> Workflow.log_fact(reduced_fact)
                  |> Workflow.draw_connection(fan_in, reduced_fact, :reduced,
                    weight: ctx.ancestry_depth + 1
                  )
                  |> Workflow.apply_hook_fns(after_apply_fns)
                  |> Workflow.prepare_next_runnables(fan_in, reduced_fact)
                  |> Workflow.mark_runnable_as_ran(fan_in, reduced_fact)
                  |> mark_fan_in_completed(completed_key)
                  |> cleanup_mapped(
                    ctx.fan_in_context.expected_key,
                    ctx.fan_in_context.seen_key,
                    ctx.fan_in_context.source_fact_hash
                  )
                end

                Runnable.complete(runnable, reduced_fact, apply_fn)

              {:error, reason} ->
                Runnable.fail(runnable, {:hook_error, reason})
            end
          else
            # Not ready yet
            apply_fn = fn workflow ->
              Workflow.mark_runnable_as_ran(workflow, fan_in, fact)
            end

            Runnable.complete(runnable, :waiting, apply_fn)
          end
      end
    else
      {:error, reason} ->
        Runnable.fail(runnable, {:hook_error, reason})
    end
  end

  defp find_upstream_fan_out(workflow, fan_in) do
    workflow.graph
    |> Graph.in_edges(fan_in)
    |> Enum.filter(&(&1.label == :fan_in))
    |> List.first(%{})
    |> Map.get(:v1)
  end
end
