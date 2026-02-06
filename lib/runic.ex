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
  Creates a `%Step{}`: a basic lambda expression that can be added to a workflow.

  Steps are the fundamental building blocks of Runic workflows, representing
  input → output transformations. Each step wraps a function and can be composed
  with other steps to form data processing pipelines.

  ## Basic Usage

      iex> require Runic
      iex> step = Runic.step(fn x -> x * 2 end)
      iex> step.work.(5)
      10

  ## Arities

  Steps support 0, 1, or 2-arity functions:

      iex> require Runic
      iex> zero_arity = Runic.step(fn -> 42 end)
      iex> zero_arity.work.()
      42

      iex> require Runic
      iex> one_arity = Runic.step(fn x -> x + 1 end)
      iex> one_arity.work.(10)
      11

      iex> require Runic
      iex> two_arity = Runic.step(fn a, b -> a + b end)
      iex> two_arity.work.(3, 4)
      7

  Note: 2-arity steps only execute when the workflow receives a 2-element list as input.

  ## Captured Variables with `^`

  Use the pin operator `^` to capture outer scope variables. This is essential for:
  - Content-addressable hashing (each bound value produces unique hashes)
  - Serialization with `build_log/1` and recovery with `from_log/1`
  - Dynamic workflow construction at runtime

      iex> require Runic
      iex> multiplier = 3
      iex> step = Runic.step(fn x -> x * ^multiplier end)
      iex> step.closure.bindings[:multiplier]
      3
      iex> step.work.(10)
      30

  Without `^`, Elixir's normal closure mechanism captures the variable, but Runic
  cannot track, hash, or serialize it - the workflow will fail after persistence.

  ## Captured Functions

  Steps can wrap module functions using capture syntax:

      iex> require Runic
      iex> step = Runic.step(&String.upcase/1)
      iex> step.work.("hello")
      "HELLO"

  ## Options

  - `:name` - An atom or string identifier for referencing this step in workflows
  - `:work` - The function to execute (alternative to passing as first argument)
  - `:inputs` - Reserved for future schema-based type compatibility
  - `:outputs` - Reserved for future schema-based type compatibility

      iex> require Runic
      iex> step = Runic.step(fn x -> x * 2 end, name: :doubler)
      iex> step.name
      :doubler

      iex> require Runic
      iex> step = Runic.step(name: :tripler, work: fn x -> x * 3 end)
      iex> step.name
      :tripler

  ## In Workflows

  Steps can be connected in pipelines using the workflow DSL:

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(
      ...>   name: "pipeline",
      ...>   steps: [
      ...>     {Runic.step(fn x -> x + 1 end, name: :add_one),
      ...>      [Runic.step(fn x -> x * 2 end, name: :double)]}
      ...>   ]
      ...> )
      iex> results = workflow |> Workflow.react_until_satisfied(5) |> Workflow.raw_productions()
      iex> Enum.sort(results)
      [6, 12]

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
  Creates a `%Condition{}`: a standalone conditional expression.

  Conditions represent the left-hand side (predicate) of a rule. They can be
  reused across multiple rules when the same condition is expensive or shared.

  ## Basic Usage

      iex> require Runic
      iex> cond = Runic.condition(fn x -> x > 10 end)
      iex> cond.work.(15)
      true
      iex> cond.work.(5)
      false

  ## With Module Function Capture

      iex> require Runic
      iex> cond = Runic.condition({Kernel, :is_integer, 1})
      iex> cond.work.(42)
      true

  ## Use Cases

  - **Expensive checks**: When a condition involves costly operations (e.g., API calls,
    database queries), define it once and reference it in multiple rules
  - **Stateful conditions**: Use `state_of/1` to create conditions that depend on
    accumulator or state machine state
  - **Reusability**: Share predicates across rules for consistency

  Note: Conditions should be pure and deterministic - they should not execute side effects.
  """
  def condition(fun) when is_function(fun) do
    Condition.new(fun)
  end

  def condition({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    Condition.new(Function.capture(m, f, a))
  end

  @doc """
  Converts a Runic component into a `%Workflow{}` via the `Transmutable` protocol.

  Components like steps, rules, state machines, etc. can be transmuted into
  standalone workflows for evaluation or composition.

  ## Examples

      iex> require Runic
      iex> step = Runic.step(fn x -> x * 2 end)
      iex> workflow = Runic.transmute(step)
      iex> workflow.__struct__
      Runic.Workflow

      iex> require Runic
      iex> rule = Runic.rule(fn x when x > 0 -> :positive end)
      iex> workflow = Runic.transmute(rule)
      iex> workflow.__struct__
      Runic.Workflow

  ## Use Cases

  - Preparing components for standalone evaluation
  - Converting natural representations (e.g., a single rule) into evaluable workflows
  - Composing heterogeneous components by first converting to workflows, then merging
  """
  def transmute(component) do
    component
    |> Runic.Transmutable.transmute()
    |> do_transmute()
  end

  defp do_transmute(%Workflow{} = workflow), do: workflow
  defp do_transmute(component), do: transmute(component)

  @doc """
  Creates a `%Workflow{}` from component options.

  Workflows are directed acyclic graphs (DAGs) of steps, rules, and other components
  connected through dataflow semantics. They enable lazy or eager evaluation and can
  be composed, persisted, and distributed.

  ## Basic Usage

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(
      ...>   name: :simple,
      ...>   steps: [Runic.step(fn x -> x * 2 end)]
      ...> )
      iex> workflow |> Workflow.react_until_satisfied(5) |> Workflow.raw_productions()
      [10]

  ## Options

  - `:name` - Identifier for the workflow (atom or string)
  - `:steps` - List of steps, with optional pipeline syntax for parent-child relationships
  - `:rules` - List of conditional rules to add
  - `:before_hooks` - Debug hooks called before step execution
  - `:after_hooks` - Debug hooks called after step execution

  ## Pipeline Syntax

  Use tuples `{parent, [children]}` to define step dependencies:

      iex> require Runic
      iex> alias Runic.Workflow
      iex> pipeline = Runic.workflow(
      ...>   name: :pipeline,
      ...>   steps: [
      ...>     {Runic.step(fn x -> x + 1 end, name: :add_one),
      ...>      [Runic.step(fn x -> x * 2 end, name: :double),
      ...>       Runic.step(fn x -> x * 3 end, name: :triple)]}
      ...>   ]
      ...> )
      iex> results = pipeline |> Workflow.react_until_satisfied(5) |> Workflow.raw_productions()
      iex> Enum.sort(results)
      [6, 12, 18]

  ## With Rules

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(
      ...>   name: :rule_example,
      ...>   rules: [
      ...>     Runic.rule(fn x when is_integer(x) and x > 10 -> :large end),
      ...>     Runic.rule(fn x when is_integer(x) and x <= 10 -> :small end)
      ...>   ]
      ...> )
      iex> workflow |> Workflow.plan_eagerly(15) |> Workflow.react_until_satisfied() |> Workflow.raw_productions()
      [:large]

  ## Hooks

  Hooks receive `(step, workflow, fact)` and must return the workflow.
  Use them for debugging, logging, or dynamic workflow modification:

      require Runic
      alias Runic.Workflow

      Runic.workflow(
        name: :with_hooks,
        steps: [Runic.step(fn x -> x * 2 end, name: :double)],
        after_hooks: [
          double: [
            fn _step, workflow, fact ->
              IO.puts("Produced: \#{inspect(fact.value)}")
              workflow
            end
          ]
        ]
      )

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
  Creates a `%Rule{}`: a conditional reaction for pattern-matched execution.

  Rules have two phases: a **condition** (left-hand side) that must match,
  and a **reaction** (right-hand side) that executes when matched. This
  separation enables efficient evaluation of many rules together.

  ## Basic Usage

      iex> require Runic
      iex> alias Runic.Workflow.Rule
      iex> rule = Runic.rule(fn x when is_integer(x) and x > 0 -> :positive end)
      iex> Rule.check(rule, 5)
      true
      iex> Rule.check(rule, -1)
      false
      iex> Rule.run(rule, 5)
      :positive

  ## Guard Clauses

  Rules support full Elixir guard expressions:

      iex> require Runic
      iex> alias Runic.Workflow.Rule
      iex> rule = Runic.rule(fn x when is_binary(x) and byte_size(x) > 5 -> :long_string end)
      iex> Rule.check(rule, "hello!")
      true
      iex> Rule.check(rule, "hi")
      false

  ## Pattern Matching

      iex> require Runic
      iex> alias Runic.Workflow.Rule
      iex> rule = Runic.rule(fn %{status: :pending} -> :process end)
      iex> Rule.check(rule, %{status: :pending, id: 1})
      true
      iex> Rule.check(rule, %{status: :done})
      false

  ## Separated Condition and Reaction

  For expensive conditions shared by multiple rules, or clearer organization:

      iex> require Runic
      iex> alias Runic.Workflow.Rule
      iex> rule = Runic.rule(
      ...>   name: :expensive_check,
      ...>   condition: fn x -> rem(x, 2) == 0 end,
      ...>   reaction: fn x -> x * 2 end
      ...> )
      iex> Rule.check(rule, 4)
      true
      iex> Rule.run(rule, 4)
      8

  Also supports `:if` / `:do` aliases:

      Runic.rule(
        name: :my_rule,
        if: fn x -> x > 10 end,
        do: fn x -> :large end
      )

  ## Multi-Arity Rules

  Rules can require multiple inputs (provided as a list):

      iex> require Runic
      iex> alias Runic.Workflow.Rule
      iex> rule = Runic.rule(fn a, b when is_integer(a) and is_integer(b) -> a + b end)
      iex> Rule.check(rule, [3, 4])
      true
      iex> Rule.run(rule, [3, 4])
      7

  ## In Workflows

  Rules are evaluated in the planning/match phase before execution:

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(
      ...>   name: :classifier,
      ...>   rules: [
      ...>     Runic.rule(fn x when x > 100 -> :xlarge end, name: :xlarge),
      ...>     Runic.rule(fn x when x > 10 and x <= 100 -> :large end, name: :large),
      ...>     Runic.rule(fn x when x > 0 and x <= 10 -> :small end, name: :small)
      ...>   ]
      ...> )
      iex> workflow |> Workflow.plan_eagerly(50) |> Workflow.react_until_satisfied() |> Workflow.raw_productions()
      [:large]

  ## Given/Where/Then DSL

  For complex rules with pattern destructuring, use the explicit DSL with
  three clauses:

  - **`given`** — a pattern-matching clause that destructures the input and binds
    variables. The binding name becomes the key in the bindings map passed to `then`.
  - **`where`** — a boolean expression evaluated at runtime. Unlike `when` guards,
    `where` supports **any** Elixir expression including function calls like
    `String.starts_with?/2`, `Enum.member?/2`, etc.
  - **`then`** — a function that receives the bindings map and produces a result.
    The bindings from `given` are available as keys.

  Note: Use `where` instead of `when` because `when` is a reserved Elixir keyword.

  ### Do/End Block Form

      require Runic

      Runic.rule do
        given(order: %{status: status, total: total})
        where(status == :pending and total > 100)
        then(fn %{order: order, total: total} -> {:apply_discount, order, total * 0.9} end)
      end

  ### Named Do/End Block Form

  Pass options before the `do` block to name the rule:

      require Runic

      Runic.rule name: :premium_discount do
        given(order: %{customer: %{tier: tier}, total: total})
        where(tier == :premium and total > 50)
        then(fn %{order: order} -> {:apply_discount, order} end)
      end

  ### Keyword Form

  The same rule can be written as a keyword list:

      require Runic

      Runic.rule(
        name: :threshold_check,
        given: [value: v],
        where: v > 100,
        then: fn %{value: v} -> {:over_threshold, v} end
      )

  Direct map patterns are also supported in the keyword form:

      Runic.rule(
        name: :map_pattern,
        given: %{x: x, y: y},
        where: x + y > 10,
        then: fn %{x: x, y: y} -> {:sum, x + y} end
      )

  ### Non-Guard Expressions in `where`

  Unlike `when` guards, `where` supports any boolean expression:

      require Runic

      Runic.rule do
        given(name: name)
        where(String.starts_with?(name, "prefix_"))
        then(fn %{name: n} -> {:matched, n} end)
      end

  ### Capturing External Variables with `^`

  Use the pin operator `^` to capture variables from the surrounding scope.
  This is essential when dynamically constructing rules in loops or functions:

      require Runic
      alias Runic.Workflow

      threshold = 100

      rule =
        Runic.rule do
          given(value: v)
          where(v > ^threshold)
          then(fn %{value: v} -> {:over_threshold, v} end)
        end

      Workflow.new()
      |> Workflow.add(rule)
      |> Workflow.react_until_satisfied(150)
      |> Workflow.raw_productions()
      # => [{:over_threshold, 150}]

  The `^` pin also works in the keyword form and in `condition`/`reaction` style:

      some_values = [:potato, :ham, :tomato]

      Runic.rule(
        name: "escaped rule",
        condition: fn val when is_atom(val) -> true end,
        reaction: fn val ->
          Enum.map(^some_values, fn x -> {val, x} end)
        end
      )
  """
  # Handle rule with do block containing given/when/then DSL
  defmacro rule(opts_or_block)

  defmacro rule([{:do, block}]) do
    compile_given_when_then_rule(block, [], __CALLER__)
  end

  defmacro rule(opts) when is_list(opts) do
    # Phase 3: Detect given/where/then keys and transform to DSL form
    has_given_where_then = Keyword.has_key?(opts, :given) or Keyword.has_key?(opts, :then)

    has_condition_reaction =
      Keyword.has_key?(opts, :condition) or Keyword.has_key?(opts, :if) or
        Keyword.has_key?(opts, :reaction) or Keyword.has_key?(opts, :do)

    # Error if mixing styles
    if has_given_where_then and has_condition_reaction do
      raise ArgumentError, """
      Cannot mix given/where/then style with condition/reaction style in rule macro.

      Use either:
        Runic.rule(given: pattern, where: condition, then: action)
      Or:
        Runic.rule(condition: fn -> ... end, reaction: fn -> ... end)
      """
    end

    if has_given_where_then do
      # Transform keyword opts to synthetic DSL block AST
      compile_keyword_given_when_then_rule(opts, __CALLER__)
    else
      compile_condition_reaction_rule(opts, __CALLER__)
    end
  end

  # Catch-all for anonymous function expressions: rule(fn x -> ... end)
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

  # Original condition/reaction keyword form
  defp compile_condition_reaction_rule(opts, env) do
    {rewritten_opts, opts_bindings} = traverse_options(opts, env)

    name = rewritten_opts[:name]
    condition = rewritten_opts[:condition] || rewritten_opts[:if]
    reaction = rewritten_opts[:reaction] || rewritten_opts[:do]

    arity = Components.arity_of(reaction)

    {rewritten_reaction, reaction_bindings} = traverse_expression(reaction, env)

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

  # Phase 3: Compile keyword form with given/where/then keys
  defp compile_keyword_given_when_then_rule(opts, env) do
    # Extract given/where/then from opts
    given_expr = Keyword.get(opts, :given)
    where_expr = Keyword.get(opts, :where, true)
    then_expr = Keyword.get(opts, :then)

    unless then_expr do
      raise ArgumentError,
            "rule with given/where/then style requires a `:then` key with an action function"
    end

    # Build synthetic block AST for compile_given_when_then_rule
    # The block looks like: {:__block__, [], [given(...), where(...), then(...)]}
    statements = []

    statements =
      if given_expr do
        [{:given, [], [given_expr]} | statements]
      else
        statements
      end

    statements =
      if where_expr != true do
        [{:where, [], [where_expr]} | statements]
      else
        statements
      end

    statements = [{:then, [], [then_expr]} | statements]

    block = {:__block__, [], Enum.reverse(statements)}

    # Extract non-DSL options (name, inputs, outputs)
    preserved_opts = Keyword.drop(opts, [:given, :where, :then])

    compile_given_when_then_rule(block, preserved_opts, env)
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

  # Fallback for arbitrary expressions (e.g., where clauses with boolean expressions)
  # Phase 1: Support pin operators in any expression, not just function bodies
  defp traverse_expression(expression, env) do
    traverse_any_expression(expression, env)
  end

  # Traverse any AST to find and rewrite pinned variables (^var syntax)
  # Returns {rewritten_ast, bindings} where bindings are assignments to capture pinned vars
  defp traverse_any_expression(ast, env) do
    {rewritten_ast, bindings} =
      Macro.prewalk(ast, [], fn
        {:^, pin_meta, [{var, _, ctx} = _expr]} = _pinned_ast, acc ->
          # Pinned variable - capture it
          new_var = Macro.var(var, ctx)
          {new_var, [{:=, pin_meta, [new_var, {var, [], ctx}]} | acc]}

        otherwise, acc ->
          {Macro.expand(otherwise, env), acc}
      end)

    {rewritten_ast, bindings}
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
  Creates a `%StateMachine{}`: stateful workflows with reducers and conditional reactors.

  State machines combine an accumulator with rules that react to state changes.
  The reducer processes inputs in context of accumulated state, and reactors
  conditionally execute based on the new state.

  ## Basic Usage

      iex> require Runic
      iex> alias Runic.Workflow
      iex> counter = Runic.state_machine(
      ...>   name: :counter,
      ...>   init: 0,
      ...>   reducer: fn x, acc -> acc + x end
      ...> )
      iex> workflow = Workflow.new() |> Workflow.add(counter)
      iex> results = workflow |> Workflow.plan_eagerly(5) |> Workflow.react_until_satisfied() |> Workflow.raw_productions()
      iex> Enum.sort(results)
      [0, 5]

  ## Options

  - `:name` - Identifier for the state machine (required for referencing)
  - `:init` - Initial state (literal value, function, or `{M, F, A}` tuple)
  - `:reducer` - Function `(input, state) -> new_state` for state transitions
  - `:reactors` - List of rules that react to state changes
  - `:inputs` / `:outputs` - Reserved for future schema-based type compatibility

  ## With Reactors

  Reactors are rules that fire when the accumulated state matches their conditions:

      require Runic
      alias Runic.Workflow

      threshold_sm = Runic.state_machine(
        name: :threshold_monitor,
        init: 0,
        reducer: fn x, acc -> acc + x end,
        reactors: [
          fn state when state > 100 -> :threshold_exceeded end,
          fn state when state > 50 -> :warning end
        ]
      )

  ## Lock/Unlock Example

      require Runic

      lock = Runic.state_machine(
        name: :lock,
        init: %{code: "secret", state: :locked},
        reducer: fn
          :lock, state ->
            %{state | state: :locked}
          {:unlock, code}, %{code: code, state: :locked} = state ->
            %{state | state: :unlocked}
          _, state ->
            state
        end,
        reactors: [
          fn %{state: :unlocked} -> :access_granted end,
          fn %{state: :locked} -> :access_denied end
        ]
      )

  ## Captured Variables

  Use `^` for runtime values in reducers and reactors:

      multiplier = 2
      Runic.state_machine(
        name: :scaled_sum,
        init: 0,
        reducer: fn x, acc -> acc + x * ^multiplier end
      )
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
  Creates a `%Map{}`: applies a transformation to each element of an enumerable.

  Map operations fan-out an enumerable input into individual elements, apply
  the transformation to each, and can be followed by a reduce to fan-in results.

  ## Basic Usage

      iex> require Runic
      iex> alias Runic.Workflow
      iex> map_op = Runic.map(fn x -> x * 2 end, name: :double)
      iex> workflow = Workflow.new() |> Workflow.add(map_op)
      iex> results = workflow |> Workflow.plan_eagerly([1, 2, 3]) |> Workflow.react_until_satisfied() |> Workflow.raw_productions()
      iex> Enum.sort(results)
      [2, 4, 6]

  ## Options

  - `:name` - Identifier for referencing in `reduce/3` via `:map` option
  - `:inputs` / `:outputs` - Reserved for future schema-based type compatibility

  ## With Pipeline

  Map can contain nested pipelines:

      require Runic

      Runic.map(
        {Runic.step(fn x -> x * 2 end, name: :double),
         [Runic.step(fn x -> x + 1 end, name: :add_one)]}
      )

  ## Map-Reduce Pattern

  Connect a reduce to collect mapped results. The reduce's `:map` option links
  it to the upstream map:

      iex> require Runic
      iex> alias Runic.Workflow
      iex> map_op = Runic.map(fn x -> x * 2 end, name: :double)
      iex> reduce_op = Runic.reduce(0, fn x, acc -> x + acc end, name: :sum, map: :double)
      iex> workflow = Workflow.new()
      ...>   |> Workflow.add(map_op)
      ...>   |> Workflow.add(reduce_op, to: :double)
      iex> results = workflow
      ...>   |> Workflow.plan_eagerly([1, 2, 3])
      ...>   |> Workflow.react_until_satisfied()
      ...>   |> Workflow.raw_productions(:sum)
      iex> 12 in results
      true

  ## How It Works

  Internally, map uses a FanOut component that splits the enumerable into
  individual facts. Each element is processed independently, enabling
  parallel execution with the `:async` option on `react/2`.
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
  Creates a `%Reduce{}`: aggregates multiple facts into a single accumulated result.

  Reduce operations fan-in results from a map operation or process an enumerable
  from a parent step. Unlike `accumulator/3` which processes single values
  cumulatively, `reduce/3` aggregates over collections.

  ## Basic Usage

  Like `Enum.reduce/3`, process an enumerable from a parent step:

      require Runic
      alias Runic.Workflow

      workflow = Runic.workflow(
        name: :sum_range,
        steps: [
          {Runic.step(fn -> [1, 2, 3, 4, 5] end, name: :generate),
           [Runic.reduce(0, fn x, acc -> x + acc end, name: :sum)]}
        ]
      )

  ## Options

  - `:name` - Identifier for the reduce component
  - `:map` - Name of an upstream map component for fan-in (lazy evaluation)
  - `:inputs` / `:outputs` - Reserved for future schema-based type compatibility

  ## Map-Reduce Pattern (Lazy Evaluation)

  When `:map` is specified, reduce waits for all mapped elements before aggregating.
  This enables lazy/parallel execution of the map phase:

      iex> require Runic
      iex> alias Runic.Workflow
      iex> map_op = Runic.map(fn x -> x * 2 end, name: :double)
      iex> reduce_op = Runic.reduce(0, fn x, acc -> x + acc end, name: :sum, map: :double)
      iex> workflow = Workflow.new()
      ...>   |> Workflow.add(map_op)
      ...>   |> Workflow.add(reduce_op, to: :double)
      iex> results = workflow
      ...>   |> Workflow.plan_eagerly([1, 2, 3])
      ...>   |> Workflow.react_until_satisfied()
      ...>   |> Workflow.raw_productions(:sum)
      iex> 12 in results
      true

  ## Nested Pipeline with Reduce

  Reduce can follow a pipeline after the map:

      require Runic

      Runic.workflow(
        steps: [
          {Runic.map(fn x -> x * 2 end, name: :double),
           [{Runic.step(fn x -> x + 1 end, name: :add_one),
             [Runic.reduce(0, fn x, acc -> x + acc end, name: :sum, map: :double)]}]}
        ]
      )

  ## Important Notes

  - Reduce operations are inherently sequential and cannot be parallelized
    unless your reducer has CRDT (commutative) properties
  - Without `:map`, reduce processes the enumerable eagerly in one invocation
  - With `:map`, reduce waits for all fan-out elements before reducing
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
  Creates an `%Accumulator{}`: maintains cumulative state across individual inputs.

  Unlike `reduce/3` which aggregates over collections, accumulators process
  single values and maintain running state across multiple workflow invocations.
  This makes them ideal for running totals, counters, and stateful computations.

  ## Basic Usage

      iex> require Runic
      iex> alias Runic.Workflow
      iex> acc = Runic.accumulator(0, fn x, state -> state + x end, name: :running_sum)
      iex> workflow = Workflow.new() |> Workflow.add(acc)
      iex> results = workflow |> Workflow.plan_eagerly(5) |> Workflow.react_until_satisfied() |> Workflow.raw_productions()
      iex> 5 in results
      true

  ## Options

  - `:name` - Identifier for the accumulator (useful for referencing in rules)
  - `:inputs` / `:outputs` - Reserved for future schema-based type compatibility

  ## Difference from Reduce

  | Accumulator | Reduce |
  |-------------|--------|
  | Single value per invocation | Aggregates over enumerables |
  | State persists across invocations | One-shot aggregation |
  | For running totals/counters | For map-reduce patterns |

  ## Building State Machines

  Connect rules to accumulators to create state-machine-like behavior:

      require Runic
      alias Runic.Workflow

      counter = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)
      threshold_rule = Runic.rule(
        condition: fn {state, _input} -> state > 100 end,
        reaction: fn _ -> :threshold_exceeded end
      )

  ## Captured Variables

      iex> require Runic
      iex> alias Runic.Workflow
      iex> multiplier = 2
      iex> acc = Runic.accumulator(0, fn x, state -> state + x * ^multiplier end, name: :scaled_sum)
      iex> acc.closure.bindings[:multiplier]
      2
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

  Expands in conjunction with the rest of the expression of the rule's expression to evaluate against the last known state of the component.

  ## Examples

      require Runic
      alias Runic.Workflow

      counter = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      threshold_rule =
        Runic.rule name: :threshold_check do
          given(x: x)
          where(state_of(:counter) > 5)
          then(fn %{x: x} -> {:above_threshold, x} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(counter)
        |> Workflow.add(threshold_rule, to: :counter)
  """
  def state_of(component_name_or_hash), do: doc!([component_name_or_hash])

  @doc """
  Evaluates to true in a condition if the specified step has ever been ran.

  Note that this evaluates to true globally for any prior execution of the workflow, not just within the current invocation.

  ## Examples

      require Runic
      alias Runic.Workflow

      rule =
        Runic.rule name: :after_validation do
          given(x: x)
          where(step_ran?(:validator))
          then(fn %{x: x} -> {:validated, x} end)
        end
  """
  def step_ran?(component_name_or_hash), do: doc!([component_name_or_hash])

  @doc """
  Evaluates to true if the specified step has been executed for the given input fact.

  Considers only input facts for a generation of invokations fed into the root of the workflow.

  ## Examples

      require Runic
      alias Runic.Workflow

      rule =
        Runic.rule name: :scoped_check do
          given(x: x)
          where(step_ran?(:validator, x))
          then(fn %{x: x} -> {:validated, x} end)
        end
  """
  def step_ran?(component_name_or_hash, fact_or_hash),
    do: doc!([component_name_or_hash, fact_or_hash])

  @doc """
  Returns the number of facts produced by a given component in the workflow.

  Used inside `where` clauses of rules to gate on how many facts a component has produced.

  ## Examples

      require Runic

      Runic.rule name: :batch_ready do
        given(x: x)
        where(fact_count(:items) >= 3)
        then(fn %{x: x} -> {:process_batch, x} end)
      end
  """
  def fact_count(component_name_or_hash), do: doc!([component_name_or_hash])

  @doc """
  Returns the most recent raw value produced by a component.

  Useful in `where` clauses to compare against the latest output, or in `then`
  clauses to incorporate another component's latest result.

  ## Examples

  In a `where` clause:

      require Runic

      Runic.rule name: :high_temp_alert do
        given(x: x)
        where(latest_value_of(:sensor) > 100)
        then(fn %{x: x} -> {:alert, x} end)
      end

  In a `then` clause:

      require Runic

      Runic.rule name: :echo_latest do
        given(x: x)
        then(fn %{x: x} -> {:latest, x, latest_value_of(:sensor)} end)
      end
  """
  def latest_value_of(component_name_or_hash), do: doc!([component_name_or_hash])

  @doc """
  Returns the most recent `%Fact{}` struct produced by a component.

  Unlike `latest_value_of/1`, this returns the full `%Fact{}` struct including
  metadata such as `hash` and `ancestry`, not just the raw value.

  ## Examples

      require Runic

      Runic.rule name: :check_latest_fact do
        given(x: x)
        where(latest_fact_of(:processor) != nil)
        then(fn %{x: x} -> {:ok, x} end)
      end
  """
  def latest_fact_of(component_name_or_hash), do: doc!([component_name_or_hash])

  @doc """
  Returns a list of all raw values produced by a component across all invocations.

  Useful for aggregation in `where` or `then` clauses, e.g. summing all scores.

  ## Examples

  In a `where` clause:

      require Runic

      Runic.rule name: :sum_check do
        given(x: x)
        where(Enum.sum(all_values_of(:scores)) > 100)
        then(fn %{x: x} -> {:high_score, x} end)
      end

  In a `then` clause:

      require Runic

      Runic.rule name: :sum_all_scores do
        given(x: _x)
        then(fn _bindings -> Enum.sum(all_values_of(:scores)) end)
      end
  """
  def all_values_of(component_name_or_hash), do: doc!([component_name_or_hash])

  @doc """
  Returns a list of all `%Fact{}` structs produced by a component across all invocations.

  Unlike `all_values_of/1`, this returns full `%Fact{}` structs with metadata.

  ## Examples

      require Runic

      Runic.rule name: :multi_fact_check do
        given(x: x)
        where(length(all_facts_of(:events)) > 0)
        then(fn %{x: x} -> {:has_events, x} end)
      end
  """
  def all_facts_of(component_name_or_hash), do: doc!([component_name_or_hash])

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

  # Creates a variable AST marked as generated to suppress unused variable warnings
  defp generated_var(name) do
    {name, [generated: true], nil}
  end

  # Marks all variables in an AST as generated to suppress unused variable warnings
  defp mark_vars_generated(ast) do
    Macro.prewalk(ast, fn
      {name, meta, context} when is_atom(name) and is_atom(context) ->
        {name, Keyword.put(meta, :generated, true), context}

      other ->
        other
    end)
  end

  defp compile_given_when_then_rule(block, opts, env) do
    # Parse the block to extract given, when, then clauses
    {given_clause, where_clause, then_clause} = parse_given_when_then_block(block)

    # Extract bindings and pattern from given clause
    {pattern_ast, top_binding, binding_vars} = compile_given_clause(given_clause)

    # Detect meta expressions in the where clause
    condition_meta_refs = detect_meta_expressions(where_clause)
    has_condition_meta = condition_meta_refs != []

    # Compile where clause into a condition function
    # If meta expressions present, compile with 2-arity (input, meta_ctx)
    {condition_fn, condition_arity, condition_meta_refs} =
      if has_condition_meta do
        fn_ast =
          compile_meta_when_clause(
            where_clause,
            pattern_ast,
            top_binding,
            binding_vars,
            env,
            condition_meta_refs
          )

        {fn_ast, 2, condition_meta_refs}
      else
        fn_ast = compile_when_clause(where_clause, pattern_ast, top_binding, binding_vars, env)
        {fn_ast, 1, []}
      end

    # Detect meta expressions in the then clause
    reaction_meta_refs = detect_meta_expressions(then_clause)
    has_reaction_meta = reaction_meta_refs != []

    # Compile then clause - if meta expressions present, compile with 2-arity (input, meta_ctx)
    {reaction_fn, reaction_meta_refs} =
      if has_reaction_meta do
        fn_ast =
          compile_meta_then_clause(
            then_clause,
            pattern_ast,
            top_binding,
            binding_vars,
            env,
            reaction_meta_refs
          )

        {fn_ast, reaction_meta_refs}
      else
        fn_ast = compile_then_clause(then_clause, pattern_ast, top_binding, binding_vars, env)
        {fn_ast, []}
      end

    # Get options
    {rewritten_opts, opts_bindings} = traverse_options(opts, env)
    name = rewritten_opts[:name]

    # Determine arity for the rule (always 1 for DSL rules - single input matched against pattern)
    # But condition may be 2-arity if it has meta refs
    arity = 1

    # Build the rule workflow with meta refs if present
    {workflow, condition_hash, reaction_hash} =
      workflow_of_rule_with_meta(
        {condition_fn, reaction_fn},
        arity,
        condition_arity,
        condition_meta_refs,
        reaction_meta_refs
      )

    source =
      quote do
        Runic.rule(unquote(opts), do: unquote(block))
      end

    closure_source =
      quote do
        Runic.rule(unquote(rewritten_opts), do: unquote(block))
      end

    # Collect bindings from where clause (for pin operators in conditions)
    {_rewritten_where, where_bindings} = traverse_expression(where_clause, env)

    # Collect bindings from then clause
    {_rewritten_then, then_bindings} = traverse_expression(then_clause, env)
    variable_bindings = Enum.uniq(where_bindings ++ then_bindings ++ opts_bindings)

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
    {generated_var(:input), :input, [{:input, generated_var(:input)}]}
  end

  # Phase 2: Direct map pattern - given(%{item: i, quantity: q})
  defp compile_given_clause({:%{}, _, pairs} = pattern) when is_list(pairs) do
    # Mark variables as generated to suppress unused variable warnings
    pattern = mark_vars_generated(pattern)

    # For direct map patterns, we need to:
    # 1. Extract all variables from the map pattern (the variable names like `i`, `q`)
    # 2. Also add the map keys themselves (like `item`, `quantity`) bound to their values
    #
    # This allows `then(fn %{item: i} -> ... end)` to work correctly
    binding_vars = extract_pattern_variables(pattern)

    # Add key bindings: for %{item: i}, add both `i` (the variable) and `item` bound to same value
    key_bindings =
      Enum.flat_map(pairs, fn
        {key, {var_name, _, ctx}} when is_atom(key) and is_atom(var_name) and is_atom(ctx) ->
          # Key maps to a variable - bind key to the same variable
          [{key, generated_var(var_name)}]

        {key, _pattern} when is_atom(key) ->
          # Key maps to a complex pattern - try to bind key to the whole match if possible
          # For now, we can't easily do this, so skip
          []

        _ ->
          []
      end)

    # Merge: key_bindings first, then binding_vars (vars take precedence if same name)
    all_vars = Enum.uniq_by(key_bindings ++ binding_vars, fn {name, _} -> name end)

    # No top_binding for direct map patterns (input IS the map)
    {pattern, nil, all_vars}
  end

  # Phase 2: Direct tuple pattern (3+ elements) - given({:event, type, payload})
  defp compile_given_clause({:{}, _, elements} = pattern) when is_list(elements) do
    pattern = mark_vars_generated(pattern)
    binding_vars = extract_pattern_variables(pattern)
    {pattern, nil, binding_vars}
  end

  # Phase 2: Two-element tuple pattern - given({:ok, value})
  defp compile_given_clause({_first, _second} = pattern) do
    pattern = mark_vars_generated(pattern)
    binding_vars = extract_pattern_variables(pattern)
    {pattern, nil, binding_vars}
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
        # Mark pattern variables as generated to suppress unused variable warnings
        pattern = mark_vars_generated(pattern)

        case pattern do
          {var_name, _, ctx} when is_atom(var_name) and is_atom(ctx) ->
            # Pattern is just a variable - check if it's same as binding_name
            if var_name == binding_name do
              # Just use _ as pattern and bind to binding_name
              {generated_var(binding_name), binding_name,
               [{binding_name, generated_var(binding_name)}]}
            else
              # Different names - use the pattern variable
              binding_vars = extract_pattern_variables(pattern)
              all_vars = [{binding_name, generated_var(binding_name)} | binding_vars]
              {pattern, binding_name, all_vars}
            end

          {:_, _, _} ->
            # Pattern is underscore - just bind to binding_name
            {{:_, [generated: true], nil}, binding_name,
             [{binding_name, generated_var(binding_name)}]}

          _ ->
            # Complex pattern - extract all variables from it
            binding_vars = extract_pattern_variables(pattern)
            # Add the top-level binding
            all_vars = [{binding_name, generated_var(binding_name)} | binding_vars]
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
            pattern = mark_vars_generated(pattern)
            pattern_vars = extract_pattern_variables(pattern)
            [{name, generated_var(name)} | pattern_vars]
          end)

        # Build a map pattern that binds each key's value to a variable
        # Each entry becomes: key: pattern = var
        map_entries =
          Enum.map(multiple_bindings, fn {name, pattern} ->
            pattern = mark_vars_generated(pattern)
            # Bind the pattern to a variable with the same name as the key
            {name, {:=, [], [pattern, generated_var(name)]}}
          end)

        map_pattern = {:%{}, [], map_entries}
        {map_pattern, nil, all_vars}
    end
  end

  defp extract_pattern_variables(pattern) do
    # Walk the pattern AST and collect all variable bindings
    # Variables are marked as generated to suppress unused variable warnings
    {_ast, vars} =
      Macro.prewalk(pattern, [], fn
        # Skip underscores and underscore-prefixed vars
        {:_, _, _} = node, acc ->
          {node, acc}

        # Collect variables
        {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
          name_str = Atom.to_string(name)

          # Skip special forms, underscore-prefixed, and module names
          if String.starts_with?(name_str, "_") or
               name in [:__MODULE__, :__ENV__, :__DIR__, :__CALLER__] or
               String.match?(name_str, ~r/^[A-Z]/) do
            {node, acc}
          else
            # Mark extracted variables as generated
            {node, [{name, generated_var(name)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq_by(vars, fn {name, _} -> name end)
  end

  defp compile_when_clause(when_expr, pattern, top_binding, _binding_vars, env) do
    # Build a condition function that:
    # 1. Matches the input against the pattern
    # 2. If matched, evaluates the when expression with bindings
    # 3. Returns boolean
    #
    # Phase 1: where clauses are now compiled as full function bodies,
    # supporting pin operators (^var) and any Elixir expression (not just guards).

    # Check if the when_expr is literal true (no condition)
    is_always_true = when_expr == true

    # Traverse the where expression for pinned variables (^var)
    {rewritten_when_expr, when_bindings} = traverse_expression(when_expr, env)

    # The when expression, with variables bound
    when_body =
      if is_always_true do
        true
      else
        rewritten_when_expr
      end

    # Build the case pattern - if we have a top_binding, use = to bind the whole value
    # But avoid self-match like `value = value` when pattern IS the top_binding var
    # Mark the when_body variables as generated for proper warning suppression
    when_body = mark_vars_generated(when_body)

    case_pattern =
      cond do
        is_nil(top_binding) ->
          pattern

        # Check if pattern is the same variable as top_binding
        match?({^top_binding, _, ctx} when is_atom(ctx), pattern) ->
          # Pattern is already the binding variable, no need to wrap with =
          pattern

        true ->
          # Bind the whole matched value to the binding name (use generated var)
          {:=, [], [generated_var(top_binding), pattern]}
      end

    # Build the condition function
    # Use generated: true to suppress unused variable warnings for pattern bindings
    # If we have pinned bindings, we need to capture them in the closure
    _ = when_bindings

    quote generated: true do
      fn input ->
        case input do
          unquote(case_pattern) ->
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
          {:=, [], [generated_var(top_binding), pattern]}
      end

    # Build bindings map from the extracted variables
    # Use the stored AST for each binding - this allows key aliases (like :item -> :i variable)
    bindings_map_entries =
      Enum.map(binding_vars, fn {name, ast} ->
        {name, ast}
      end)

    bindings_map = {:%{}, [], bindings_map_entries}

    # Use generated: true to suppress unused variable warnings for pattern bindings
    case then_expr do
      {:fn, _, _} ->
        # User provided a function - traverse for ^ bindings then wrap
        {rewritten_fn, _bindings} = traverse_expression(then_expr, env)

        quote generated: true do
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
        quote generated: true do
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
        quote generated: true do
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

  defp workflow_of_rule_with_meta(
         {condition, reaction},
         rule_arity,
         condition_arity,
         condition_meta_refs,
         reaction_meta_refs
       ) do
    reaction_ast_hash = Components.fact_hash(reaction)
    escaped_reaction_meta_refs = Macro.escape(reaction_meta_refs)

    reaction_step =
      quote do
        Step.new(
          work: unquote(reaction),
          hash: unquote(reaction_ast_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )
      end

    condition_ast_hash = Components.fact_hash(condition)
    escaped_condition_meta_refs = Macro.escape(condition_meta_refs)

    condition_node =
      quote do
        Condition.new(
          work: unquote(condition),
          hash: unquote(condition_ast_hash),
          arity: unquote(condition_arity),
          meta_refs: unquote(escaped_condition_meta_refs)
        )
      end

    workflow =
      quote do
        import Runic

        Workflow.new()
        |> Workflow.add_step(unquote(condition_node))
        |> Workflow.add_step(unquote(condition_node), unquote(reaction_step))
      end

    _ = rule_arity

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

  # =============================================================================
  # Meta Expression Detection and Compilation
  # =============================================================================

  @meta_expression_kinds [
    :state_of,
    :step_ran?,
    :fact_count,
    :latest_value_of,
    :latest_fact_of,
    :all_values_of,
    :all_facts_of
  ]

  @doc false
  def detect_meta_expressions(ast) do
    {_rewritten, refs} = Macro.prewalk(ast, [], &collect_meta_ref/2)
    Enum.reverse(refs)
  end

  # Handle field access: check if it's accessing a meta expression (potentially chained)
  defp collect_meta_ref({:., _, [_inner, field]} = node, acc) when is_atom(field) do
    case extract_meta_expression_with_fields(node) do
      {:ok, kind, target, field_path} ->
        existing = find_ref_by_target(acc, target, kind)

        if existing do
          # Update the field_path to the longer path (we process outer-to-inner)
          updated = update_field_path_if_longer(acc, target, kind, field_path)
          {node, updated}
        else
          context_key = build_context_key(target, kind)

          ref = %{
            kind: kind,
            target: target,
            field_path: field_path,
            context_key: context_key
          }

          {node, [ref | acc]}
        end

      :not_meta ->
        {node, acc}
    end
  end

  defp collect_meta_ref({kind, _, [target]} = node, acc)
       when kind in @meta_expression_kinds do
    existing = find_ref_by_target(acc, target, kind)

    unless existing do
      context_key = build_context_key(target, kind)

      ref = %{
        kind: kind,
        target: target,
        field_path: [],
        context_key: context_key
      }

      {node, [ref | acc]}
    else
      {node, acc}
    end
  end

  defp collect_meta_ref(node, acc), do: {node, acc}

  # Extract meta expression and field path from chained field access
  # e.g., state_of(:config).database.connection.pool_size
  # Returns {:ok, kind, target, field_path} or :not_meta
  defp extract_meta_expression_with_fields({:., _, [inner, field]}) when is_atom(field) do
    case extract_meta_expression_with_fields(inner) do
      {:ok, kind, target, inner_fields} ->
        {:ok, kind, target, inner_fields ++ [field]}

      :not_meta ->
        :not_meta
    end
  end

  # Match the call form of dot access (e.g., `foo.bar` becomes `{{:., _, [foo, :bar]}, _, []}`)
  defp extract_meta_expression_with_fields({{:., _, [inner, field]}, _, []})
       when is_atom(field) do
    case extract_meta_expression_with_fields(inner) do
      {:ok, kind, target, inner_fields} ->
        {:ok, kind, target, inner_fields ++ [field]}

      :not_meta ->
        :not_meta
    end
  end

  # Base case: bare meta expression like state_of(:config)
  defp extract_meta_expression_with_fields({:state_of, _, [target]}) do
    {:ok, :state_of, target, []}
  end

  # For other meta expression kinds (they don't typically have field access, but handle for completeness)
  defp extract_meta_expression_with_fields({kind, _, [target]})
       when kind in @meta_expression_kinds do
    {:ok, kind, target, []}
  end

  defp extract_meta_expression_with_fields(_), do: :not_meta

  defp find_ref_by_target(refs, target, kind) do
    Enum.find(refs, fn ref -> ref.target == target and ref.kind == kind end)
  end

  # Update field_path only if the new path is longer (outer nodes have longer paths)
  defp update_field_path_if_longer(refs, target, kind, new_field_path) do
    Enum.map(refs, fn ref ->
      if ref.target == target and ref.kind == kind and
           length(new_field_path) > length(ref.field_path) do
        %{ref | field_path: new_field_path}
      else
        ref
      end
    end)
  end

  defp build_context_key(target, kind) when is_atom(target) do
    suffix =
      case kind do
        :state_of -> "_state"
        :step_ran? -> "_ran"
        :fact_count -> "_count"
        :latest_value_of -> "_latest_value"
        :latest_fact_of -> "_latest_fact"
        :all_values_of -> "_all_values"
        :all_facts_of -> "_all_facts"
      end

    String.to_atom("#{target}#{suffix}")
  end

  defp build_context_key(_target, kind) do
    String.to_atom("meta_#{kind}")
  end

  @doc false
  def has_meta_expressions?(ast) do
    detect_meta_expressions(ast) != []
  end

  @doc false
  def rewrite_meta_refs_in_ast(ast, meta_refs) do
    # Use var! with Runic context to match compile_meta_when_clause
    meta_ctx_var = quote(do: var!(meta_ctx, Runic))

    Macro.prewalk(ast, fn node ->
      case node do
        # state_of(:x).field - full dot access expression with call
        {{:., dot_meta, [{:state_of, _, [target]}, field]}, call_meta, []} ->
          ref = find_ref_by_target(meta_refs, target, :state_of)

          if ref do
            # Build: Map.get(meta_ctx, :context_key, %{}).field
            # Use Map.get with default empty map to avoid KeyError
            map_get = quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key), %{}))
            {{:., dot_meta, [map_get, field]}, call_meta, []}
          else
            node
          end

        # state_of(:x) without field access
        {:state_of, _, [target]} ->
          ref = find_ref_by_target(meta_refs, target, :state_of)

          if ref do
            # Build: Map.get(meta_ctx, :context_key)
            quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key)))
          else
            node
          end

        # Other meta expressions: step_ran?, fact_count, etc.
        {kind, _, [target]} when kind in @meta_expression_kinds ->
          ref = find_ref_by_target(meta_refs, target, kind)

          if ref do
            quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key)))
          else
            node
          end

        other ->
          other
      end
    end)
  end

  @doc false
  def compile_meta_then_clause(
        then_expr,
        pattern,
        top_binding,
        binding_vars,
        env,
        meta_refs
      ) do
    # Build bindings map from the extracted variables
    # Use the stored AST for each binding - this allows key aliases (like :item -> :i variable)
    bindings_map_entries =
      Enum.map(binding_vars, fn {name, ast} ->
        {name, ast}
      end)

    bindings_map = {:%{}, [], bindings_map_entries}

    case_pattern =
      cond do
        is_nil(top_binding) ->
          pattern

        match?({^top_binding, _, ctx} when is_atom(ctx), pattern) ->
          pattern

        true ->
          {:=, [], [generated_var(top_binding), pattern]}
      end

    case then_expr do
      {:fn, _, _} ->
        # User provided a function - traverse for ^ bindings, rewrite meta expressions
        {rewritten_fn, _bindings} = traverse_expression(then_expr, env)
        rewritten_fn = rewrite_meta_refs_in_ast(rewritten_fn, meta_refs)

        quote generated: true do
          fn input, var!(meta_ctx, Runic) ->
            _ = var!(meta_ctx, Runic)

            case input do
              unquote(case_pattern) ->
                bindings = unquote(bindings_map)
                unquote(rewritten_fn).(bindings)
            end
          end
        end

      {:&, _, _} ->
        # Capture syntax - wrap to pass bindings
        # Note: Capture syntax can't use meta expressions directly in the captured function
        # The meta expressions would need to be in the wrapping function
        quote generated: true do
          fn input, var!(meta_ctx, Runic) ->
            _ = var!(meta_ctx, Runic)

            case input do
              unquote(case_pattern) ->
                bindings = unquote(bindings_map)
                unquote(then_expr).(bindings)
            end
          end
        end

      _ ->
        # Raw expression - wrap in a function, rewrite meta expressions
        rewritten_expr = rewrite_meta_refs_in_ast(then_expr, meta_refs)
        rewritten_expr = mark_vars_generated(rewritten_expr)

        quote generated: true do
          fn input, var!(meta_ctx, Runic) ->
            _ = var!(meta_ctx, Runic)

            case input do
              unquote(case_pattern) ->
                _bindings = unquote(bindings_map)
                unquote(rewritten_expr)
            end
          end
        end
    end
  end

  @doc false
  def compile_meta_when_clause(when_expr, pattern, top_binding, _binding_vars, _env, meta_refs) do
    rewritten_body = rewrite_meta_refs_in_ast(when_expr, meta_refs)
    rewritten_body = mark_vars_generated(rewritten_body)

    case_pattern =
      cond do
        is_nil(top_binding) ->
          pattern

        match?({^top_binding, _, ctx} when is_atom(ctx), pattern) ->
          pattern

        true ->
          {:=, [], [generated_var(top_binding), pattern]}
      end

    quote generated: true do
      fn input, var!(meta_ctx, Runic) ->
        _ = var!(meta_ctx, Runic)

        case input do
          unquote(case_pattern) ->
            unquote(rewritten_body)

          _ ->
            false
        end
      end
    end
  end
end
