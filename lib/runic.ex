defmodule Runic do
  @external_resource "README.md"
  @moduledoc "README.md" |> File.read!() |> String.split("<!-- MDOC !-->") |> Enum.fetch!(1)

  alias Runic.Closure
  alias Runic.ClosureMetadata
  alias Runic.Workflow.CompilationUtils
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

  defp default_component_name(component_kind, hash) do
    "#{component_kind}_#{hash}"
  end

  @doc """
  Creates a %Step{}: a basic lambda expression that can be added to a workflow.

  Steps are basic input -> output dataflow primatives that can be connected together in a workflow.

  A Step implements the Runic.Workflow.Activation, and Runic.Workflow.Component protocols for evaluation in a workflow and composition
  with other Runic components.

  ## Examples

  ```elixir
  require Runic
  import Runic

  # Simple steps without captured variables
  iex> simple_0_arity_step = step(fn -> 42 end)
  iex> 1_arity_step = step(fn input -> input * 2 end)
  iex> 2_arity_step = step(fn input1, input2 -> input1 + input2 end)

  # Steps with captured variables (use ^)
  iex> outer_value = 100
  iex> step_with_binding = step(fn x -> x + ^outer_value end)
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

    # Build closure source with FULL component creation using rewritten work
    # This way when evaluated, it returns a Step struct, not just a function
    closure_source =
      quote do
        Runic.step(unquote(rewritten_work))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    # If we have bindings, compute hash at runtime to include binding values
    # Otherwise compute at compile time
    if Enum.empty?(variable_bindings) do
      step_hash = Components.fact_hash(source)
      work_hash = Components.fact_hash(work)

      quote do
        Step.new(
          work: unquote(rewritten_work),
          closure: unquote(closure),
          name: unquote(default_component_name("step", step_hash)),
          hash: unquote(step_hash),
          work_hash: unquote(work_hash),
          inputs: nil,
          outputs: nil
        )
      end
    else
      # For content addressability, normalize the work AST before hashing
      normalized_work = normalize_ast(rewritten_work)

      quote do
        closure = unquote(closure)
        # Step hash is based on the closure (full component creation)
        step_hash = closure.hash
        # Work hash is based on NORMALIZED AST + bindings for deterministic content addressing
        work_hash =
          Components.fact_hash({unquote(Macro.escape(normalized_work)), closure.bindings})

        Step.new(
          work: unquote(rewritten_work),
          closure: closure,
          name: unquote(default_component_name("step", "_")) <> "_#{step_hash}",
          hash: step_hash,
          work_hash: work_hash,
          inputs: nil,
          outputs: nil
        )
      end
    end
  end

  defmacro step({:&, _, _} = work) do
    source =
      quote do
        Runic.step(unquote(work))
      end

    step_hash = Components.fact_hash(source)
    work_hash = Components.fact_hash(work)

    # For captured functions, the closure source is the full step creation
    closure_source = source
    closure = build_closure(closure_source, [], __CALLER__)

    quote do
      Step.new(
        work: unquote(work),
        closure: unquote(closure),
        name: unquote(default_component_name("step", step_hash)),
        hash: unquote(step_hash),
        work_hash: unquote(work_hash),
        inputs: nil,
        outputs: nil
      )
    end
  end

  defmacro step(opts) when is_list(opts) or is_map(opts) do
    {rewritten_opts, opts_bindings} =
      if is_list(opts), do: traverse_options(opts, __CALLER__), else: {opts, []}

    work = rewritten_opts[:work]

    source =
      quote do
        Runic.step(unquote(opts))
      end

    {rewritten_work, work_bindings} = traverse_expression(work, __CALLER__)

    variable_bindings =
      (work_bindings ++ opts_bindings)
      |> Enum.uniq()

    # Build closure source with FULL component creation
    closure_source =
      quote do
        Runic.step(unquote(rewritten_opts))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    # If we have bindings, compute hash at runtime
    # Otherwise compute at compile time
    if Enum.empty?(variable_bindings) do
      step_hash = Components.fact_hash(source)
      work_hash = Components.fact_hash(work)
      step_name = rewritten_opts[:name] || default_component_name("step", step_hash)

      quote do
        Step.new(
          work: unquote(rewritten_work),
          closure: unquote(closure),
          name: unquote(step_name),
          hash: unquote(step_hash),
          work_hash: unquote(work_hash),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        )
      end
    else
      base_name = rewritten_opts[:name]
      normalized_work = normalize_ast(rewritten_work)

      quote do
        closure = unquote(closure)
        step_hash = closure.hash

        work_hash =
          Components.fact_hash({unquote(Macro.escape(normalized_work)), closure.bindings})

        step_name =
          if unquote(base_name) do
            unquote(base_name)
          else
            unquote(default_component_name("step", "_")) <> "_#{step_hash}"
          end

        Step.new(
          work: unquote(rewritten_work),
          closure: closure,
          name: step_name,
          hash: step_hash,
          work_hash: work_hash,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        )
      end
    end
  end

  defmacro step(work, opts) do
    {rewritten_opts, opts_bindings} =
      if is_list(opts), do: traverse_options(opts, __CALLER__), else: {opts, []}

    source =
      quote do
        Runic.step(unquote(work), unquote(opts))
      end

    {rewritten_work, work_bindings} = traverse_expression(work, __CALLER__)

    variable_bindings =
      (work_bindings ++ opts_bindings)
      |> Enum.uniq()

    # Build closure source with FULL component creation
    closure_source =
      quote do
        Runic.step(unquote(rewritten_work), unquote(opts))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    # If we have bindings, compute hash at runtime
    # Otherwise compute at compile time
    if Enum.empty?(variable_bindings) do
      step_hash = Components.fact_hash(source)
      work_hash = Components.fact_hash(work)
      step_name = rewritten_opts[:name] || default_component_name("step", step_hash)

      quote do
        Step.new(
          work: unquote(rewritten_work),
          closure: unquote(closure),
          name: unquote(step_name),
          hash: unquote(step_hash),
          work_hash: unquote(work_hash),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        )
      end
    else
      base_name = rewritten_opts[:name]
      normalized_work = normalize_ast(rewritten_work)

      quote do
        closure = unquote(closure)
        step_hash = closure.hash

        work_hash =
          Components.fact_hash({unquote(Macro.escape(normalized_work)), closure.bindings})

        step_name =
          if unquote(base_name) do
            unquote(base_name)
          else
            unquote(default_component_name("step", "_")) <> "_#{step_hash}"
          end

        Step.new(
          work: unquote(rewritten_work),
          closure: closure,
          name: step_name,
          hash: step_hash,
          work_hash: work_hash,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        )
      end
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
  Invokes the Transmutable protocol of a component until it becomes a workflow.
  """
  def transmute(component) do
    component
    |> Runic.Transmutable.transmute()
    |> do_transmute()
  end

  defp do_transmute(%Workflow{} = workflow), do: workflow
  defp do_transmute(component), do: transmute(component)

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

  ## Explicit DSL Syntax

  For more complex rules with meta-conditions, use the explicit given/where/then syntax:

  ```elixir
  rule do
    given order: %{status: status, total: total}
    where status == :pending and total > 100
    then fn %{order: order} -> {:apply_discount, order} end
  end
  ```

  Or with options:

  ```elixir
  rule name: :discount_rule do
    given order: %{status: status, total: total}
    where status == :pending and total > 100
    then fn %{order: order} -> {:apply_discount, order} end
  end
  ```

  Note: We use `where` instead of `when` because `when` is a special form in Elixir
  that binds to the previous expression (used for guards), which would interfere
  with the DSL parsing.
  """
  # Handle rule with do block containing given/when/then DSL
  defmacro rule(opts_or_block)

  defmacro rule([{:do, block}]) do
    compile_given_when_then_rule(block, [], __CALLER__)
  end

  defmacro rule(opts) when is_list(opts) do
    {rewritten_opts, opts_bindings} = traverse_options(opts, __CALLER__)

    name = rewritten_opts[:name]
    condition = rewritten_opts[:condition] || rewritten_opts[:if]
    reaction = rewritten_opts[:reaction] || rewritten_opts[:do]

    arity = Components.arity_of(reaction)

    {rewritten_reaction, reaction_bindings} = traverse_expression(reaction, __CALLER__)

    variable_bindings =
      (reaction_bindings ++ opts_bindings)
      |> Enum.uniq()

    {workflow, condition_hash, reaction_hash} =
      workflow_of_rule({condition, rewritten_reaction}, arity)

    source =
      quote do
        Runic.rule(unquote(opts))
      end

    # Build closure with full rule creation
    closure_source =
      quote do
        Runic.rule(unquote(rewritten_opts))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    if Enum.empty?(variable_bindings) do
      rule_hash = Components.fact_hash(source)
      rule_name = name || default_component_name("rule", rule_hash)

      quote do
        %Rule{
          name: unquote(rule_name),
          arity: unquote(arity),
          workflow: unquote(workflow),
          condition_hash: unquote(condition_hash),
          reaction_hash: unquote(reaction_hash),
          hash: unquote(rule_hash),
          closure: unquote(closure),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    else
      base_name = name

      quote do
        closure = unquote(closure)
        rule_hash = closure.hash

        rule_name =
          if unquote(base_name),
            do: unquote(base_name),
            else: unquote(default_component_name("rule", "_")) <> "_#{rule_hash}"

        %Rule{
          name: rule_name,
          arity: unquote(arity),
          workflow: unquote(workflow),
          condition_hash: unquote(condition_hash),
          reaction_hash: unquote(reaction_hash),
          hash: rule_hash,
          closure: closure,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    end
  end

  defmacro rule(expression) do
    arity = Components.arity_of(expression)
    {rewritten_expression, expression_bindings} = traverse_expression(expression, __CALLER__)

    variable_bindings =
      expression_bindings
      |> Enum.uniq()

    {workflow, condition_hash, reaction_hash} = workflow_of_rule(rewritten_expression, arity)

    source =
      quote do
        Runic.rule(unquote(expression))
      end

    closure_source =
      quote do
        Runic.rule(unquote(rewritten_expression))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    if Enum.empty?(variable_bindings) do
      rule_hash = Components.fact_hash(source)
      rule_name = default_component_name("rule", rule_hash)

      quote do
        %Rule{
          name: unquote(rule_name),
          arity: unquote(arity),
          workflow: unquote(workflow),
          hash: unquote(rule_hash),
          condition_hash: unquote(condition_hash),
          reaction_hash: unquote(reaction_hash),
          closure: unquote(closure)
        }
      end
    else
      quote do
        closure = unquote(closure)
        rule_hash = closure.hash
        rule_name = unquote(default_component_name("rule", "_")) <> "_#{rule_hash}"

        %Rule{
          name: rule_name,
          arity: unquote(arity),
          workflow: unquote(workflow),
          hash: rule_hash,
          condition_hash: unquote(condition_hash),
          reaction_hash: unquote(reaction_hash),
          closure: closure
        }
      end
    end
  end

  # Handle rule name: :foo do given/when/then end
  defmacro rule(opts, [{:do, block}]) when is_list(opts) do
    compile_given_when_then_rule(block, opts, __CALLER__)
  end

  defmacro rule(expression, opts) when is_list(opts) do
    {rewritten_opts, opts_bindings} = traverse_options(opts, __CALLER__)

    name = rewritten_opts[:name]
    arity = Components.arity_of(expression)

    # Process the expression to extract pinned variables
    {rewritten_expression, expression_bindings} = traverse_expression(expression, __CALLER__)

    variable_bindings =
      (expression_bindings ++ opts_bindings)
      |> Enum.uniq()

    {workflow, condition_hash, reaction_hash} = workflow_of_rule(rewritten_expression, arity)

    source =
      quote do
        Runic.rule(unquote(expression), unquote(opts))
      end

    # Build closure source with full rule creation
    closure_source =
      quote do
        Runic.rule(unquote(rewritten_expression), unquote(rewritten_opts))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    # If we have bindings, compute hash at runtime
    # Otherwise compute at compile time
    if Enum.empty?(variable_bindings) do
      rule_hash = Components.fact_hash(source)
      rule_name = name || default_component_name("rule", rule_hash)

      quote do
        %Rule{
          name: unquote(rule_name),
          arity: unquote(arity),
          workflow: unquote(workflow),
          hash: unquote(rule_hash),
          condition_hash: unquote(condition_hash),
          reaction_hash: unquote(reaction_hash),
          closure: unquote(closure),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    else
      base_name = name

      quote do
        closure = unquote(closure)
        rule_hash = closure.hash

        rule_name =
          if unquote(base_name),
            do: unquote(base_name),
            else: unquote(default_component_name("rule", "_")) <> "_#{rule_hash}"

        %Rule{
          name: rule_name,
          arity: unquote(arity),
          workflow: unquote(workflow),
          hash: rule_hash,
          condition_hash: unquote(condition_hash),
          reaction_hash: unquote(reaction_hash),
          closure: closure,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    end
  end

  defp traverse_expression({:fn, meta, clauses}, env) do
    # Collect argument names from all clauses
    # all_arg_vars =
    #   Enum.flat_map(clauses, fn {:->, _meta, [args, _block]} ->
    #     args
    #     |> List.flatten()
    #     |> Enum.flat_map(fn arg -> collect_pattern_vars(arg) end)
    #   end)
    #   |> MapSet.new()

    {rewritten_clauses, bindings_acc} =
      Enum.reduce(clauses, {[], []}, fn
        {:->, clause_meta, [args, block]}, {clauses_acc, bindings_acc} ->
          # Collect variables assigned in the body (these are local, not free)
          # body_assigned_vars = collect_assigned_vars(block)
          # local_vars = MapSet.union(all_arg_vars, body_assigned_vars)

          # Process each clause, capturing pinned vars and warning about unpinned
          {new_block, new_bindings} =
            Macro.prewalk(block, bindings_acc, fn
              {:^, pin_meta, [{var, _, ctx} = expr]} = _pinned_ast, acc ->
                # Pinned variable - capture it
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

  # Traverse keyword options looking for pinned variables (^var syntax)
  defp traverse_options(opts, _env) when is_list(opts) do
    {rewritten_opts, bindings_acc} =
      Enum.reduce(opts, {[], []}, fn
        {key, {:^, pin_meta, [{var, _, ctx} = expr]}}, {opts_acc, bindings_acc} ->
          new_var = Macro.var(var, ctx)
          binding_assignment = {:=, pin_meta, [new_var, expr]}
          new_opt = {key, new_var}
          {[new_opt | opts_acc], [binding_assignment | bindings_acc]}

        {key, value}, {opts_acc, bindings_acc} ->
          {[{key, value} | opts_acc], bindings_acc}
      end)

    {Enum.reverse(rewritten_opts), bindings_acc}
  end

  defp traverse_options(opts, _env), do: {opts, []}

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
    {rewritten_opts, opts_bindings} = traverse_options(opts, __CALLER__)

    init = rewritten_opts[:init] || raise ArgumentError, "An `init` function or state is required"

    reducer =
      Keyword.get(rewritten_opts, :reducer) ||
        raise ArgumentError, "A reducer function is required"

    reactors = rewritten_opts[:reactors]

    name = rewritten_opts[:name]

    # Validate input/output schemas for known subcomponents
    inputs = validate_component_schema(rewritten_opts[:inputs], "state_machine", [:reactors])
    outputs = validate_component_schema(rewritten_opts[:outputs], "state_machine", [:accumulator])

    {rewritten_reducer, reducer_bindings} = traverse_expression(reducer, __CALLER__)

    variable_bindings =
      (reducer_bindings ++ opts_bindings)
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    state_machine_hash = Components.fact_hash({init, rewritten_reducer, reactors})
    state_machine_name = name || default_component_name("state_machine", state_machine_hash)

    workflow = workflow_of_state_machine(init, rewritten_reducer, reactors, state_machine_name)

    source =
      quote do
        Runic.state_machine(unquote(opts))
      end

    quote do
      unquote_splicing(Enum.reverse(variable_bindings))

      %StateMachine{
        name: unquote(state_machine_name),
        init: unquote(init),
        reducer: unquote(rewritten_reducer),
        reactors: unquote(reactors),
        workflow: unquote(workflow) |> Map.put(:name, unquote(state_machine_name)),
        source: unquote(Macro.escape(source)),
        hash: unquote(state_machine_hash),
        bindings: unquote(bindings),
        inputs: unquote(inputs),
        outputs: unquote(outputs)
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
    {rewritten_opts, opts_bindings} =
      if is_list(opts), do: traverse_options(opts, __CALLER__), else: {opts, []}

    name = rewritten_opts[:name]

    {rewritten_expression, expression_bindings} =
      case expression do
        {:fn, _, _} -> traverse_expression(expression, __CALLER__)
        _ -> {expression, []}
      end

    variable_bindings =
      (expression_bindings ++ opts_bindings)
      |> Enum.uniq()

    source =
      quote do
        Runic.map(unquote(expression), unquote(opts))
      end

    closure_source =
      quote do
        Runic.map(unquote(rewritten_expression), unquote(rewritten_opts))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    if Enum.empty?(variable_bindings) do
      map_hash = Components.fact_hash(source)
      map_name = name || default_component_name("map", map_hash)

      map_pipeline =
        pipeline_workflow_of_map_expression(
          rewritten_expression,
          map_name
        )

      quote do
        %Runic.Workflow.Map{
          name: unquote(map_name),
          pipeline: unquote(map_pipeline),
          hash: unquote(map_hash),
          closure: unquote(closure),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    else
      base_name = name

      quote do
        closure = unquote(closure)
        map_hash = closure.hash

        map_name =
          if unquote(base_name),
            do: unquote(base_name),
            else: unquote(default_component_name("map", "_")) <> "_#{map_hash}"

        map_pipeline =
          unquote(
            pipeline_workflow_of_map_expression(
              rewritten_expression,
              quote(do: map_name)
            )
          )

        %Runic.Workflow.Map{
          name: map_name,
          pipeline: map_pipeline,
          hash: map_hash,
          closure: closure,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
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
    {rewritten_opts, opts_bindings} =
      if is_list(opts), do: traverse_options(opts, __CALLER__), else: {opts, []}

    map_to_reduce = rewritten_opts[:map]
    name = rewritten_opts[:name]

    {rewritten_reducer_fun, reducer_bindings} = traverse_expression(reducer_fun, __CALLER__)

    variable_bindings =
      (reducer_bindings ++ opts_bindings)
      |> Enum.uniq()

    source =
      quote do
        Runic.reduce(unquote(acc), unquote(reducer_fun), unquote(opts))
      end

    closure_source =
      quote do
        Runic.reduce(unquote(acc), unquote(rewritten_reducer_fun), unquote(rewritten_opts))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    if Enum.empty?(variable_bindings) do
      fan_in_hash = Components.fact_hash({acc, rewritten_reducer_fun})
      reduce_hash = Components.fact_hash(source)
      reduce_name = name || default_component_name("reduce", reduce_hash)

      quote do
        %Runic.Workflow.Reduce{
          name: unquote(reduce_name),
          hash: unquote(reduce_hash),
          fan_in: %FanIn{
            map: unquote(map_to_reduce),
            init: fn -> unquote(acc) end,
            reducer: unquote(rewritten_reducer_fun),
            hash: unquote(fan_in_hash)
          },
          closure: unquote(closure),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    else
      base_name = name
      normalized_reducer = normalize_ast(rewritten_reducer_fun)

      quote do
        closure = unquote(closure)

        fan_in_hash =
          Components.fact_hash(
            {unquote(acc), unquote(Macro.escape(normalized_reducer)), closure.bindings}
          )

        reduce_hash = closure.hash

        reduce_name =
          if unquote(base_name),
            do: unquote(base_name),
            else: unquote(default_component_name("reduce", "_")) <> "_#{reduce_hash}"

        %Runic.Workflow.Reduce{
          name: reduce_name,
          hash: reduce_hash,
          fan_in: %FanIn{
            map: unquote(map_to_reduce),
            init: fn -> unquote(acc) end,
            reducer: unquote(rewritten_reducer_fun),
            hash: fan_in_hash
          },
          closure: closure,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    end
  end

  # Schema validation helpers
  @doc """
  accumulator/2 creates an accumulator that reduces parent facts starting with the init value.

  An accumulator differs from reduce in that it only runs once per fact during invoke
  and does not expect an enumerable or a fan-in/fan-out/map-reduce scenario.

  ## Examples

  ```elixir
  require Runic
  import Runic

  # Simple accumulator
  acc = Runic.accumulator(0, fn x, acc -> x + acc end)

  # Named accumulator
  acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: "adder")
  ```
  """
  defmacro accumulator(init, reducer_fun, opts \\ []) do
    {rewritten_opts, opts_bindings} =
      if is_list(opts), do: traverse_options(opts, __CALLER__), else: {opts, []}

    name = rewritten_opts[:name]

    {rewritten_reducer_fun, reducer_bindings} = traverse_expression(reducer_fun, __CALLER__)

    variable_bindings =
      (reducer_bindings ++ opts_bindings)
      |> Enum.uniq()

    source =
      quote do
        Runic.accumulator(unquote(init), unquote(reducer_fun), unquote(opts))
      end

    closure_source =
      quote do
        Runic.accumulator(unquote(init), unquote(rewritten_reducer_fun), unquote(rewritten_opts))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    if Enum.empty?(variable_bindings) do
      accumulator_hash = Components.fact_hash(source)
      reduce_hash = Components.fact_hash({init, rewritten_reducer_fun})
      accumulator_name = name || default_component_name("accumulator", accumulator_hash)

      quote do
        %Accumulator{
          name: unquote(accumulator_name),
          init: fn -> unquote(init) end,
          reducer: unquote(rewritten_reducer_fun),
          hash: unquote(accumulator_hash),
          reduce_hash: unquote(reduce_hash),
          closure: unquote(closure),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    else
      base_name = name
      normalized_reducer = normalize_ast(rewritten_reducer_fun)

      quote do
        closure = unquote(closure)
        accumulator_hash = closure.hash

        reduce_hash =
          Components.fact_hash(
            {unquote(init), unquote(Macro.escape(normalized_reducer)), closure.bindings}
          )

        accumulator_name =
          if unquote(base_name),
            do: unquote(base_name),
            else: unquote(default_component_name("accumulator", "_")) <> "_#{accumulator_hash}"

        %Accumulator{
          name: accumulator_name,
          init: fn -> unquote(init) end,
          reducer: unquote(rewritten_reducer_fun),
          hash: accumulator_hash,
          reduce_hash: reduce_hash,
          closure: closure,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    end
  end

  # meta-api

  @doc """
  Used inside Runic macros such as rules to reference the state of another component such as an accumulator
  or reduce.

  Expands into a `%StateCondition{}` in conjunction with any other conditions of the rule's expression to evaluate against the last known state of the component.
  """
  def state_of(component_name_or_hash), do: doc!([component_name_or_hash])

  @doc """
  Evaluates to true in a condition if the specified step has ever been ran.

  Note that this evaluates to true globally for any prior execution of the workflow, not just within the current invocation.
  """
  def step_ran?(component_name_or_hash), do: doc!([component_name_or_hash])

  @doc """
  Evaluates to true if the specified step has been executed for the given input fact.

  Considers only input facts for a generation of invokations fed into the root of the workflow.
  """
  def step_ran?(component_name_or_hash, fact_or_hash),
    do: doc!([component_name_or_hash, fact_or_hash])

  defp doc!(_) do
    raise "these Runic meta APIs should not be invoked directly, " <>
            "they serve for documentation purposes only"
  end

  # Schema validation helpers
  defp validate_component_schema(schema, component_type, known_subcomponents) do
    if schema do
      schema_keys = Keyword.keys(schema)
      invalid_keys = schema_keys -- known_subcomponents

      unless Enum.empty?(invalid_keys) do
        raise ArgumentError,
              "Invalid subcomponent keys #{inspect(invalid_keys)} for #{component_type}. " <>
                "Valid keys are: #{inspect(known_subcomponents)}"
      end
    end

    schema
  end

  # Normalize AST by removing metadata (line numbers, context, etc) for content addressing
  defp normalize_ast(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} when is_list(args) ->
        # Remove all metadata, keep just the form and args
        {form, [], args}

      {form, _meta, ctx} when is_atom(ctx) or is_nil(ctx) ->
        # Variable node - remove metadata but keep context
        {form, [], ctx}

      other ->
        other
    end)
  end

  # Build a Closure struct from rewritten source AST and variable bindings
  # NOTE: `rewritten_source` should be the result of traverse_expression, not the original source
  defp build_closure(rewritten_source, variable_bindings, caller_context) do
    # Normalize the source AST for content addressability (remove line numbers, etc)
    normalized_source = normalize_ast(rewritten_source)

    if not Enum.empty?(variable_bindings) do
      quote do
        unquote_splicing(Enum.reverse(variable_bindings))

        bindings_map = %{
          unquote_splicing(
            Enum.map(variable_bindings, fn {:=, _, [{left_var, _, _}, right]} ->
              {left_var, right}
            end)
          )
        }

        metadata = ClosureMetadata.from_caller(unquote(Macro.escape(caller_context)))
        # Use the normalized source for content addressability
        Closure.new(unquote(Macro.escape(normalized_source)), bindings_map, metadata)
      end
    else
      quote do
        Closure.new(unquote(Macro.escape(normalized_source)), %{}, nil)
      end
    end
  end

  # Deprecated: kept for backward compatibility with old serialized workflows
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

  # direct to ast pipeline workflow
  defp pipeline_workflow_of_map_expression(expression, name) do
    pipeline_workflow_of_map_expression(
      quote generated: true do
        require Runic
        alias Runic.Workflow

        Runic.workflow(name: unquote(name))
      end,
      expression,
      name
    )
  end

  defp pipeline_workflow_of_map_expression(wrk_expression, {:fn, _, _} = expression, name) do
    fan_out_hash = Components.fact_hash({:fan_out, expression})

    fan_out =
      quote do
        %FanOut{
          hash: unquote(fan_out_hash),
          name: unquote(name)
        }
      end

    step = CompilationUtils.pipeline_step(expression)

    quote do
      unquote(wrk_expression)
      |> Workflow.add_step(unquote(fan_out))
      |> Workflow.add_step(unquote(fan_out), unquote(step))

      # |> Workflow.add(unquote(step), to: unquote(fan_out_hash))
    end
  end

  defp pipeline_workflow_of_map_expression(wrk_expression, {:step, _, _} = expression, name) do
    fan_out_hash = Components.fact_hash({:fan_out, expression})

    fan_out =
      quote do
        %FanOut{
          hash: unquote(fan_out_hash),
          name: unquote(name)
        }
      end

    step = CompilationUtils.pipeline_step(expression)

    quote do
      unquote(wrk_expression)
      |> Workflow.add_step(unquote(fan_out))
      |> Workflow.add(unquote(step), to: unquote(fan_out_hash))
    end
  end

  defp pipeline_workflow_of_map_expression(
         wrk_expression,
         {[_ | _] = parent_steps, [_ | _] = dependent_steps} = pipeline_expression,
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

    parent_steps_with_hashes =
      Enum.map(parent_steps, fn step_ast ->
        {Components.fact_hash(step_ast), CompilationUtils.pipeline_step(step_ast)}
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

    wrk_expression =
      quote generated: true do
        unquote(wrk_expression)
        |> Workflow.add_step(unquote(fan_out))
        |> then(fn wrk_expression ->
          Enum.reduce(unquote(parent_steps_with_hashes), wrk_expression, fn {_, join_step}, acc ->
            Workflow.add_step(acc, unquote(fan_out), join_step)
          end)
        end)
        |> then(fn wrk_expression ->
          Enum.reduce(unquote(parent_steps_with_hashes), wrk_expression, fn {_, join_step}, acc ->
            Workflow.add_step(acc, join_step, unquote(join))
          end)
        end)
      end

    Enum.reduce(dependent_steps, wrk_expression, fn dstep, wrk_acc ->
      dependent_pipeline_workflow =
        CompilationUtils.workflow_graph_of_pipeline_tree_expression(
          dstep,
          name
        )

      quote generated: true do
        unquote(wrk_acc)
        |> Workflow.add(unquote(dependent_pipeline_workflow), to: unquote(join_hash))
      end
    end)
  end

  defp pipeline_workflow_of_map_expression(
         wrk_expression,
         {step_expression, [_ | _] = dependent_steps} = pipeline_expression,
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

    step = CompilationUtils.pipeline_step(step_expression)

    wrk_expression =
      quote generated: true do
        unquote(wrk_expression)
        |> Workflow.add_step(unquote(fan_out))
        |> Workflow.add(unquote(step), to: unquote(fan_out_hash))
      end

    dependent_pipeline_workflow =
      CompilationUtils.workflow_graph_of_pipeline_tree_expression(dependent_steps, name)

    quote generated: true do
      unquote(wrk_expression)
      |> Workflow.add(unquote(dependent_pipeline_workflow), to: unquote(step))
    end
  end

  defp pipeline_workflow_of_map_expression(
         wrk_expression,
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

    wrk_expression =
      quote generated: true do
        unquote(wrk_expression)
        |> Workflow.add_step(unquote(fan_out))
      end

    Enum.reduce(pipeline_expression, wrk_expression, fn dstep, wrk_acc ->
      dependent_pipeline_workflow =
        CompilationUtils.workflow_graph_of_pipeline_tree_expression(dstep, name)

      quote generated: true do
        unquote(wrk_acc)
        |> Workflow.add(unquote(dependent_pipeline_workflow), to: unquote(fan_out_hash))
      end
    end)
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

  # =============================================================================
  # Given/When/Then DSL Compilation
  # =============================================================================

  defp compile_given_when_then_rule(block, opts, env) do
    # Parse the block to extract given, when, then clauses
    {given_clause, where_clause, then_clause} = parse_given_when_then_block(block)

    # Extract bindings and pattern from given clause
    {pattern_ast, top_binding, binding_vars} = compile_given_clause(given_clause)

    # Compile where clause into a condition function
    # The condition receives the input and returns true/false
    condition_fn = compile_when_clause(where_clause, pattern_ast, top_binding, binding_vars, env)

    # Compile then clause - it receives the input and builds bindings internally
    reaction_fn = compile_then_clause(then_clause, pattern_ast, top_binding, binding_vars, env)

    # Get options
    {rewritten_opts, opts_bindings} = traverse_options(opts, env)
    name = rewritten_opts[:name]

    # Determine arity (always 1 for DSL rules - single input matched against pattern)
    arity = 1

    # Build the rule workflow
    {workflow, condition_hash, reaction_hash} =
      workflow_of_rule({condition_fn, reaction_fn}, arity)

    source =
      quote do
        Runic.rule(unquote(opts), do: unquote(block))
      end

    closure_source =
      quote do
        Runic.rule(unquote(rewritten_opts), do: unquote(block))
      end

    # Collect bindings from then clause
    {_rewritten_then, then_bindings} = traverse_expression(then_clause, env)
    variable_bindings = Enum.uniq(then_bindings ++ opts_bindings)

    closure = build_closure(closure_source, variable_bindings, env)

    if Enum.empty?(variable_bindings) do
      rule_hash = Components.fact_hash(source)
      rule_name = name || default_component_name("rule", rule_hash)

      quote do
        %Rule{
          name: unquote(rule_name),
          arity: unquote(arity),
          workflow: unquote(workflow),
          condition_hash: unquote(condition_hash),
          reaction_hash: unquote(reaction_hash),
          hash: unquote(rule_hash),
          closure: unquote(closure),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    else
      base_name = name

      quote do
        closure = unquote(closure)
        rule_hash = closure.hash

        rule_name =
          if unquote(base_name),
            do: unquote(base_name),
            else: unquote(default_component_name("rule", "_")) <> "_#{rule_hash}"

        %Rule{
          name: rule_name,
          arity: unquote(arity),
          workflow: unquote(workflow),
          condition_hash: unquote(condition_hash),
          reaction_hash: unquote(reaction_hash),
          hash: rule_hash,
          closure: closure,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs])
        }
      end
    end
  end

  defp parse_given_when_then_block({:__block__, _, statements}) do
    parse_statements(statements)
  end

  defp parse_given_when_then_block(single_statement) do
    parse_statements([single_statement])
  end

  defp parse_statements(statements) do
    given_clause =
      Enum.find_value(statements, fn
        {:given, _, [bindings]} -> bindings
        _ -> nil
      end)

    # Support both `where` (preferred) and `when` (if it parses correctly)
    where_clause =
      Enum.find_value(statements, fn
        {:where, _, [expr]} -> expr
        {:when, _, [expr]} -> expr
        _ -> nil
      end)

    then_clause =
      Enum.find_value(statements, fn
        {:then, _, [expr]} -> expr
        _ -> nil
      end)

    # Validate required clauses
    unless then_clause do
      raise ArgumentError,
            "rule DSL requires a `then` clause with an action function"
    end

    # Default given to match anything if not specified - use special marker
    given_clause = given_clause || :match_any

    # Default where to true if not specified
    where_clause = where_clause || true

    {given_clause, where_clause, then_clause}
  end

  defp compile_given_clause(:match_any) do
    # Match anything - bind to `input` for the then clause
    {Macro.var(:input, nil), :input, [{:input, Macro.var(:input, nil)}]}
  end

  defp compile_given_clause(bindings) when is_list(bindings) do
    # bindings is a keyword list like [order: %{status: status, total: total}]
    # We need to:
    # 1. Build a pattern that matches the input
    # 2. Extract all variable names for the bindings map

    case bindings do
      [{binding_name, pattern}] ->
        # Single binding - match input against pattern
        # Check if pattern is just a plain variable (like `given value: value`)
        # In that case, the value IS the binding, don't also add binding_name
        case pattern do
          {var_name, _, ctx} when is_atom(var_name) and is_atom(ctx) ->
            # Pattern is just a variable - check if it's same as binding_name
            if var_name == binding_name do
              # Just use _ as pattern and bind to binding_name
              {Macro.var(binding_name, nil), binding_name,
               [{binding_name, Macro.var(binding_name, nil)}]}
            else
              # Different names - use the pattern variable
              binding_vars = extract_pattern_variables(pattern)
              all_vars = [{binding_name, Macro.var(binding_name, nil)} | binding_vars]
              {pattern, binding_name, all_vars}
            end

          {:_, _, _} ->
            # Pattern is underscore - just bind to binding_name
            {{:_, [], nil}, binding_name, [{binding_name, Macro.var(binding_name, nil)}]}

          _ ->
            # Complex pattern - extract all variables from it
            binding_vars = extract_pattern_variables(pattern)
            # Add the top-level binding
            all_vars = [{binding_name, Macro.var(binding_name, nil)} | binding_vars]
            {pattern, binding_name, all_vars}
        end

      multiple_bindings ->
        # Multiple bindings - treat as map pattern where input must be a map
        # containing all the specified keys
        # We need to bind each key's matched value to a variable
        # e.g., given order: %{status: :pending}, user: %{tier: tier}
        # becomes: %{order: %{status: :pending} = order, user: %{tier: tier} = user}

        all_vars =
          Enum.flat_map(multiple_bindings, fn {name, pattern} ->
            pattern_vars = extract_pattern_variables(pattern)
            [{name, Macro.var(name, nil)} | pattern_vars]
          end)

        # Build a map pattern that binds each key's value to a variable
        # Each entry becomes: key: pattern = var
        map_entries =
          Enum.map(multiple_bindings, fn {name, pattern} ->
            # Bind the pattern to a variable with the same name as the key
            {name, {:=, [], [pattern, Macro.var(name, nil)]}}
          end)

        map_pattern = {:%{}, [], map_entries}
        {map_pattern, nil, all_vars}
    end
  end

  defp extract_pattern_variables(pattern) do
    # Walk the pattern AST and collect all variable bindings
    {_ast, vars} =
      Macro.prewalk(pattern, [], fn
        # Skip underscores and underscore-prefixed vars
        {:_, _, _} = node, acc ->
          {node, acc}

        # Collect variables
        {name, meta, context} = node, acc when is_atom(name) and is_atom(context) ->
          name_str = Atom.to_string(name)

          # Skip special forms, underscore-prefixed, and module names
          if String.starts_with?(name_str, "_") or
               name in [:__MODULE__, :__ENV__, :__DIR__, :__CALLER__] or
               String.match?(name_str, ~r/^[A-Z]/) do
            {node, acc}
          else
            {node, [{name, {name, meta, context}} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq_by(vars, fn {name, _} -> name end)
  end

  defp compile_when_clause(when_expr, pattern, top_binding, _binding_vars, _env) do
    # Build a condition function that:
    # 1. Matches the input against the pattern
    # 2. If matched, evaluates the when expression with bindings
    # 3. Returns boolean

    # The when expression, with variables bound
    when_body =
      if when_expr == true do
        true
      else
        when_expr
      end

    # Build the case pattern - if we have a top_binding, use = to bind the whole value
    # But avoid self-match like `value = value` when pattern IS the top_binding var
    case_pattern =
      cond do
        is_nil(top_binding) ->
          pattern

        # Check if pattern is the same variable as top_binding
        match?({^top_binding, _, ctx} when is_atom(ctx), pattern) ->
          # Pattern is already the binding variable, no need to wrap with =
          pattern

        true ->
          # Bind the whole matched value to the binding name
          {:=, [], [Macro.var(top_binding, nil), pattern]}
      end

    # Build the condition function
    quote do
      fn input ->
        case input do
          unquote(case_pattern) ->
            # Evaluate where clause (variables are bound by the pattern match)
            unquote(when_body)

          _ ->
            false
        end
      end
    end
  end

  defp compile_then_clause(then_expr, pattern, top_binding, binding_vars, env) do
    # The then clause should be a function that receives the input,
    # pattern matches it to extract bindings, then calls the user's function
    # with the bindings map

    # Build the case pattern - same as condition
    # Avoid self-match like `value = value`
    case_pattern =
      cond do
        is_nil(top_binding) ->
          pattern

        match?({^top_binding, _, ctx} when is_atom(ctx), pattern) ->
          pattern

        true ->
          {:=, [], [Macro.var(top_binding, nil), pattern]}
      end

    # Build bindings map from the extracted variables
    bindings_map_entries =
      Enum.map(binding_vars, fn {name, _ast} ->
        {name, Macro.var(name, nil)}
      end)

    bindings_map = {:%{}, [], bindings_map_entries}

    case then_expr do
      {:fn, _, _} ->
        # User provided a function - traverse for ^ bindings then wrap
        {rewritten_fn, _bindings} = traverse_expression(then_expr, env)

        quote do
          fn input ->
            case input do
              unquote(case_pattern) ->
                bindings = unquote(bindings_map)
                unquote(rewritten_fn).(bindings)
            end
          end
        end

      {:&, _, _} ->
        # Capture syntax - wrap to pass bindings
        quote do
          fn input ->
            case input do
              unquote(case_pattern) ->
                bindings = unquote(bindings_map)
                unquote(then_expr).(bindings)
            end
          end
        end

      _ ->
        # Raw expression - wrap in a function
        quote do
          fn input ->
            case input do
              unquote(case_pattern) ->
                _bindings = unquote(bindings_map)
                unquote(then_expr)
            end
          end
        end
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

    workflow =
      quote do
        import Runic

        Workflow.new()
        |> Workflow.add_step(unquote(condition))
        |> Workflow.add_step(unquote(condition), unquote(reaction))
      end

    {workflow, condition_ast_hash, reaction_ast_hash}
  end

  defp workflow_of_rule({:fn, _, [{:->, _, [[], _rhs]}]} = expression, 0 = _arity) do
    reaction_ast_hash = Components.fact_hash(expression)

    reaction = quote(do: Step.new(work: unquote(expression), hash: unquote(reaction_ast_hash)))

    workflow =
      quote do
        import Runic

        Workflow.new()
        |> Workflow.add_step(unquote(reaction))
      end

    # For zero-arity rules, there is no condition, so condition_hash should be nil
    {workflow, nil, reaction_ast_hash}
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

    condition_ast_hash = Components.fact_hash(condition_fun)

    condition =
      quote do
        Condition.new(
          work: unquote(condition_fun),
          hash: unquote(condition_ast_hash),
          arity: unquote(arity)
        )
      end

    quoted_workflow =
      quote do
        import Runic

        Workflow.new()
        |> Workflow.add_step(unquote(condition))
        |> Workflow.add_step(unquote(condition), unquote(reaction))
      end

    {quoted_workflow, condition_ast_hash, reaction_ast_hash}
  end

  # matches: fn true -> _ end | fn nil -> _ end
  defp workflow_of_rule({:fn, _, [{:->, _, [[lhs], rhs]}]} = _expression, 1 = _arity)
       when lhs in [true, nil] do
    condition_fun = fn _lhs -> true end
    condition_ast_hash = Components.fact_hash(condition_fun)

    condition = quote(do: Condition.new(unquote(condition_fun)))

    reaction_fun = quote(do: fn _ -> unquote(rhs) end)
    reaction_ast_hash = Components.fact_hash(reaction_fun)

    reaction = quote(do: step(unquote(reaction_fun)))

    workflow =
      quote do
        import Runic

        Workflow.new()
        |> Workflow.add_step(unquote(condition))
        |> Workflow.add_step(unquote(condition), unquote(reaction))
      end

    {workflow, condition_ast_hash, reaction_ast_hash}
  end

  defp workflow_of_rule(
         {:fn, head_meta, [{:->, clause_meta, [[lhs], _rhs]}]} = expression,
         1 = arity
       ) do
    condition_fun =
      {:fn, head_meta,
       [
         {:->, clause_meta, [[lhs], true]},
         {:->, clause_meta, [[{:_otherwise, [if_undefined: :apply], Elixir}], false]}
       ]}

    condition_ast_hash = Components.fact_hash(condition_fun)

    condition =
      quote do
        Condition.new(
          work: unquote(condition_fun),
          hash: unquote(condition_ast_hash),
          arity: unquote(arity)
        )
      end

    reaction_ast_hash = Components.fact_hash(expression)
    reaction = quote(do: Step.new(work: unquote(expression), hash: unquote(reaction_ast_hash)))

    workflow =
      quote do
        import Runic

        Workflow.new()
        |> Workflow.add_step(unquote(condition))
        |> Workflow.add_step(unquote(condition), unquote(reaction))
      end

    {workflow, condition_ast_hash, reaction_ast_hash}
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

  # Collect variables assigned in the body (left side of = expressions)
  # defp collect_assigned_vars(ast) do
  #   {_, vars} =
  #     Macro.prewalk(ast, MapSet.new(), fn
  #       # Don't traverse into nested functions
  #       {:fn, _, _} = nested_fn, acc ->
  #         {nested_fn, acc}

  #       # Collect variables from left side of assignments
  #       {:=, _, [left, _right]} = assign_node, acc ->
  #         new_vars = collect_pattern_vars(left)
  #         {assign_node, MapSet.union(acc, MapSet.new(new_vars))}

  #       node, acc ->
  #         {node, acc}
  #     end)

  #   vars
  # end

  # Collect variable names from a pattern (handles nested patterns and guards)
  # defp collect_pattern_vars({var, _, ctx}) when is_atom(var) and (is_atom(ctx) or is_nil(ctx)),
  #   do: [var]

  # # Handle guards: {:when, _, [arg1, arg2, ..., guard_expr]}
  # defp collect_pattern_vars({:when, _, elements})
  #      when is_list(elements) and length(elements) > 1 do
  #   {patterns, [_guard | _]} = Enum.split(elements, -1)
  #   Enum.flat_map(patterns, &collect_pattern_vars/1)
  # end

  # # Handle pattern matches
  # defp collect_pattern_vars({:=, _, [left, right]}),
  #   do: collect_pattern_vars(left) ++ collect_pattern_vars(right)

  # defp collect_pattern_vars({:{}, _, elements}),
  #   do: Enum.flat_map(elements, &collect_pattern_vars/1)

  # defp collect_pattern_vars({left, right}),
  #   do: collect_pattern_vars(left) ++ collect_pattern_vars(right)

  # defp collect_pattern_vars({:%, _, [_alias, {:%{}, _, fields}]}),
  #   do: Enum.flat_map(fields, fn {_, v} -> collect_pattern_vars(v) end)

  # defp collect_pattern_vars({:%{}, _, fields}),
  #   do: Enum.flat_map(fields, fn {_, v} -> collect_pattern_vars(v) end)

  # defp collect_pattern_vars([_ | _] = list), do: Enum.flat_map(list, &collect_pattern_vars/1)
  # defp collect_pattern_vars(_), do: []

  # Check if a name is a special form or built-in
  # defp is_special_form(name) do
  #   name in [
  #     :__MODULE__,
  #     :__DIR__,
  #     :__ENV__,
  #     :__CALLER__,
  #     :__STACKTRACE__,
  #     :_,
  #     :...
  #   ] or String.starts_with?(to_string(name), "_")
  # end
end
