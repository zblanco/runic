defprotocol Runic.Workflow.Invokable do
  @moduledoc """
  Protocol enforcing how an operation/step/node within a workflow can always be activated in context of a workflow.

  The return of an implementation's `invoke/3` should always return a new workflow.

  The invocable protocol is invoked to evaluate valid steps in that cycle starting with conditionals.
  """
  def invoke(node, workflow, fact)
  def match_or_execute(node)
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Root do
  alias Runic.Workflow.Root
  alias Runic.Workflow.Fact
  alias Runic.Workflow

  def invoke(%Root{}, workflow, %Fact{ancestry: {parent_hash, _parent_fact_hash}} = fact) do
    workflow
    |> Workflow.log_fact(fact)
    |> Workflow.prepare_next_runnables(Map.get(workflow.flow.vertices, parent_hash), fact)
  end

  def invoke(%Root{} = root, workflow, fact) do
    workflow
    |> Workflow.log_fact(fact)
    |> Workflow.prepare_next_generation(fact)
    |> Workflow.prepare_next_runnables(root, fact)
  end

  def match_or_execute(_root), do: :match
  # def runnable_connection(_root), do: :root
  # def resolved_connection(_root), do: :root
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Condition do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Condition,
    Components
  }

  require Logger

  @spec invoke(Runic.Workflow.Condition.t(), Runic.Workflow.t(), Runic.Workflow.Fact.t()) ::
          Runic.Workflow.t()
  def invoke(
        %Condition{} = condition,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    if try_to_run_work(condition.work, fact.value, condition.arity) do
      workflow
      |> Workflow.prepare_next_runnables(condition, fact)
      |> Workflow.draw_connection(fact, condition, :satisfied)
      |> Workflow.mark_runnable_as_ran(condition, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, condition, fact)
    end
  end

  # def runnable_connection(_condition), do: :matchable
  # def resolved_connection(_condition), do: :satisfied

  def match_or_execute(_condition), do: :match

  defp try_to_run_work(work, fact_value, arity) do
    try do
      run_work(work, fact_value, arity)
    rescue
      FunctionClauseError -> false
    catch
      true ->
        true

      any ->
        Logger.error(
          "something other than FunctionClauseError happened in try_to_run_work/3: \n\n #{inspect(any)}"
        )

        false
    end
  end

  defp run_work(work, fact_value, 1) when is_list(fact_value) do
    apply(work, fact_value)
  end

  defp run_work(work, fact_value, arity) when arity > 1 and is_list(fact_value) do
    Components.run(work, fact_value)
  end

  defp run_work(_work, _fact_value, arity) when arity > 1 do
    false
  end

  defp run_work(work, fact_value, _arity) do
    Components.run(work, fact_value)
  end
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Step do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Step,
    Components
  }

  @spec invoke(%Runic.Workflow.Step{}, Runic.Workflow.t(), Runic.Workflow.Fact.t()) ::
          Runic.Workflow.t()
  def invoke(
        %Step{} = step,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    result = Components.run(step.work, fact.value, Components.arity_of(step.work))

    result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})

    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(step, result_fact, :produced)
    |> Workflow.prepare_next_runnables(step, result_fact)
    |> Workflow.mark_runnable_as_ran(step, fact)
  end

  def match_or_execute(_step), do: :execute
  # def runnable_connection(_step), do: :runnable
  # def resolved_connection(_step), do: :ran
  # def causal_connection(_step), do: :produced
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Conjunction do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Conjunction
  }

  @spec invoke(%Runic.Workflow.Conjunction{}, Runic.Workflow.t(), Runic.Workflow.Fact.t()) ::
          Runic.Workflow.t()
  def invoke(
        %Conjunction{} = conj,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    satisfied_conditions = Workflow.satisfied_condition_hashes(workflow, fact)

    if conj.hash not in satisfied_conditions and
         Enum.all?(conj.condition_hashes, &(&1 in satisfied_conditions)) do
      workflow
      |> Workflow.prepare_next_runnables(conj, fact)
      |> Workflow.draw_connection(fact, conj, :satisfied)
      |> Workflow.mark_runnable_as_ran(conj, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, conj, fact)
    end
  end

  def match_or_execute(_conjunction), do: :match
  # def runnable_connection(_conjunction), do: :matchable
  # def resolved_connection(_conjunction), do: :satisfied
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.MemoryAssertion do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    MemoryAssertion
  }

  @spec invoke(
          %Runic.Workflow.MemoryAssertion{},
          Runic.Workflow.t(),
          Runic.Workflow.Fact.t()
        ) :: Runic.Workflow.t()
  def invoke(
        %MemoryAssertion{} = ma,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    if ma.memory_assertion.(workflow) do
      workflow
      |> Workflow.prepare_next_runnables(ma, fact)
      |> Workflow.draw_connection(fact, ma, :satisfied)
      |> Workflow.mark_runnable_as_ran(ma, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, ma, fact)
    end
  end

  def match_or_execute(_memory_assertion), do: :match
  # def runnable_connection(_memory_assertion), do: :matchable
  # def resolved_connection(_memory_assertion), do: :satisfied
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.StateReaction do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Components,
    StateReaction
  }

  def invoke(
        %StateReaction{} = sr,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    last_known_state = Workflow.last_known_state(workflow, sr)

    result = Components.run(sr.work, last_known_state, sr.arity)

    unless result == {:error, :no_match_of_lhs_in_reactor_fn} do
      result_fact = Fact.new(value: result, ancestry: {sr.hash, fact.hash})

      workflow
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(sr, result_fact, :produced)
      |> Workflow.prepare_next_runnables(sr, result_fact)
      |> Workflow.mark_runnable_as_ran(sr, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, sr, fact)
    end
  end

  def match_or_execute(_state_reaction), do: :execute
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.StateCondition do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    StateCondition
  }

  @spec invoke(
          %Runic.Workflow.StateCondition{},
          Runic.Workflow.t(),
          Runic.Workflow.Fact.t()
        ) :: Runic.Workflow.t()
  def invoke(
        %StateCondition{} = sc,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    last_known_state = Workflow.last_known_state(workflow, sc)

    # check
    sc_result = sc.work.(fact.value, last_known_state)

    if sc_result do
      workflow
      |> Workflow.prepare_next_runnables(sc, fact)
      |> Workflow.draw_connection(fact, sc, :satisfied)
      |> Workflow.mark_runnable_as_ran(sc, fact)
    else
      Workflow.mark_runnable_as_ran(workflow, sc, fact)
    end
  end

  def match_or_execute(_state_condition), do: :match
  # def runnable_connection(_state_condition), do: :matchable
  # def resolved_connection(_state_condition), do: :satisfied
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Accumulator do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Components,
    Accumulator
  }

  @spec invoke(%Runic.Workflow.Accumulator{}, Runic.Workflow.t(), Runic.Workflow.Fact.t()) ::
          Runic.Workflow.t()
  def invoke(
        %Accumulator{} = acc,
        %Workflow{} = workflow,
        %Fact{} = fact
      ) do
    last_known_state = last_known_state(workflow, acc)

    unless is_nil(last_known_state) do
      next_state = apply(acc.reducer, [fact.value, last_known_state.value])

      next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

      workflow
      |> Workflow.prepare_next_runnables(acc, fact)
      |> Workflow.log_fact(next_state_produced_fact)
      |> Workflow.draw_connection(acc, fact, :state_produced)
      |> Workflow.mark_runnable_as_ran(acc, fact)
    else
      init_fact = init_fact(acc)

      next_state = apply(acc.reducer, [fact.value, init_fact.value])

      next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

      workflow
      |> Workflow.log_fact(init_fact)
      |> Workflow.draw_connection(acc, init_fact, :state_initiated)
      |> Workflow.prepare_next_runnables(acc, fact)
      |> Workflow.log_fact(next_state_produced_fact)
      |> Workflow.draw_connection(acc, next_state_produced_fact, :state_produced)
      |> Workflow.mark_runnable_as_ran(acc, fact)
    end
  end

  def match_or_execute(_state_reactor), do: :execute

  # def runnable_connection(_state_condition), do: :runnable
  # def resolved_connection(_state_condition), do: :state_produced

  defp last_known_state(workflow, accumulator) do
    workflow.graph
    |> Graph.out_edges(accumulator)
    |> Enum.filter(&(&1.label == :state_produced))
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
    Join
  }

  @spec invoke(%Runic.Workflow.Join{}, Runic.Workflow.t(), Runic.Workflow.Fact.t()) ::
          Runic.Workflow.t()
  def invoke(
        %Join{} = join,
        %Workflow{} = workflow,
        %Fact{ancestry: {_parent_hash, _value_hash}} = fact
      ) do
    # a join has n parents that must have produced a fact
    # a join's parent steps are either part of a runnable (for a partially satisfied join)
    # or each step has a produced edge to a new fact for whom the current fact is the ancestor

    workflow = Workflow.draw_connection(workflow, fact, join, :joined)

    possible_priors =
      workflow.graph
      |> Graph.in_edges(join)
      |> Enum.filter(&(&1.label == :joined))
      |> Enum.map(& &1.v1.value)

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
      |> Workflow.draw_connection(join, join_bindings_fact, :produced)
    else
      workflow
    end
  end

  def match_or_execute(_join), do: :execute
end
