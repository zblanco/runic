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
  alias Runic.Workflow.FanOut
  alias Runic.Workflow.FanIn
  alias Runic.Workflow.Join

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

  A Step implements the Runic.Workflow.Activation, and Runic.Workflow.Component protocols for evaluation in a workflow and composition
  with other Runic components.

  ## Examples

  ```elixir
  require Runic
  import Runic

  iex> simple_0_arity_step = step(fn -> 42 end)
  iex> 1_arity_step = step(fn input -> input * 2 end)
  iex> 2_arity_step = step(fn input1, input2 -> input1 + input2 end)
  ```

  Steps that accept more than 1 input are not evaluated unless the workflow is evaluating a list of inputs the same length as its arity.

  Steps can also be defined with Options in a keyword list so that it can be referenced by other components.

  ## Options

  - `:name` - a name for the step that can be used to reference it in other components.
  - `:work` - the work to be done by the step, can be a function, or a quoted expression.

  ```elixir
  iex> named_step = step(
    name: :my_named_step,
    work: fn input -> input * 2 end
  )

  iex> alternately_named_step(
    fn input -> input * 2 end, name: :alternately_named_step
  )
  ```

  Steps can also be defined using captured functions:

  ```elixir
  iex> captured_step = step(&Enum.map/2)
  > %Runic.Workflow.Step{...}
  ```
  """
  defmacro step({:fn, _, _} = work) do
    source =
      quote do
        Runic.step(unquote(work))
      end

    {rewritten_work, work_bindings} = traverse_expression(work, __CALLER__)

    variable_bindings =
      work_bindings
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    quote do
      unquote_splicing(Enum.reverse(variable_bindings))

      Step.new(
        work: unquote(rewritten_work),
        source: unquote(Macro.escape(source)),
        hash: unquote(Components.fact_hash(work)),
        bindings: unquote(bindings)
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

    {rewritten_work, work_bindings} = traverse_expression(work, __CALLER__)

    variable_bindings =
      work_bindings
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    quote do
      unquote_splicing(Enum.reverse(variable_bindings))

      Step.new(
        work: unquote(rewritten_work),
        source: unquote(Macro.escape(source)),
        name: unquote(opts[:name]),
        hash: unquote(Components.fact_hash(work)),
        bindings: unquote(bindings)
      )
    end
  end

  defmacro step(work, opts) do
    source =
      quote do
        Runic.step(unquote(work), unquote(opts))
      end

    {rewritten_work, work_bindings} = traverse_expression(work, __CALLER__)

    variable_bindings =
      work_bindings
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    quote do
      unquote_splicing(Enum.reverse(variable_bindings))

      Step.new(
        work: unquote(rewritten_work),
        source: unquote(Macro.escape(source)),
        name: unquote(opts[:name]),
        hash: unquote(Components.fact_hash(work)),
        bindings: unquote(bindings)
      )
    end
  end

  @doc """
  Creates a %Condition{}: a conditional expression that can be added to a workflow or used as the left hand side of a rule.
  """
  def condition(fun) when is_function(fun) do
    Condition.new(fun)
  end

  def condition({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    Condition.new(Function.capture(m, f, a))
  end

  @doc """
  Invokes the Transmutable protocol of a component to convert it into a workflow.
  """
  def transmute(component) do
    Runic.Transmutable.transmute(component)
  end

  @doc """
  Define a Runic.Workflow with options.

  Runic Workflows are made up of many components connected to eachother through dataflow semantics.

  Runic Workflows can be made up of built in components like steps, rules, statemachines, and map or reduce operations.

  Runic Components can be combined together at runtime and evaluated in composition.

  See the `Runic.Workflow` documentation to learn more about using workflows in detail.

  ## Options

  - `:name` - a name for the workflow that can be used to reference it in other components.
  - `:steps` - a list of steps to add to the workflow. Steps defined here may be nested using the pipeline syntax, a tree of tuples with the step and any child steps.
  - `:rules` - a list of rules to add to the workflow.
  - `:before_hooks` - a list of hooks to run before a named component is evaluated in the workflow. Meant for debugging or dynamic changes to the workflow.
  - `:after_hooks` - a list of hooks to run after a named component is evaluated in the workflow. Meant for debugging or dynamic changes to the workflow.

  ## Examples

  ```elixir
  require Runic
  require Logger
  import Runic
  alias Runic.Workflow

  simple_workflow = workflow(
    name: :simple_workflow,
    steps: [
      step(fn -> 42 end),
      step(fn input -> String.upcase(input) end)
    ],
    rules: [
      rule(
        condition: fn input -> input == :hello end,
        reaction: fn input -> "Greeting: \#{input}" end
      )
    ]
  )

  iex> simple_workflow |> Workflow.react_until_satisfied(:hello) |> Workflow.raw_reactions()
  > [42, "HELLO", "Greeting: :hello"]

  workflow_with_hooks = workflow(
    name: :workflow_with_hooks,
    steps: [
      step(fn num -> 42 * num end, :times_42)
    ],
    before_hooks: [
      times_42: [
        fn step, wrk, input_fact ->
          Logger.debug(\"""
          Processing step: \#{step.name}
          with input: \#{fact.value}
          \""")

          wrk
        end
      ]
    ],
    after_hooks: [
      times_42: [
        fn step, wrk, output_fact ->
          Logger.debug(\"""
          Step processed: \#{step.name}
          produced output: \#{fact.value}
          \""")

          wrk
        end
      ]
    ]
  )

  workflow_with_pipeline_of_steps = workflow(
    name: :nested_pipeline_workflow,
    steps: [
      {step(fn num -> num * 2), [
        {step(fn num -> num + 2), [
          step(fn num -> num * 42)
        ]},
        step(fn num -> num + 1)
      ]}
    ]
  )
  ```
  """
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

  @doc """
  Rules are a way to define conditional reactions within a Runic workflow.

  Every rule has a left hand side that must match conditionally to execute the right hand side.

  A rule is like an elixir function except it's condition may be evaluated separately from its block of code.

  Rules also differ in that they can be evaluated with many other rules and evaluated together in composition.

  ## Examples

  ```elixir

  require Runic
  import Runic
  alias Runic.Workflow.Rule

  anonymous_function_rule = rule(fn input when is_binary(input) -> :string_found end)

  iex> Rule.check(anonymous_function_rule, "hello")
  > true

  iex> Rule.run(anonymous_function_rule, "hello")
  > :string_found
  ```

  We can also define the condition and reaction separately.

  This can be advantageous if more than one rule share the same condition and/or it is an expensive operation you don't
  want to evaluate many times for a single input.

  ```elixir
  example_rule = rule(
    condition: fn input -> ExpensiveAIModel.is_input_okay?(input) end,
    reaction: fn input -> MyModule.do_thing(input) end
  )
  ```

  You can also name the rule and define it with `if` and `do` options.

  ```elixir
  example_rule = rule(
    name: :example_rule,
    if: fn input -> ExpensiveAIModel.is_input_okay?(input) end,
    do: fn input -> MyModule.do_thing(input) end
  )
  ```
  """
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

    bindings = build_bindings(variable_bindings, __CALLER__)

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

    # Process the expression to extract pinned variables
    {rewritten_expression, expression_bindings} = traverse_expression(expression, __CALLER__)

    variable_bindings =
      expression_bindings
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    workflow = workflow_of_rule(rewritten_expression, arity)

    source =
      quote do
        Runic.rule(unquote(expression), unquote(opts))
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

  defp traverse_expression({:fn, meta, clauses}, env) do
    {rewritten_clauses, bindings_acc} =
      Enum.reduce(clauses, {[], []}, fn
        {:->, clause_meta, [args, block]}, {clauses_acc, bindings_acc} ->
          # Process each clause separately
          {new_block, new_bindings} =
            Macro.prewalk(block, bindings_acc, fn
              {:^, pin_meta, [{var, _, ctx} = expr]} = _pinned_ast, acc ->
                new_var = Macro.var(var, ctx)
                {new_var, [{:=, pin_meta, [new_var, expr]} | acc]}

              otherwise, acc ->
                {Macro.expand(otherwise, env), acc}
            end)

          new_clause = {:->, clause_meta, [args, new_block]}
          {[new_clause | clauses_acc], new_bindings}
      end)

    rewritten_expression = {:fn, meta, Enum.reverse(rewritten_clauses)}
    {rewritten_expression, bindings_acc}
  end

  defp traverse_expression({:&, _, _} = expression, _env) do
    {expression, []}
  end

  @doc """
  Defines a statemachine that can be evaluated within a Runic workflow.

  Runic state machines are a way to model stateful workflows with reducers that can conditionally accumulate state
  and reactors to act on the new state.

  You can think of a reducer as a rule that evaluates the input in context of the last known state accumulated.
  And reactors as rules that conditionally evaluate the new state returned by the reducer.

  ## Example
  ```elixir
  require Runic
  import Runic

  potato_lock =
    Runic.state_machine(
      name: "potato lock",
      init: %{code: "potato", state: :locked, contents: "ham"},
      reducer: fn
        :lock, state ->
          %{state | state: :locked}

        {:unlock, input_code}, %{code: code, state: :locked} = state
        when input_code == code ->
          %{state | state: :unlocked}

        {:unlock, _input_code}, %{state: :locked} = state ->
          state

        _input_code, %{state: :unlocked} = state ->
          state
      end,
      reactors: [
        fn %{state: :unlocked, contents: contents} -> contents end,
        fn %{state: :locked} -> {:error, :locked} end
      ]
    )
  ```
  """
  defmacro state_machine(opts) do
    init = opts[:init] || raise ArgumentError, "An `init` function or state is required"

    reducer =
      Keyword.get(opts, :reducer) ||
        raise ArgumentError, "A reducer function is required"

    reactors = opts[:reactors]

    name = opts[:name]

    {rewritten_reducer, reducer_bindings} = traverse_expression(reducer, __CALLER__)

    variable_bindings =
      reducer_bindings
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    workflow = workflow_of_state_machine(init, rewritten_reducer, reactors, name)

    source =
      quote do
        Runic.state_machine(unquote(opts))
      end

    quote do
      unquote_splicing(Enum.reverse(variable_bindings))

      %StateMachine{
        name: unquote(name),
        init: unquote(init),
        reducer: unquote(rewritten_reducer),
        reactors: unquote(reactors),
        workflow: unquote(workflow) |> Map.put(:name, unquote(name)),
        source: unquote(Macro.escape(source)),
        hash: unquote(Components.fact_hash({init, rewritten_reducer, reactors})),
        bindings: unquote(bindings)
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

    {rewritten_expression, expression_bindings} =
      case expression do
        {:fn, _, _} -> traverse_expression(expression, __CALLER__)
        _ -> {expression, []}
      end

    variable_bindings =
      expression_bindings
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    pipeline_graph_of_ast =
      pipeline_graph_of_map_expression(rewritten_expression, name)

    source =
      quote do
        Runic.map(unquote(rewritten_expression), unquote(opts))
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
      unquote_splicing(Enum.reverse(variable_bindings))

      %Runic.Workflow.Map{
        name: unquote(name),
        pipeline: unquote(map_pipeline),
        hash: unquote(Components.fact_hash({rewritten_expression, name})),
        source: unquote(Macro.escape(source)),
        bindings: unquote(bindings)
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

    {rewritten_reducer_fun, reducer_bindings} = traverse_expression(reducer_fun, __CALLER__)

    variable_bindings =
      reducer_bindings
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    source =
      quote do
        Runic.reduce(unquote(acc), unquote(reducer_fun), unquote(opts))
      end

    quote do
      unquote_splicing(Enum.reverse(variable_bindings))

      hash = unquote(Components.fact_hash({acc, rewritten_reducer_fun}))

      %Runic.Workflow.Reduce{
        name: unquote(name),
        hash: hash,
        fan_in: %FanIn{
          map: unquote(map_to_reduce),
          init: fn -> unquote(acc) end,
          reducer: unquote(rewritten_reducer_fun),
          hash: hash
        },
        source: unquote(Macro.escape(source)),
        bindings: unquote(bindings)
      }
    end
  end

  defp build_bindings(variable_bindings, caller_context) do
    if not Enum.empty?(variable_bindings) do
      quote do
        %{
          unquote_splicing(
            Enum.map(variable_bindings, fn {:=, _, [{left_var, _, _}, right]} ->
              {left_var, right}
            end)
          ),
          __caller_context__: unquote(Macro.escape(caller_context))
        }
      end
    else
      quote do
        %{}
      end
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

          # arity_check =
          #   quote do
          #     Condition.new(Components.is_of_arity?(1))
          #   end

          quote generated: true do
            unquote(wrk)
            |> Workflow.add_step(unquote(state_condition))
            # |> Workflow.add_step(unquote(arity_check))
            # |> Workflow.add_step(unquote(arity_check), unquote(state_condition))
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
            fn workflow, _fact ->
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
        hash: unquote(Components.fact_hash(reactor_ast)),
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
end
