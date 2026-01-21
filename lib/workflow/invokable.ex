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

  # def runnable_connection(_condition), do: :matchable
  # def resolved_connection(_condition), do: :satisfied

  def match_or_execute(_condition), do: :match

  # def replay(condition, workflow, fact) do
  #   workflow
  #   |> Workflow.prepare_next_runnables(condition, fact)
  #   |> Workflow.draw_connection(fact, condition, :satisfied)
  #   |> Workflow.mark_runnable_as_ran(condition, fact)
  # end
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
  defp find_fan_out_info(workflow, %Runic.Workflow.Fact{ancestry: {_producer_hash, input_fact_hash}}) do
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

    joined_edges =
      workflow.graph
      |> Graph.in_edges(join)
      |> Enum.filter(&(&1.label == :joined))

    # Deduplicate by parent hash - only keep one fact per expected parent
    # This handles the case where a step runs multiple times in parallel execution
    possible_priors_by_parent =
      joined_edges
      |> Enum.reduce(%{}, fn edge, acc ->
        parent_hash = elem(edge.v1.ancestry, 0)
        # Only keep if this parent is expected and we don't already have a fact for it
        if Map.has_key?(join_order_weights, parent_hash) and not Map.has_key?(acc, parent_hash) do
          Map.put(acc, parent_hash, edge.v1)
        else
          acc
        end
      end)

    # Sort by join order and extract values
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
      |> Workflow.draw_connection(join, join_bindings_fact, :produced,
        weight: workflow.generations
      )
      |> Workflow.run_after_hooks(join, join_bindings_fact)
    else
      # Join is not yet satisfied, but we must still mark this runnable as ran
      # to prevent infinite re-invocation in parallel execution scenarios
      Workflow.mark_runnable_as_ran(workflow, join, fact)
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
        |> maybe_prepare_map_reduce(is_reduced?, fan_out, fact, source_fact)
      end)
      |> Workflow.mark_runnable_as_ran(fan_out, source_fact)
    else
      Workflow.mark_runnable_as_ran(workflow, fan_out, source_fact)
    end
  end

  # Use source_fact.hash as the batch identifier instead of generations
  # This is stable across workflow merges and re-planning
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
        # basic step w/ enumerable output -> fan_in
        reduced_value = reduce_with_while(fact.value, fan_in.init.(), fan_in.reducer)

        reduced_fact =
          Fact.new(value: reduced_value, ancestry: {fan_in.hash, fact.hash})

        workflow
        |> Workflow.log_fact(reduced_fact)
        |> Workflow.draw_connection(fan_in, reduced_fact, :reduced, weight: causal_generation)
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
          |> Workflow.draw_connection(fan_in, reduced_fact, :reduced, weight: causal_generation)
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

  defp find_fan_out_source_fact_hash(workflow, %Fact{ancestry: nil}) do
    # Fact has no ancestry, can't find FanOut source
    nil
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

  defp traces_to_source_fact?(workflow, %Fact{ancestry: {_producer_hash, parent_fact_hash}}, source_fact_hash) do
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

  def match_or_execute(_fan_in), do: :execute
end
