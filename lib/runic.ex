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

  @boolean_expressions ~w(
    ==
    ===
    !=
    !==
    <
    >
    <=
    >=
    in
    not
    =~
  )a

  @doc """
  Creates a %Step{}: a basic lambda expression that can be added to a workflow.

  Steps are basic input -> output dataflow primatives that can be connected together in a workflow.

  A Step implements the Runic.Workflow.Activation, and Runic.Workflow.Component protocols
  to be composable and possible to evaluate at runtime with inputs.
  """
  def step(opts \\ [])

  def step(work) when is_function(work) do
    step(work: work)
  end

  def step(opts) when is_list(opts) do
    Step.new(opts)
  end

  def step(opts) when is_map(opts) do
    Step.new(opts)
  end

  def step(work, opts) when is_function(work) do
    Step.new(Keyword.merge([work: work], opts))
  end

  def step({m, f, a} = work, opts) when is_atom(m) and is_atom(f) and is_integer(a) do
    Step.new(Keyword.merge([work: work], opts))
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

    Workflow.new(name)
    |> add_steps(steps)
    |> add_rules(rules)
  end

  defmacro rule(opts) when is_list(opts) do
    condition = opts[:condition] || opts[:if]
    reaction = opts[:reaction] || opts[:do]

    arity = Components.arity_of(reaction)

    workflow = workflow_of_rule({condition, reaction}, arity)

    quote do
      %Rule{
        expression: unquote({Macro.escape(condition), Macro.escape(reaction)}),
        arity: unquote(arity),
        workflow: unquote(workflow)
      }
    end
  end

  defmacro rule(expression) do
    arity = Components.arity_of(expression)

    workflow = workflow_of_rule(expression, arity)

    quote bind_quoted: [
            expression: Macro.escape(expression),
            arity: arity,
            workflow: workflow
          ] do
      %Rule{
        arity: arity,
        workflow: workflow,
        expression: expression
      }
    end
  end

  defmacro rule(expression, opts) when is_list(opts) do
    name = opts[:name]

    arity = Components.arity_of(expression)

    workflow = workflow_of_rule(expression, arity)

    quote bind_quoted: [
            name: name,
            expression: Macro.escape(expression),
            arity: arity,
            workflow: workflow
          ] do
      %Rule{
        name: name,
        arity: arity,
        workflow: workflow,
        expression: expression
      }
    end
  end

  defmacro state_machine(opts) do
    init = opts[:init] || raise ArgumentError, "An `init` function or state is required"

    reducer =
      Keyword.get(opts, :reducer) ||
        raise ArgumentError, "A reducer function is required"

    reactors = opts[:reactors]

    name = opts[:name]

    workflow = workflow_of_state_machine(init, reducer, reactors, name)

    quote do
      %StateMachine{
        name: unquote(name),
        init: unquote(init),
        reducer: unquote(reducer),
        reactors: unquote(reactors),
        workflow: unquote(workflow) |> Map.put(:name, unquote(name))
      }
    end
  end

  @doc """
  map/1 applies the expression to each element in the enumerable.

  A map expression can be a function, a list, or a nested pipeline expression of steps.

  The input fact to the map expression must implement the Enumerable protocol so that during workflow evaluation
  the map expression can be applied to each element as a runnable.

  A Runic map expression must be inside a Runic workflow to be evaluated.

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
  ```
  """
  defmacro map(expression) do
    quote do
      unquote(pipeline_of_map_expression(expression))
    end
  end

  def reduce(acc, reducer_fun) do
    %Accumulator{
      init: acc,
      reducer: reducer_fun,
      hash: Components.fact_hash({acc, reducer_fun})
    }
  end

  defp pipeline_of_map_expression({:fn, _, _} = expression) do
    fan_out =
      quote do
        %FanOut{
          hash: unquote(Components.fact_hash({:fan_out, expression}))
        }
      end

    step = pipeline_step(expression)

    quote do
      {unquote(fan_out), [unquote(step)]}
    end
  end

  defp pipeline_of_map_expression(
         {step_expression, [_ | _] = dependent_steps} = pipeline_expression
       ) do
    fan_out =
      quote do
        %FanOut{
          hash: unquote(Components.fact_hash({:fan_out, pipeline_expression}))
        }
      end

    step = pipeline_step(step_expression)

    dependent_pipeline = pipeline_of_expression(dependent_steps)

    quote do
      {unquote(fan_out), [{unquote(step), unquote(dependent_pipeline)}]}
    end
  end

  defp pipeline_of_map_expression({:&, _, _} = expression) do
    fan_out =
      quote do
        %FanOut{
          hash: unquote(Components.fact_hash({:fan_out, expression}))
        }
      end

    step = pipeline_step(expression)

    quote do
      {unquote(fan_out), [unquote(step)]}
    end
  end

  defp pipeline_of_expression(dependent_steps) when is_list(dependent_steps) do
    Enum.map(dependent_steps, &pipeline_of_expression/1)
  end

  defp pipeline_of_expression({{:fn, _, _} = anonymous_step_expression, dependent_steps}) do
    {pipeline_step(anonymous_step_expression), pipeline_of_expression(dependent_steps)}
  end

  defp pipeline_of_expression({{:., _, [_, :map]}, _, [expression]}) do
    pipeline_of_map_expression(expression)
  end

  defp pipeline_of_expression({{:., _, [_, :step]}, _, _} = expression) do
    expression
  end

  defp pipeline_of_expression({:map, _, [expression]}) do
    pipeline_of_map_expression(expression)
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

  defp pipeline_step({{:., _, [_, :step]}, _, _} = expression) do
    expression
  end

  defp pipeline_step({:step, _, _} = expression) do
    expression
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

  defp add_steps(workflow, steps) when is_list(steps) do
    # root level pass
    Enum.reduce(steps, workflow, fn
      %Step{} = step, wrk ->
        Workflow.add_step(wrk, step)

      {%Step{} = step, _dependent_steps} = parent_and_children, wrk ->
        wrk = Workflow.add_step(wrk, step)
        add_dependent_steps(parent_and_children, wrk)

      {[_step | _] = parent_steps, dependent_steps}, wrk ->
        wrk = Enum.reduce(parent_steps, wrk, fn step, wrk -> Workflow.add_step(wrk, step) end)

        join =
          parent_steps
          |> Enum.map(& &1.hash)
          |> Workflow.Join.new()

        wrk = Workflow.add_step(wrk, parent_steps, join)

        add_dependent_steps({join, dependent_steps}, wrk)
    end)
  end

  defp add_steps(workflow, nil), do: workflow

  defp add_dependent_steps({parent_step, dependent_steps}, workflow) do
    Enum.reduce(dependent_steps, workflow, fn
      {[_step | _] = parent_steps, dependent_steps}, wrk ->
        wrk =
          Enum.reduce(parent_steps, wrk, fn step, wrk ->
            Workflow.add_step(wrk, parent_step, step)
          end)

        join =
          parent_steps
          |> Enum.map(& &1.hash)
          |> Workflow.Join.new()

        wrk = Workflow.add_step(wrk, parent_steps, join)

        add_dependent_steps({join, dependent_steps}, wrk)

      {step, _dependent_steps} = parent_and_children, wrk ->
        wrk = Workflow.add_step(wrk, parent_step, step)
        add_dependent_steps(parent_and_children, wrk)

      step, wrk ->
        Workflow.add_step(wrk, parent_step, step)
    end)
  end

  defp add_rules(workflow, nil), do: workflow

  defp add_rules(workflow, rules) do
    Enum.reduce(rules, workflow, fn %Rule{} = rule, wrk ->
      Workflow.add_rule(wrk, rule)
    end)
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
         {:fn, _meta, [{:->, _, [[{:when, _, _} = lhs], _rhs]}]} = expression,
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

    component_ast_graph =
      quote do
        unquote(
          lhs
          |> Macro.postwalker()
          |> Enum.reduce(
            %{
              component_ast_graph:
                Graph.new() |> Graph.add_vertex(:root) |> Graph.add_edge(:root, arity_condition),
              arity: arity,
              arity_condition: arity_condition,
              binds: binds_of_guarded_anonymous(expression, arity),
              reaction: reaction,
              children: [],
              possible_children: %{},
              conditions: []
            },
            &post_extract_guarded_into_workflow/2
          )
          |> Map.get(:component_ast_graph)
        )
      end

    quoted_workflow =
      quote do
        import Runic

        component_ast_graph = unquote(Macro.escape(component_ast_graph))

        unquote(
          Graph.Reducers.Bfs.reduce(component_ast_graph, workflow_with_arity_check_quoted, fn
            ast_vertex, quoted_workflow ->
              parents = Graph.in_neighbors(component_ast_graph, ast_vertex)

              quoted_workflow =
                Enum.reduce(parents, quoted_workflow, fn
                  :root, quoted_workflow ->
                    quote do
                      unquote(quoted_workflow)
                      |> Workflow.add_step(unquote(ast_vertex))
                    end

                  parent, quoted_workflow ->
                    quote do
                      unquote(quoted_workflow)
                      |> Workflow.add_step(unquote(parent), unquote(ast_vertex))
                    end
                end)

              {:next, quoted_workflow}
          end)
        )
      end

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

  defp post_extract_guarded_into_workflow(
         {:when, _meta, _guarded_expression},
         %{
           component_ast_graph: g,
           arity_condition: arity_condition,
           reaction: reaction,
           conditions: conditions
         } = wrapped_wrk
       ) do
    component_ast_g =
      Enum.reduce(conditions, g, fn
        {lhs_of_or, rhs_of_or} = _or, g ->
          Graph.add_edges(g, [
            Graph.Edge.new(arity_condition, lhs_of_or),
            Graph.Edge.new(arity_condition, rhs_of_or)
          ])

        condition, g ->
          Graph.add_edge(g, arity_condition, condition)
      end)

    component_ast_g =
      component_ast_g
      |> Graph.add_vertex(reaction)
      |> Graph.add_edges(leaf_to_reaction_edges(component_ast_g, arity_condition, reaction))

    %{wrapped_wrk | component_ast_graph: component_ast_g}
  end

  defp post_extract_guarded_into_workflow(
         {:or, _meta, [lhs_of_or | [rhs_of_or | _]]} = ast,
         %{
           possible_children: possible_children
         } = wrapped_wrk
       ) do
    lhs_child_cond = Map.fetch!(possible_children, lhs_of_or)
    rhs_child_cond = Map.fetch!(possible_children, rhs_of_or)

    wrapped_wrk
    |> Map.put(
      :possible_children,
      Map.put(possible_children, ast, {lhs_child_cond, rhs_child_cond})
    )
  end

  defp post_extract_guarded_into_workflow(
         {:and, _meta, [lhs_of_and | [rhs_of_and | _]]} = ast,
         %{possible_children: possible_children, component_ast_graph: g} =
           wrapped_wrk
       ) do
    lhs_child_cond = Map.fetch!(possible_children, lhs_of_and)
    rhs_child_cond = Map.fetch!(possible_children, rhs_of_and)

    conditions = [lhs_child_cond, rhs_child_cond] |> List.flatten()

    conjunction = quote(do: Conjunction.new(unquote(conditions)))

    wrapped_wrk
    |> Map.put(
      :component_ast_graph,
      Enum.reduce(conditions, g, fn
        {lhs_of_or, rhs_of_or} = _or, g ->
          Graph.add_edges(g, [
            Graph.Edge.new(lhs_of_or, conjunction),
            Graph.Edge.new(rhs_of_or, conjunction)
          ])

        condition, g ->
          Graph.add_edge(g, condition, conjunction)
      end)
    )
    |> Map.put(:possible_children, Map.put(possible_children, ast, conjunction))
  end

  defp post_extract_guarded_into_workflow(
         {expr, _meta, children} = expression,
         %{binds: binds, arity_condition: arity_condition, arity: arity, component_ast_graph: g} =
           wrapped_wrk
       )
       when is_atom(expr) and not is_nil(children) do
    if expr in @boolean_expressions or binary_part(to_string(expr), 0, 2) === "is" do
      match_fun_ast =
        {:fn, [],
         [
           {:->, [],
            [
              [
                {:when, [], underscore_unused_binds(binds, expression) ++ [expression]}
              ],
              true
            ]},
           {:->, [], [Enum.map(binds, fn {_bind, _meta, cont} -> {:_, [], cont} end), false]}
         ]}

      ast_hash = Components.fact_hash(match_fun_ast)

      condition =
        quote(
          do:
            Condition.new(
              work: unquote(match_fun_ast),
              arity: unquote(arity),
              hash: unquote(ast_hash)
            )
        )

      wrapped_wrk
      |> Map.put(:component_ast_graph, Graph.add_edge(g, arity_condition, condition))
      |> Map.put(:conditions, [condition | wrapped_wrk.conditions])
      |> Map.put(
        :possible_children,
        Map.put(wrapped_wrk.possible_children, expression, condition)
      )
    else
      wrapped_wrk
    end
  end

  defp post_extract_guarded_into_workflow(
         _some_other_ast,
         acc
       ) do
    acc
  end

  defp underscore_unused_binds(binds, expression) do
    prewalked = Macro.prewalker(expression)

    Enum.map(binds, fn {_binding, meta, context} = bind ->
      if bind not in prewalked do
        {:_, meta, context}
      else
        bind
      end
    end)
  end

  defp leaf_to_reaction_edges(g, arity_condition, reaction) do
    Graph.Reducers.Dfs.reduce(g, [], fn
      ^arity_condition, leaf_edges ->
        {:next, leaf_edges}

      :root, leaf_edges ->
        {:next, leaf_edges}

      v, leaf_edges ->
        if Graph.out_degree(g, v) == 0 do
          {:next, [Graph.Edge.new(v, reaction) | leaf_edges]}
        else
          {:next, leaf_edges}
        end
    end)
  end
end
