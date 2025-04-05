defmodule Runic do
  @external_resource "README.md"
  @moduledoc "README.md" |> File.read!() |> String.split("<!-- MDOC !-->") |> Enum.fetch!(1)

  alias Runic.Workflow.StateCondition
  alias Runic.Workflow.Accumulator
  alias Runic.Workflow.StateMachine
  alias Runic.Workflow.StateReaction
  alias Runic.Workflow.MemoryAssertion
  alias Runic.Workflow
  alias Runic.Workflow.Step
  alias Runic.Workflow.Condition
  alias Runic.Workflow.Rule
  alias Runic.Workflow.Components
  alias Runic.Workflow.Conjunction
  alias Runic.Workflow.FanOut
  alias Runic.Workflow.FanIn
  alias Runic.Workflow.Join
  alias Runic.Workflow.ComponentAdded
  alias Runic.Workflow.ReactionOccurred

  # @boolean_expressions ~w(
  #   ==
  #   ===
  #   !=
  #   !==
  #   <
  #   >
  #   <=
  #   >=
  #   in
  #   not
  #   =~
  # )a

  @doc """
  Creates a %Step{}: a basic lambda expression that can be added to a workflow.

  Steps are basic input -> output dataflow primatives that can be connected together in a workflow.

  A Step implements the Runic.Workflow.Activation, and Runic.Workflow.Component protocols
  to be composable and possible to evaluate at runtime with inputs.
  """
  defmacro step({:fn, _, _} = work) do
    source =
      quote do
        Runic.step(unquote(work))
      end

    quote do
      Step.new(
        work: unquote(work),
        source: unquote(Macro.escape(source)),
        hash: unquote(Components.fact_hash(work))
      )
    end
  end

  defmacro step({:&, _, _} = work) do
    source =
      quote do
        Runic.step(unquote(work))
      end

    quote do
      Step.new(
        work: unquote(work),
        source: unquote(Macro.escape(source)),
        hash: unquote(Components.fact_hash(work))
      )
    end
  end

  defmacro step(opts) when is_list(opts) or is_map(opts) do
    work = opts[:work]

    source =
      quote do
        Runic.step(unquote(opts))
      end

    quote do
      Step.new(
        work: unquote(work),
        source: unquote(Macro.escape(source)),
        name: unquote(opts[:name]),
        hash: unquote(Components.fact_hash(work))
      )
    end
  end

  defmacro step(work, opts) do
    source =
      quote do
        Runic.step(unquote(work), unquote(opts))
      end

    quote do
      Step.new(
        work: unquote(work),
        source: unquote(Macro.escape(source)),
        name: unquote(opts[:name]),
        hash: unquote(Components.fact_hash(work))
      )
    end
  end

  def condition(fun) when is_function(fun) do
    Condition.new(fun)
  end

  def condition({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    Condition.new(Function.capture(m, f, a))
  end

  def transmute(component) do
    Runic.Transmutable.transmute(component)
  end

  def workflow(opts \\ []) do
    name = opts[:name]
    steps = opts[:steps]
    rules = opts[:rules]
    before_hooks = opts[:before_hooks]
    after_hooks = opts[:after_hooks]

    Workflow.new(name)
    |> Workflow.add_steps(steps)
    |> Workflow.add_rules(rules)
    |> Workflow.add_before_hooks(before_hooks)
    |> Workflow.add_after_hooks(after_hooks)
  end

  # defmacro workflow_from_log(events) do
  #   Enum.reduce(unquote(events), Workflow.new(), fn
  #     %ComponentAdded{source: source, to: to}, wrk ->
  #       dbg(source, label: "source")
  #       {component, _binding} = Code.eval_quoted(source, [], __CALLER__)
  #       Workflow.add(wrk, component, to: to)

  #     %ReactionOccurred{} = ro, wrk ->
  #       reaction_edge =
  #         Graph.Edge.new(
  #           ro.from,
  #           ro.to,
  #           label: ro.reaction,
  #           properties: ro.properties
  #         )

  #       generation =
  #         if(ro.reaction == :generation and ro.from > wrk.generations) do
  #           ro.from
  #         else
  #           wrk.generations
  #         end

  #       %Workflow{
  #         wrk
  #         | graph: Graph.add_edge(wrk.graph, reaction_edge),
  #           generations: generation
  #       }
  #   end)
  # end

  defmacro rule(opts) when is_list(opts) do
    name = opts[:name]
    condition = opts[:condition] || opts[:if]
    reaction = opts[:reaction] || opts[:do]

    arity = Components.arity_of(reaction)

    # {rewritten_condition, condition_bindings} = traverse_expression(condition, __CALLER__)
    {rewritten_reaction, reaction_bindings} = traverse_expression(reaction, __CALLER__)

    variable_bindings =
      reaction_bindings
      |> Enum.uniq()

    bindings =
      quote do
        # Create a map to hold the bindings for the rule
        %{
          unquote_splicing(
            Enum.map(variable_bindings, fn {:=, _, [{left_var, _, _}, right]} ->
              {left_var, right}
            end)
          ),
          __caller_context__: unquote(Macro.escape(__CALLER__))
        }
      end

    workflow = workflow_of_rule({condition, rewritten_reaction}, arity)

    source =
      quote do
        Runic.rule(
          name: unquote(name),
          condition: unquote(condition),
          reaction: unquote(rewritten_reaction)
        )
      end

    quote do
      unquote_splicing(Enum.reverse(variable_bindings))

      %Rule{
        name: unquote(name),
        arity: unquote(arity),
        workflow: unquote(workflow),
        bindings: unquote(bindings),
        source: unquote(Macro.escape(source))
      }
    end
  end

  defmacro rule(expression) do
    arity = Components.arity_of(expression)

    workflow = workflow_of_rule(expression, arity)

    source =
      quote do
        Runic.rule(unquote(expression))
      end

    quote bind_quoted: [
            arity: arity,
            workflow: workflow,
            source: Macro.escape(source)
          ] do
      %Rule{
        arity: arity,
        workflow: workflow,
        source: source
      }
    end
  end

  defmacro rule(expression, opts) when is_list(opts) do
    name = opts[:name]

    arity = Components.arity_of(expression)

    workflow = workflow_of_rule(expression, arity)

    source =
      quote do
        Runic.rule(unquote(expression), unquote(opts))
      end

    quote bind_quoted: [
            name: name,
            arity: arity,
            workflow: workflow,
            source: Macro.escape(source)
          ] do
      %Rule{
        name: name,
        arity: arity,
        workflow: workflow,
        source: source
      }
    end
  end

  defp traverse_expression({:fn, _, [{:->, _, [_, _block]}]} = expression, env) do
    Macro.prewalk(expression, [], fn
      {:^, meta, [{var, _, ctx} = expr]} = _pinned_ast, acc ->
        new_var = Macro.var(var, ctx)
        {new_var, [{:=, meta, [new_var, expr]} | acc]}

      otherwise, acc ->
        {Macro.expand(otherwise, env), acc}
    end)
  end

  defmacro state_machine(opts) do
    init = opts[:init] || raise ArgumentError, "An `init` function or state is required"

    reducer =
      Keyword.get(opts, :reducer) ||
        raise ArgumentError, "A reducer function is required"

    reactors = opts[:reactors]

    name = opts[:name]

    workflow = workflow_of_state_machine(init, reducer, reactors, name)

    source =
      quote do
        Runic.state_machine(unquote(opts))
      end

    quote do
      %StateMachine{
        name: unquote(name),
        init: unquote(init),
        reducer: unquote(reducer),
        reactors: unquote(reactors),
        workflow: unquote(workflow) |> Map.put(:name, unquote(name)),
        source: unquote(Macro.escape(source))
      }
    end
  end

  @doc """
  map/1 applies the expression to each element in the enumerable.

  A map expression can be a function, a list, or a nested pipeline expression of steps.

  The input fact to the map expression must implement the Enumerable protocol so that during workflow evaluation
  the map expression can be applied to each element as a runnable.

  A Runic map expression must be inside a Runic workflow to be evaluated.

  Internally a map expression is a FanOut step that splits the input enumerable into separate facts that are then processed by the map expression.

  The map function itself is within a step with a connection flowing from the FanOut step.

  ## Examples

  ```elixir
  Runic.map(fn x -> x * 2 end)

  Runic.map(
    {Runic.step(fn num -> num * 2 end),
    [
      Runic.step(fn num -> num + 1 end),
      Runic.step(fn num -> num + 4 end)
    ]}
  )

  Runic.map([
    Runic.step(fn num -> num * 2 end),
    Runic.step(fn num -> num + 1 end),
    Runic.step(fn num -> num + 4 end)
  ])
  ```
  """
  defmacro map(expression, opts \\ []) do
    name = opts[:name]

    pipeline_graph_of_ast =
      pipeline_graph_of_map_expression(expression, name)

    source =
      quote do
        Runic.map(unquote(expression), unquote(opts))
      end

    map_pipeline =
      quote do
        unquote(
          pipeline_graph_of_ast
          |> Graph.edges()
          |> Enum.reduce(quote(do: Workflow.new()), fn
            %{v1: :root, v2: v2}, wrk ->
              quote do
                unquote(wrk)
                |> Workflow.add_step(unquote(v2))
              end

            %{v1: v1, v2: v2}, wrk ->
              quote do
                unquote(wrk)
                |> Workflow.add_step(unquote(v1), unquote(v2))
              end
          end)
        )
      end

    quote do
      %Runic.Workflow.Map{
        name: unquote(name),
        pipeline: unquote(map_pipeline),
        hash: unquote(Components.fact_hash({expression, name})),
        source: unquote(Macro.escape(source))
      }
      |> Runic.Workflow.Map.build_named_components()
    end
  end

  @doc """
  Includes a reduce expression in a Runic workflow.

  Reducers are used to accumulate many facts into a single fact.

  A reduce expression can aggregate a map expression or a fact produced by a parent step that implements the enumerable protocol.

  By default reduce/2 will behave like Enum.reduce/3 does in Elixir where it expects an enumerable and applies the reducer function to each element.

  ```elixir
  require Runic

  simple_reduce_workflow = Runic.workflow(steps: [
    {Runic.step(fn -> 0..5 end), [
      Runic.reduce(0, fn acc, x -> acc + x end)
    ]}
  ])
  ```

  This is similar to the Elixir code using the Enum module:

  ```elixir
  Enum.reduce(0..5, 0, fn x, acc -> acc + x end)
  ```

  However evaluating the reduce in a single runnable invokation with Runic may incur greater costs as it evaluates eagerly.

  When the `step` option is provided with the name of an existing map expression, the reduce expression will be applied to each element in the enumerable produced by its parent step
  that was fanned out by the map expression.

  This allows lazy workflow evaluation where separate runnables are produced for each element in the enumerable.

  If the work to compute within a map or within each reduce is expensive it may be preferred to allow the workflow scheduler to
  execute how it sees fit.

  ```elixir
  Runic.workflow(steps: [
    {Runic.step(fn -> 0..5 end), [
      Runic.map(fn x -> x * 2 end, name: :map),
      Runic.reduce(0, fn x, acc -> acc + x end, step: :map)
    ]}
  ])
  ```

  The reason for an explicit designation of a map expression is so that the map expression can define a pipeline the reduce can follow where the direct parent of the reduce may not be the same step as the map.

  ```elixir
  Runic.workflow(steps: [
    {Runic.step(fn -> 0..5 end), [
      {Runic.map(fn x -> x * 2 end, name: :map), [
        {Runic.step(fn x -> x + 1 end), [
          Runic.reduce(0, fn x, acc -> acc + x end, step: :map)
        ]}
      ]}
    ]}
  ])
  ```

  In this workflow the reduce will be applied to the output of the step that adds 1 to each element in the enumerable produced by the map expression where it multiplies each element by 2.
  """
  defmacro reduce(acc, reducer_fun, opts \\ []) do
    map_to_reduce = opts[:map]

    name = opts[:name]

    source =
      quote do
        Runic.reduce(unquote(acc), unquote(reducer_fun), unquote(opts))
      end

    quote do
      hash = unquote(Components.fact_hash({acc, reducer_fun}))

      %Runic.Workflow.Reduce{
        name: unquote(name),
        hash: hash,
        fan_in: %FanIn{
          map: unquote(map_to_reduce),
          init: fn -> unquote(acc) end,
          reducer: unquote(reducer_fun),
          hash: hash
        },
        source: unquote(Macro.escape(source))
      }
    end
  end

  defp pipeline_graph_of_map_expression(expression, name \\ nil)

  defp pipeline_graph_of_map_expression(expression, name) do
    pipeline_graph_of_map_expression(
      Graph.new(vertex_identifier: &Components.vertex_id_of/1) |> Graph.add_vertex(:root),
      expression,
      name
    )
  end

  defp pipeline_graph_of_map_expression(g, {:fn, _, _} = expression, name) do
    fan_out =
      quote do
        %FanOut{
          hash: unquote(Components.fact_hash({:fan_out, expression})),
          name: unquote(name)
        }
      end

    step = pipeline_step(expression)

    g
    |> Graph.add_edge(:root, fan_out)
    |> Graph.add_edge(fan_out, step)
  end

  defp pipeline_graph_of_map_expression(g, {:step, _, _} = expression, name) do
    fan_out =
      quote do
        %FanOut{
          hash: unquote(Components.fact_hash({:fan_out, expression})),
          name: unquote(name)
        }
      end

    step = pipeline_step(expression)

    g
    |> Graph.add_edge(:root, fan_out)
    |> Graph.add_edge(fan_out, step)
  end

  defp pipeline_graph_of_map_expression(
         g,
         {[_ | _] = parent_steps, [_ | _] = dependent_steps} = pipeline_expression,
         name
       ) do
    fan_out =
      quote do
        %FanOut{
          hash: unquote(Components.fact_hash({:fan_out, pipeline_expression})),
          name: unquote(name)
        }
      end

    parent_steps_with_hashes =
      Enum.map(parent_steps, fn step_ast ->
        {Components.fact_hash(step_ast), pipeline_step(step_ast)}
      end)

    parent_hashes = Enum.map(parent_steps_with_hashes, &elem(&1, 0))

    join_hash = Components.fact_hash(Enum.map(parent_steps_with_hashes, &elem(&1, 0)))

    join =
      quote do
        %Join{
          hash: unquote(join_hash),
          joins: unquote(parent_hashes)
        }
      end

    g =
      g
      |> Graph.add_edge(:root, fan_out)
      |> Graph.add_edges(
        Enum.map(parent_steps_with_hashes, fn {_, join_step} ->
          {fan_out, join_step}
        end)
      )
      |> Graph.add_edges(
        Enum.map(parent_steps_with_hashes, fn {_, join_step} ->
          {join_step, join}
        end)
      )

    Enum.reduce(dependent_steps, g, fn dstep, g_acc ->
      dependent_pipeline_graph_of_expression(g_acc, join, dstep)
    end)
  end

  defp pipeline_graph_of_map_expression(
         g,
         {step_expression, [_ | _] = dependent_steps} = pipeline_expression,
         name
       ) do
    fan_out =
      quote do
        %FanOut{
          hash: unquote(Components.fact_hash({:fan_out, pipeline_expression})),
          name: unquote(name)
        }
      end

    step = pipeline_step(step_expression)

    g =
      g
      |> Graph.add_edge(:root, fan_out)
      |> Graph.add_edge(fan_out, step)

    Enum.reduce(dependent_steps, g, fn dstep, g_acc ->
      dependent_pipeline_graph_of_expression(g_acc, step, dstep)
    end)
  end

  defp pipeline_graph_of_map_expression(
         g,
         [_ | _] = pipeline_expression,
         name
       ) do
    fan_out_hash = Components.fact_hash({:fan_out, pipeline_expression})

    fan_out =
      quote do
        %FanOut{
          hash: unquote(fan_out_hash),
          name: unquote(name)
        }
      end

    g =
      g
      |> Graph.add_edge(:root, fan_out)

    Enum.reduce(pipeline_expression, g, fn dstep, g_acc ->
      dependent_pipeline_graph_of_expression(g_acc, fan_out, dstep)
    end)
  end

  defp dependent_pipeline_graph_of_expression(g, parent, {:fn, _, _} = anonymous_step_expression) do
    Graph.add_edge(g, parent, pipeline_step(anonymous_step_expression))
  end

  defp dependent_pipeline_graph_of_expression(g, parent, {{:., _, [_, :step]}, _, _} = expression) do
    Graph.add_edge(g, parent, pipeline_step(expression))
  end

  defp dependent_pipeline_graph_of_expression(
         g,
         parent,
         {{:., _, [_, :reduce]}, _, _} = expression
       ) do
    Graph.add_edge(g, parent, expression)
  end

  defp dependent_pipeline_graph_of_expression(
         g,
         parent,
         {{:., _, [_, :map]}, _, [[map_expression, opts]]}
       )
       when is_list(map_expression) do
    name = opts[:name]
    map_pipeline_graph_of_ast = pipeline_graph_of_map_expression(map_expression, name)

    Graph.add_edges(
      g,
      map_pipeline_graph_of_ast
      |> Graph.edges()
      |> Enum.map(fn
        %{v1: :root, v2: v2} = edge ->
          %{edge | v1: parent, v2: v2}

        edge ->
          edge
      end)
    )
  end

  defp dependent_pipeline_graph_of_expression(
         g,
         parent,
         {{:., _, [_, :map]}, _, [map_expression]}
       ) do
    map_pipeline_graph_of_ast = pipeline_graph_of_map_expression(map_expression)

    Graph.add_edges(
      g,
      map_pipeline_graph_of_ast
      |> Graph.edges()
      |> Enum.map(fn
        %{v1: :root, v2: v2} = edge ->
          %{edge | v1: parent, v2: v2}

        edge ->
          edge
      end)
    )
  end

  defp dependent_pipeline_graph_of_expression(g, parent, {:map, _, [{map_expression, opts}]})
       when is_list(opts) do
    name = opts[:name]
    map_pipeline_graph_of_ast = pipeline_graph_of_map_expression(map_expression, name)

    Graph.add_edges(
      g,
      map_pipeline_graph_of_ast
      |> Graph.edges()
      |> Enum.map(fn
        %{v1: :root, v2: v2} = edge ->
          %{edge | v1: parent, v2: v2}

        edge ->
          edge
      end)
    )
  end

  defp dependent_pipeline_graph_of_expression(g, parent, {:map, _, [map_expression]}) do
    map_pipeline_graph_of_ast = pipeline_graph_of_map_expression(map_expression)

    Graph.add_edges(
      g,
      map_pipeline_graph_of_ast
      |> Graph.edges()
      |> Enum.map(fn
        %{v1: :root, v2: v2} = edge ->
          %{edge | v1: parent, v2: v2}

        edge ->
          edge
      end)
    )
  end

  defp dependent_pipeline_graph_of_expression(g, parent, {dparent, dependents}) do
    parent_step = pipeline_step(dparent)

    g = Graph.add_edge(g, parent, parent_step)

    Enum.reduce(dependents, g, fn dstep, g_acc ->
      dependent_pipeline_graph_of_expression(g_acc, parent_step, dstep)
    end)
  end

  defp dependent_pipeline_graph_of_expression(g, parent, step) do
    Graph.add_edge(g, parent, pipeline_step(step))
  end

  defp pipeline_step({:&, _, _} = expression) do
    step_ast_hash = Components.fact_hash(expression)

    quote do
      Step.new(work: unquote(expression), hash: unquote(step_ast_hash))
    end
  end

  defp pipeline_step({:fn, _, _} = expression) do
    step_ast_hash = Components.fact_hash(expression)

    quote do
      Step.new(work: unquote(expression), hash: unquote(step_ast_hash))
    end
  end

  defp pipeline_step({{:., _, [_, :step]}, _, [expression | [rest]]}) do
    step_ast_hash = Components.fact_hash(expression)

    name = rest[:name]

    quote do
      Step.new(work: unquote(expression), hash: unquote(step_ast_hash), name: unquote(name))
    end
  end

  defp pipeline_step({{:., _, [_, :step]}, _, [expression]}) do
    step_ast_hash = Components.fact_hash(expression)

    quote do
      Step.new(work: unquote(expression), hash: unquote(step_ast_hash))
    end
  end

  defp pipeline_step({:step, _, [expression | [rest]]}) do
    step_ast_hash = Components.fact_hash(expression)

    name = rest[:name]

    quote do
      Step.new(work: unquote(expression), hash: unquote(step_ast_hash), name: unquote(name))
    end
  end

  defp pipeline_step({:step, _, [expression]}) do
    step_ast_hash = Components.fact_hash(expression)

    quote do
      Step.new(work: unquote(expression), hash: unquote(step_ast_hash))
    end
  end

  defp workflow_of_state_machine(init, reducer, reactors, name) do
    accumulator = accumulator_of_state_machine(init, reducer)

    workflow_ast =
      reducer
      |> build_reducer_workflow_ast(accumulator, name)
      |> maybe_add_reactors(reactors, accumulator)

    quote generated: true do
      unquote(workflow_ast)
    end
  end

  defp accumulator_of_state_machine({:fn, _, _} = init, reducer) do
    quote do
      %Accumulator{
        init: unquote(init),
        reducer: unquote(reducer),
        hash: unquote(Components.fact_hash({init, reducer}))
      }
    end
  end

  defp accumulator_of_state_machine({:&, _, _} = init, reducer) do
    quote do
      %Accumulator{
        init: unquote(init),
        reducer: unquote(reducer),
        hash: unquote(Components.fact_hash({init, reducer}))
      }
    end
  end

  defp accumulator_of_state_machine({:{}, _, _} = init, reducer) do
    init_fun =
      quote do
        {m, f, a} = unquote(init)
        Function.capture(m, f, a)
      end

    quote do
      %Accumulator{
        init: unquote(init_fun),
        reducer: unquote(reducer),
        hash: unquote(Components.fact_hash({init, reducer}))
      }
    end
  end

  defp accumulator_of_state_machine(literal_init, reducer) do
    literal_init_ast =
      quote do
        fn -> unquote(literal_init) end
      end

    quote do
      %Accumulator{
        init: unquote(literal_init_ast),
        reducer: unquote(reducer),
        hash: unquote(Components.fact_hash({literal_init_ast, reducer}))
      }
    end
  end

  defp build_reducer_workflow_ast({:fn, _, clauses} = _reducer, accumulator, name) do
    Enum.reduce(
      clauses,
      quote generated: true do
        Workflow.new(unquote(name))
      end,
      fn
        {:->, _meta, _} = clause, wrk ->
          state_cond_fun =
            case clause do
              {:->, _, [[{:when, _, _} = lhs], _rhs]} ->
                quote generated: true do
                  fn
                    unquote(lhs) -> true
                    _, _ -> false
                  end
                end

              {:->, _meta, [lhs, _rhs]} ->
                quote generated: true do
                  fn
                    unquote_splicing(lhs) -> true
                    _, _ -> false
                  end
                end
            end

          hash_of_ast = Components.fact_hash({state_cond_fun, accumulator})

          state_condition =
            quote generated: true do
              StateCondition.new(
                unquote(state_cond_fun),
                Map.get(unquote(accumulator), :hash),
                unquote(hash_of_ast)
              )
            end

          arity_check =
            quote do
              Condition.new(Components.is_of_arity?(1))
            end

          quote generated: true do
            unquote(wrk)
            |> Workflow.add_step(unquote(arity_check))
            |> Workflow.add_step(unquote(arity_check), unquote(state_condition))
            |> Workflow.add_step(unquote(state_condition), unquote(accumulator))
          end
      end
    )
  end

  defp maybe_add_reactors(workflow_ast, nil, _accumulator), do: workflow_ast

  defp maybe_add_reactors(workflow_ast, reactors, accumulator) do
    Enum.reduce(reactors, workflow_ast, fn
      {:fn, _meta, [{:->, _, [[lhs], _rhs]}]} = reactor, wrk ->
        memory_assertion_fun =
          quote generated: true do
            fn workflow ->
              last_known_state = StateMachine.last_known_state(unquote(accumulator), workflow)

              check = fn
                unquote(lhs) -> true
                _ -> false
              end

              check.(last_known_state)
            end
          end

        memory_assertion_ast_hash = Components.fact_hash(memory_assertion_fun)

        memory_assertion =
          quote generated: true do
            MemoryAssertion.new(
              memory_assertion: unquote(memory_assertion_fun),
              state_hash: Map.get(unquote(accumulator), :hash),
              hash: unquote(memory_assertion_ast_hash)
            )
          end

        state_reaction = reactor_ast_of(reactor, accumulator, Components.arity_of(reactor))

        quote generated: true do
          unquote(wrk)
          |> Workflow.add_step(unquote(memory_assertion))
          |> Workflow.add_step(unquote(memory_assertion), unquote(state_reaction))
        end
    end)
  end

  defp reactor_ast_of({:fn, _meta, [{:->, _, [[lhs], rhs]}]}, accumulator, 1 = _arity) do
    reactor_ast =
      quote do
        fn
          unquote(lhs) -> unquote(rhs)
          _otherwise -> {:error, :no_match_of_lhs_in_reactor_fn}
        end
      end

    quote do
      StateReaction.new(
        work: unquote(reactor_ast),
        state_hash: Map.get(unquote(accumulator), :hash),
        arity: 1,
        ast: unquote(Macro.escape(reactor_ast))
      )
    end
  end

  defp workflow_of_rule({condition, reaction}, arity) do
    reaction_ast_hash = Components.fact_hash(reaction)

    reaction = quote(do: Step.new(work: unquote(reaction), hash: unquote(reaction_ast_hash)))

    condition_ast_hash = Components.fact_hash(condition)

    condition =
      quote(
        do:
          Condition.new(
            work: unquote(condition),
            hash: unquote(condition_ast_hash),
            arity: unquote(arity)
          )
      )

    quote do
      import Runic

      Workflow.new()
      |> Workflow.add_step(unquote(condition))
      |> Workflow.add_step(unquote(condition), unquote(reaction))
    end
  end

  defp workflow_of_rule({:fn, _, [{:->, _, [[], _rhs]}]} = expression, 0 = _arity) do
    reaction_ast_hash = Components.fact_hash(expression)

    reaction = quote(do: Step.new(work: unquote(expression), hash: unquote(reaction_ast_hash)))

    quote do
      import Runic

      Workflow.new()
      |> Workflow.add_step(unquote(reaction))
    end
  end

  defp workflow_of_rule(
         {:fn, _head_meta, [{:->, _clause_meta, [[{:when, _, _clauses} = lhs], _rhs]}]} =
           expression,
         arity
       ) do
    reaction_ast_hash = Components.fact_hash(expression)

    reaction =
      quote(
        do:
          Step.new(
            work: unquote(expression),
            hash: unquote(reaction_ast_hash)
          )
      )

    arity_condition =
      quote do
        Condition.new(Components.is_of_arity?(unquote(arity)), unquote(arity))
      end

    workflow_with_arity_check_quoted =
      quote do
        Workflow.new()
        |> Workflow.add_step(unquote(arity_condition))
      end

    binds = binds_of_guarded_anonymous(lhs, arity)

    condition_fun =
      quote do
        fn
          unquote(lhs) ->
            true

          unquote_splicing(Enum.map(binds, fn {_bind, meta, cont} -> {:_, meta, cont} end)) ->
            false
        end
      end

    condition =
      quote do
        Condition.new(
          work: unquote(condition_fun),
          hash: unquote(Components.fact_hash(condition_fun)),
          arity: unquote(arity)
        )
      end

    quoted_workflow =
      quote do
        import Runic

        unquote(workflow_with_arity_check_quoted)
        |> Workflow.add_step(unquote(arity_condition), unquote(condition))
        |> Workflow.add_step(unquote(condition), unquote(reaction))
      end

    # component_ast_graph =
    #   quote do
    #     unquote(
    #       lhs
    #       |> Macro.postwalker()
    #       |> Enum.reduce(
    #         %{
    #           component_ast_graph:
    #             Graph.new() |> Graph.add_vertex(:root) |> Graph.add_edge(:root, arity_condition),
    #           arity: arity,
    #           arity_condition: arity_condition,
    #           binds: binds_of_guarded_anonymous(expression, arity),
    #           reaction: reaction,
    #           children: [],
    #           possible_children: %{},
    #           conditions: []
    #         },
    #         &post_extract_guarded_into_workflow/2
    #       )
    #       |> Map.get(:component_ast_graph)
    #     )
    #   end

    # quoted_workflow =
    #   quote do
    #     import Runic

    #     unquote(
    #       Graph.Reducers.Bfs.reduce(component_ast_graph, workflow_with_arity_check_quoted, fn
    #         ast_vertex, quoted_workflow ->
    #           parents = Graph.in_neighbors(component_ast_graph, ast_vertex)

    #           quoted_workflow =
    #             Enum.reduce(parents, quoted_workflow, fn
    #               :root, quoted_workflow ->
    #                 quote do
    #                   unquote(quoted_workflow)
    #                   |> Workflow.add_step(unquote(ast_vertex))
    #                 end

    #               parent, quoted_workflow ->
    #                 quote do
    #                   unquote(quoted_workflow)
    #                   |> Workflow.add_step(unquote(parent), unquote(ast_vertex))
    #                 end
    #             end)

    #           {:next, quoted_workflow}
    #       end)
    #     )
    #   end

    quoted_workflow
  end

  # matches: fn true -> _ end | fn nil -> _ end
  defp workflow_of_rule({:fn, _, [{:->, _, [[lhs], rhs]}]} = _expression, 1 = _arity)
       when lhs in [true, nil] do
    condition = quote(do: Condition.new(fn _lhs -> true end))
    reaction = quote(do: step(fn _ -> unquote(rhs) end))

    arity_condition =
      quote do
        Condition.new(Components.is_of_arity?(1))
      end

    quote do
      import Runic

      Workflow.new()
      |> Workflow.add_step(unquote(arity_condition))
      |> Workflow.add_step(unquote(arity_condition), unquote(condition))
      |> Workflow.add_step(unquote(condition), unquote(reaction))
    end
  end

  defp workflow_of_rule(
         {:fn, head_meta, [{:->, clause_meta, [[lhs], _rhs]}]} = expression,
         1 = arity
       ) do
    condition =
      {:fn, head_meta,
       [
         {:->, clause_meta, [[lhs], true]},
         {:->, clause_meta, [[{:_otherwise, [if_undefined: :apply], Elixir}], false]}
       ]}

    condition_ast_hash = Components.fact_hash(condition)

    condition =
      quote do
        Condition.new(
          work: unquote(condition),
          hash: unquote(condition_ast_hash),
          arity: unquote(arity)
        )
      end

    reaction = quote(do: step(unquote(expression)))

    arity_condition =
      quote do
        Condition.new(Components.is_of_arity?(unquote(arity)), unquote(arity))
      end

    quote do
      import Runic

      Workflow.new()
      |> Workflow.add_step(unquote(arity_condition))
      |> Workflow.add_step(unquote(arity_condition), unquote(condition))
      |> Workflow.add_step(unquote(condition), unquote(reaction))
    end
  end

  defp binds_of_guarded_anonymous(
         {:fn, _meta, [{:->, _, [[lhs], _rhs]}]} = _quoted_fun_expression,
         arity
       ) do
    binds_of_guarded_anonymous(lhs, arity)
  end

  defp binds_of_guarded_anonymous({:when, _meta, guarded_expression}, arity) do
    Enum.take(guarded_expression, arity)
  end

  # defp post_extract_guarded_into_workflow(
  #        {:when, _meta, _guarded_expression},
  #        %{
  #          component_ast_graph: g,
  #          arity_condition: arity_condition,
  #          reaction: reaction,
  #          conditions: conditions
  #        } = wrapped_wrk
  #      ) do
  #   component_ast_g =
  #     Enum.reduce(conditions, g, fn
  #       {lhs_of_or, rhs_of_or} = _or, g ->
  #         Graph.add_edges(g, [
  #           Graph.Edge.new(arity_condition, lhs_of_or),
  #           Graph.Edge.new(arity_condition, rhs_of_or)
  #         ])

  #       condition, g ->
  #         Graph.add_edge(g, arity_condition, condition)
  #     end)

  #   component_ast_g =
  #     component_ast_g
  #     |> Graph.add_vertex(reaction)
  #     |> Graph.add_edges(leaf_to_reaction_edges(component_ast_g, arity_condition, reaction))

  #   %{wrapped_wrk | component_ast_graph: component_ast_g}
  # end

  # defp post_extract_guarded_into_workflow(
  #        {:or, _meta, [lhs_of_or | [rhs_of_or | _]]} = ast,
  #        %{
  #          possible_children: possible_children
  #        } = wrapped_wrk
  #      ) do
  #   lhs_child_cond = Map.fetch!(possible_children, lhs_of_or)
  #   rhs_child_cond = Map.fetch!(possible_children, rhs_of_or)

  #   wrapped_wrk
  #   |> Map.put(
  #     :possible_children,
  #     Map.put(possible_children, ast, {lhs_child_cond, rhs_child_cond})
  #   )
  # end

  # defp post_extract_guarded_into_workflow(
  #        {:and, _meta, [lhs_of_and | [rhs_of_and | _]]} = ast,
  #        %{possible_children: possible_children, component_ast_graph: g} =
  #          wrapped_wrk
  #      ) do
  #   lhs_child_cond = Map.fetch!(possible_children, lhs_of_and)
  #   rhs_child_cond = Map.fetch!(possible_children, rhs_of_and)

  #   conditions = [lhs_child_cond, rhs_child_cond] |> List.flatten()

  #   conjunction = quote(do: Conjunction.new(unquote(conditions)))

  #   wrapped_wrk
  #   |> Map.put(
  #     :component_ast_graph,
  #     Enum.reduce(conditions, g, fn
  #       {lhs_of_or, rhs_of_or} = _or, g ->
  #         Graph.add_edges(g, [
  #           Graph.Edge.new(lhs_of_or, conjunction),
  #           Graph.Edge.new(rhs_of_or, conjunction)
  #         ])

  #       condition, g ->
  #         Graph.add_edge(g, condition, conjunction)
  #     end)
  #   )
  #   |> Map.put(:possible_children, Map.put(possible_children, ast, conjunction))
  # end

  # defp post_extract_guarded_into_workflow(
  #        {expr, _meta, children} = expression,
  #        %{binds: binds, arity_condition: arity_condition, arity: arity, component_ast_graph: g} =
  #          wrapped_wrk
  #      )
  #      when is_atom(expr) and not is_nil(children) do
  #   if expr in @boolean_expressions or binary_part(to_string(expr), 0, 2) === "is" do
  #     match_fun_ast =
  #       {:fn, [],
  #        [
  #          {:->, [],
  #           [
  #             [
  #               {:when, [], underscore_unused_binds(binds, expression) ++ [expression]}
  #             ],
  #             true
  #           ]},
  #          {:->, [], [Enum.map(binds, fn {_bind, _meta, cont} -> {:_, [], cont} end), false]}
  #        ]}

  #     ast_hash = Components.fact_hash(match_fun_ast)

  #     condition =
  #       quote(
  #         do:
  #           Condition.new(
  #             work: unquote(match_fun_ast),
  #             arity: unquote(arity),
  #             hash: unquote(ast_hash)
  #           )
  #       )

  #     wrapped_wrk
  #     |> Map.put(:component_ast_graph, Graph.add_edge(g, arity_condition, condition))
  #     |> Map.put(:conditions, [condition | wrapped_wrk.conditions])
  #     |> Map.put(
  #       :possible_children,
  #       Map.put(wrapped_wrk.possible_children, expression, condition)
  #     )
  #   else
  #     wrapped_wrk
  #   end
  # end

  # defp post_extract_guarded_into_workflow(
  #        _some_other_ast,
  #        acc
  #      ) do
  #   acc
  # end

  # defp underscore_unused_binds(binds, expression) do
  #   prewalked = Macro.prewalker(expression)

  #   Enum.map(binds, fn {_binding, meta, context} = bind ->
  #     if bind not in prewalked do
  #       {:_, meta, context}
  #     else
  #       bind
  #     end
  #   end)
  # end

  # defp leaf_to_reaction_edges(g, arity_condition, reaction) do
  #   Graph.Reducers.Dfs.reduce(g, [], fn
  #     ^arity_condition, leaf_edges ->
  #       {:next, leaf_edges}

  #     :root, leaf_edges ->
  #       {:next, leaf_edges}

  #     v, leaf_edges ->
  #       if Graph.out_degree(g, v) == 0 do
  #         {:next, [Graph.Edge.new(v, reaction) | leaf_edges]}
  #       else
  #         {:next, leaf_edges}
  #       end
  #   end)
  # end
end
