defprotocol Runic.Workflow.Invokable do
  @moduledoc """
  Protocol enforcing how an operation/step/node within a workflow can always be activated in context of a workflow.

  The return of an implementation's `invoke/3` should always return a new workflow.

  The invocable protocol is invoked to evaluate valid steps in that cycle starting with conditionals.
  """
  def invoke(node, workflow, fact)
  def match_or_execute(node)

  # replay reduces facts into a workflow to rebuild the workflow's memory from a log
  # in contrast to invoke which receives a runnable; replay instead accepts the fact the invokable has produced before
  # i.e. the fact ancestry hash == node.hash
  # this lets the protocol know what edges to draw in the workflow memory
  # def replay(node, workflow, fact)
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Root do
  alias Runic.Workflow.Root
  alias Runic.Workflow.Fact
  alias Runic.Workflow

  # def invoke(%Root{}, workflow, %Fact{ancestry: {parent_hash, _parent_fact_hash}} = fact) do
  #   workflow
  #   |> Workflow.log_fact(fact)
  #   |> Workflow.prepare_next_runnables(Map.get(workflow.graph.vertices, parent_hash), fact)
  # end

  def invoke(%Root{} = root, workflow, fact) do
    workflow
    |> Workflow.log_fact(fact)
    |> Workflow.prepare_next_generation(fact)
    |> Workflow.prepare_next_runnables(root, fact)
  end

  def match_or_execute(_root), do: :match
  # def runnable_connection(_root), do: :root
  # def resolved_connection(_root), do: :root

  # def replay(_root, workflow, fact) do
  #   workflow
  #   |> Workflow.log_fact(fact)
  #   |> Workflow.prepare_next_generation(fact)
  # end
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

  # def replay(condition, workflow, fact) do
  #   workflow
  #   |> Workflow.prepare_next_runnables(condition, fact)
  #   |> Workflow.draw_connection(fact, condition, :satisfied)
  #   |> Workflow.mark_runnable_as_ran(condition, fact)
  # end

  defp try_to_run_work(work, fact_value, arity) do
    try do
      run_work(work, fact_value, arity)
    rescue
      FunctionClauseError -> false
      BadArityError -> false
    catch
      true ->
        true

      any ->
        Logger.error(
          "something other than FunctionClauseError happened in Condition invoke/3 -> try_to_run_work/3: \n\n #{inspect(any)}"
        )

        false
    end
  end

  defp run_work(work, fact_value, 1) when is_list(fact_value) do
    apply(work, [fact_value])
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

    causal_generation = Workflow.causal_generation(workflow, fact)

    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(step, result_fact, :produced, weight: causal_generation)
    |> Workflow.mark_runnable_as_ran(step, fact)
    |> Workflow.run_after_hooks(step, result_fact)
    |> Workflow.prepare_next_runnables(step, result_fact)
    |> maybe_prepare_map_reduce(step, result_fact)
  end

  # def replay(step, workflow, fact) do
  #   parent_fact = Map.get(workflow.graph.vertices, elem(fact.ancestry, 1))

  #   workflow
  #   |> Workflow.log_fact(fact)
  #   |> Workflow.draw_connection(step, fact, :produced, weight: workflow.generations)
  #   |> Workflow.mark_runnable_as_ran(step, parent_fact)
  #   |> Workflow.prepare_next_runnables(step, fact)
  #   |> maybe_prepare_map_reduce(step, fact)
  # end

  def match_or_execute(_step), do: :execute

  defp is_reduced_in_map?(workflow, step) do
    MapSet.member?(workflow.mapped.mapped_paths, step.hash)
  end

  defp maybe_prepare_map_reduce(workflow, step, fact) do
    if is_reduced_in_map?(workflow, step) do
      key = {workflow.generations, step.hash}
      sister_facts = workflow.mapped[key] || []

      Map.put(workflow, :mapped, Map.put(workflow.mapped, key, [fact.hash | sister_facts]))
    else
      workflow
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

    causal_generation = Workflow.causal_generation(workflow, fact)

    if conj.hash not in satisfied_conditions and
         Enum.all?(conj.condition_hashes, &(&1 in satisfied_conditions)) do
      workflow
      |> Workflow.prepare_next_runnables(conj, fact)
      |> Workflow.draw_connection(fact, conj, :satisfied, weight: causal_generation)
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
    if ma.memory_assertion.(workflow, fact) do
      causal_generation = Workflow.causal_generation(workflow, fact)

      workflow
      |> Workflow.draw_connection(fact, ma, :satisfied, weight: causal_generation)
      |> Workflow.mark_runnable_as_ran(ma, fact)
      |> Workflow.prepare_next_runnables(ma, fact)
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

      causal_generation = Workflow.causal_generation(workflow, fact)

      workflow
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(sr, result_fact, :produced, weight: causal_generation)
      |> Workflow.run_after_hooks(sr, result_fact)
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
      causal_generation = Workflow.causal_generation(workflow, fact)

      workflow
      |> Workflow.prepare_next_runnables(sc, fact)
      |> Workflow.draw_connection(fact, sc, :satisfied, weight: causal_generation)
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

      causal_generation = Workflow.causal_generation(workflow, fact)

      workflow
      |> Workflow.log_fact(next_state_produced_fact)
      |> Workflow.draw_connection(acc, fact, :state_produced, weight: causal_generation)
      |> Workflow.mark_runnable_as_ran(acc, fact)
      |> Workflow.run_after_hooks(acc, next_state_produced_fact)
      |> Workflow.prepare_next_runnables(acc, next_state_produced_fact)
    else
      init_fact = init_fact(acc)

      next_state = apply(acc.reducer, [fact.value, init_fact.value])

      next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})

      causal_generation = Workflow.causal_generation(workflow, fact)

      workflow
      |> Workflow.log_fact(init_fact)
      |> Workflow.draw_connection(acc, init_fact, :state_initiated, weight: causal_generation)
      |> Workflow.log_fact(next_state_produced_fact)
      |> Workflow.draw_connection(acc, next_state_produced_fact, :state_produced,
        weight: causal_generation
      )
      |> Workflow.mark_runnable_as_ran(acc, fact)
      |> Workflow.run_after_hooks(acc, next_state_produced_fact)
      |> Workflow.prepare_next_runnables(acc, next_state_produced_fact)
    end
  end

  def match_or_execute(_state_reactor), do: :execute

  # def runnable_connection(_state_condition), do: :runnable
  # def resolved_connection(_state_condition), do: :state_produced

  defp last_known_state(workflow, accumulator) do
    workflow.graph
    |> Graph.out_edges(accumulator,
      by: :state_produced
    )
    # |> Enum.sort_by(& &1.weight, :desc)
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

    causal_generation = Workflow.causal_generation(workflow, fact)

    workflow =
      Workflow.draw_connection(workflow, fact, join, :joined, weight: causal_generation)

    join_order_weights =
      join.joins
      |> Enum.with_index()
      |> Map.new()

    possible_priors =
      workflow.graph
      |> Graph.in_edges(join)
      |> Enum.filter(&(&1.label == :joined))
      |> Enum.sort(fn edge1, edge2 ->
        join_weight_1 = Map.get(join_order_weights, elem(edge1.v1.ancestry, 0))
        join_weight_2 = Map.get(join_order_weights, elem(edge2.v1.ancestry, 0))
        join_weight_1 <= join_weight_2
      end)
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
      |> Workflow.draw_connection(join, join_bindings_fact, :produced,
        weight: workflow.generations
      )
      |> Workflow.run_after_hooks(join, join_bindings_fact)
    else
      workflow
    end
  end

  def match_or_execute(_join), do: :execute
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.FanOut do
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    FanOut
  }

  def invoke(
        %FanOut{} = fan_out,
        %Workflow{} = workflow,
        %Fact{} = source_fact
      ) do
    unless is_nil(Enumerable.impl_for(source_fact.value)) do
      is_reduced? = is_reduced?(workflow, fan_out)

      causal_generation = Workflow.causal_generation(workflow, source_fact)

      Enum.reduce(source_fact.value, workflow, fn value, wrk ->
        fact =
          Fact.new(value: value, ancestry: {fan_out.hash, source_fact.hash})

        wrk
        |> Workflow.log_fact(fact)
        |> Workflow.prepare_next_runnables(fan_out, fact)
        |> Workflow.draw_connection(fan_out, fact, :fan_out, weight: causal_generation)
        |> maybe_prepare_map_reduce(is_reduced?, fan_out, fact)
      end)
      |> Workflow.mark_runnable_as_ran(fan_out, source_fact)
    else
      Workflow.mark_runnable_as_ran(workflow, fan_out, source_fact)
    end
  end

  defp maybe_prepare_map_reduce(workflow, true, fan_out, fan_out_fact) do
    key = {workflow.generations, fan_out.hash}
    sister_facts = workflow.mapped[key] || []

    Map.put(workflow, :mapped, Map.put(workflow.mapped, key, [fan_out_fact.hash | sister_facts]))
  end

  defp maybe_prepare_map_reduce(workflow, false, _fan_out, _fan_out_fact) do
    workflow
  end

  def is_reduced?(workflow, fan_out) do
    Graph.out_edges(workflow.graph, fan_out) |> Enum.any?(&(&1.label == :fan_in))
  end

  def match_or_execute(_fan_out), do: :execute
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.FanIn do
  alias Runic.Workflow.FanOut
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    FanIn
  }

  @spec invoke(%Runic.Workflow.FanIn{}, Runic.Workflow.t(), Runic.Workflow.Fact.t()) ::
          Runic.Workflow.t()
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

    causal_generation = Workflow.causal_generation(workflow, fact)

    case fan_out do
      nil ->
        # basic step w/ enummerable output -> fan_in
        reduced_value = Enum.reduce(fact.value, fan_in.init.(), fan_in.reducer)

        reduced_fact =
          Fact.new(value: reduced_value, ancestry: {fan_in.hash, fact.hash})

        workflow
        |> Workflow.log_fact(reduced_fact)
        |> Workflow.run_after_hooks(fan_in, reduced_fact)
        |> Workflow.prepare_next_runnables(fan_in, reduced_fact)
        |> Workflow.draw_connection(fact, fan_in, :reduced, weight: causal_generation)
        |> Workflow.mark_runnable_as_ran(fan_in, fact)

      %FanOut{} ->
        # we may want to check ancestry paths from fan_out to fan_in with set inclusions

        sister_facts =
          for hash <- workflow.mapped[{workflow.generations, parent_step_hash}] || [] do
            workflow.graph.vertices
            |> Map.get(hash)
          end

        fan_out_facts_for_generation =
          workflow.graph
          |> Graph.out_edges(fan_out)
          |> Enum.filter(fn edge ->
            fact_generation =
              workflow.graph
              |> Graph.in_edges(edge.v2)
              |> Enum.filter(&(&1.label == :generation))
              |> List.first(%{})
              |> Map.get(:v1)

            edge.label == :fan_out and fact_generation == workflow.generations
          end)
          |> Enum.map(& &1.v2)
          |> Enum.uniq()

        # is a count safe or should we check set inclusions of hashes?
        if Enum.count(sister_facts) == Enum.count(fan_out_facts_for_generation) and
             not Enum.empty?(sister_facts) do
          sister_fact_values = Enum.map(sister_facts, & &1.value)

          reduced_value = Enum.reduce(sister_fact_values, fan_in.init.(), fan_in.reducer)

          fact =
            Fact.new(value: reduced_value, ancestry: {fan_in.hash, fact.hash})

          workflow =
            Enum.reduce(sister_facts, workflow, fn sister_fact, wrk ->
              wrk
              |> Workflow.mark_runnable_as_ran(fan_in, sister_fact)
            end)

          workflow
          |> Workflow.log_fact(fact)
          |> Workflow.run_after_hooks(fan_in, fact)
          |> Workflow.prepare_next_runnables(fan_in, fact)
          |> Workflow.draw_connection(fan_in, fact, :reduced, weight: causal_generation)
          |> Workflow.mark_runnable_as_ran(fan_in, fact)
          |> Map.put(
            :mapped,
            Map.delete(workflow.mapped, {workflow.generations, fan_out.hash})
          )
        else
          workflow
          |> Workflow.mark_runnable_as_ran(fan_in, fact)
        end
    end

    # if we have all facts needed then reduce otherwise mark as ran and let last sister fact reduce
  end

  def match_or_execute(_fan_in), do: :execute
end
