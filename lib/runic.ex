defmodule Runic do
  @moduledoc """
  Runic is a tool for modeling your workflows as data that can be composed together at runtime.

  Runic constructs can be integrated into a Runic.Workflow and evaluated lazily in concurrent contexts.

  Runic Workflows are a decorated dataflow graph (a DAG - "directed acyclic graph") of your code that can model your rules, pipelines, and state machines.

  Basic data flow dependencies such as in a pipeline are modeled as %Step{} structs (nodes/vertices) in the graph with directed edges (arrows) between steps.

  Steps can be thought of as a simple input -> output lambda function.

  As Facts are fed through a workflow, various steps are traversed to as needed and activated producing more Facts.

  Beyond steps, Runic has support for Rules and Accumulators for conditional and stateful evaluation.

  Together this enables Runic to express complex decision trees, finite state machines, data pipelines, and more.

  The Runic.Flowable protocol is what allows for extension of Runic and composability of structures like Workflows, Steps, Rules, and Accumulators by allowing user defined structures to be integrated into a `Runic.Workflow`.

  See the Runic.Workflow module for more information.

  This top level module provides high level functions and macros for building Runic Flowables
    such as Steps, Rules, Workflows, and Accumulators.

  This core library is responsible for modeling Workflows with Steps, enforcing contracts of Step functions,
    and defining the contract of Runners used to execute Workflows.

  Runic was designed to be used with custom process topologies and/or libraries such as GenStage, Broadway, and Flow.

  Runic is meant for dynamic runtime modification of a workflow where you might want to compose pieces of a workflow together.

  These sorts of use cases are common in expert systems, user DSLs (e.g. Excel, low-code tools) where a developer cannot know
    upfront the logic or data flow to be expressed in compiled code.

  If the runtime modification of a workflow isn't something your use case requires - don't use Runic.

  There are performance trade-offs in doing highly optimized things such as pattern matching and compilation at runtime.

  But if you do have complex user defined workflow, a database of things such as "rules" that have context-dependent
  composition at runtime - Runic may be the right tool for you.
  """
  alias Runic.Workflow
  alias Runic.Workflow.Step
  alias Runic.Workflow.Condition
  alias Runic.Workflow.Rule
  # alias Runic.Workflow.StateMachine
  alias Runic.Workflow.Components
  alias Runic.Workflow.Conjunction

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

  # defp maybe_expand(condition, context) when is_list(condition) do
  #   Enum.map(condition, &maybe_expand(&1, context))
  # end

  # defp maybe_expand({:&, _, [{:/, _, _}]} = captured_function_ast, context) do
  #   Macro.prewalk(captured_function_ast, fn
  #     {:__aliases__, _meta, _aliases} = alias_ast ->
  #       Macro.expand(alias_ast, context)

  #     ast_otherwise ->
  #       ast_otherwise
  #   end)
  # end

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
    Runic.Component.to_workflow(component)
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

  defp workflow_of_rule({condition, reaction}, _arity) do
    reaction = quote(do: step(unquote(reaction)))

    condition = quote(do: Condition.new(unquote(condition)))

    quote do
      import Runic

      Workflow.new()
      |> Workflow.add_step(unquote(condition))
      |> Workflow.add_step(unquote(condition), unquote(reaction))
    end
  end

  defp workflow_of_rule({:fn, _, [{:->, _, [[], _rhs]}]} = expression, 0 = _arity) do
    reaction = quote(do: step(unquote(expression)))

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
    reaction = quote(do: step(unquote(expression)))

    arity_condition =
      quote do
        Condition.new(Components.is_of_arity?(unquote(arity)))
      end

    workflow_with_arity_check_quoted =
      quote do
        Workflow.new()
        |> Workflow.add_step(Condition.new(Components.is_of_arity?(unquote(arity))))
      end

    component_ast_graph =
      quote do
        unquote(
          lhs
          |> Macro.postwalker()
          |> Enum.reduce(
            %{
              component_ast_graph: Graph.new() |> Graph.add_vertex(:root),
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
                    Macro.pipe(
                      quoted_workflow,
                      quote do
                        Workflow.add_step(unquote(ast_vertex))
                      end,
                      0
                    )

                  parent, quoted_workflow ->
                    Macro.pipe(
                      quoted_workflow,
                      quote do
                        Workflow.add_step(unquote(parent), unquote(ast_vertex))
                      end,
                      0
                    )
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
         1 = _arity
       ) do
    condition =
      {:fn, head_meta,
       [
         {:->, clause_meta, [[lhs], true]},
         {:->, clause_meta, [[{:_otherwise, [if_undefined: :apply], Elixir}], false]}
       ]}

    condition =
      quote do
        Condition.new(unquote(condition))
      end

    reaction = quote(do: step(unquote(expression)))

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

    conditions = [lhs_child_cond, rhs_child_cond]

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

      condition = quote(do: Condition.new(unquote(match_fun_ast), unquote(arity)))

      wrapped_wrk
      |> Map.put(
        :component_ast_graph,
        g |> Graph.add_edge(:root, arity_condition) |> Graph.add_edge(arity_condition, condition)
      )
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
        Graph.out_degree(g, arity_condition)
        {:next, leaf_edges}

      :root, leaf_edges ->
        {:next, leaf_edges}

      v, leaf_edges ->
        Graph.out_degree(g, v)

        if Graph.out_degree(g, v) == 0 do
          {:next, [Graph.Edge.new(v, reaction) | leaf_edges]}
        else
          {:next, leaf_edges}
        end
    end)
  end
end
