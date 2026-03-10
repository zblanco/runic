defmodule Runic do
  @external_resource "README.md"
  @moduledoc "README.md" |> File.read!() |> String.split("<!-- MDOC !-->") |> Enum.fetch!(1)

  alias Runic.Closure
  alias Runic.ClosureMetadata
  alias Runic.Workflow.CompilationUtils
  alias Runic.Workflow.Accumulator
  alias Runic.Workflow.Aggregate
  alias Runic.Workflow.StateMachine
  alias Runic.Workflow.Saga
  alias Runic.Workflow.FSM
  alias Runic.Workflow.ProcessManager
  alias Runic.Workflow
  alias Runic.Workflow.Step
  alias Runic.Workflow.Condition
  alias Runic.Workflow.Rule
  alias Runic.Workflow.Components
  alias Runic.Workflow.Conjunction
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

    # Detect context/1 meta expressions and rewrite if found
    {final_work, meta_refs} = maybe_compile_meta_work(work, rewritten_work, __CALLER__)
    escaped_meta_refs = escape_meta_refs(meta_refs)

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
          work: unquote(final_work),
          closure: unquote(closure),
          name: unquote(default_component_name("step", step_hash)),
          hash: unquote(step_hash),
          work_hash: unquote(work_hash),
          inputs: nil,
          outputs: nil,
          meta_refs: unquote(escaped_meta_refs)
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
          work: unquote(final_work),
          closure: closure,
          name: unquote(default_component_name("step", "_")) <> "_#{step_hash}",
          hash: step_hash,
          work_hash: work_hash,
          inputs: nil,
          outputs: nil,
          meta_refs: unquote(escaped_meta_refs)
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

    # Detect context/1 meta expressions and rewrite if found
    {final_work, meta_refs} = maybe_compile_meta_work(work, rewritten_work, __CALLER__)
    escaped_meta_refs = escape_meta_refs(meta_refs)

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
          work: unquote(final_work),
          closure: unquote(closure),
          name: unquote(step_name),
          hash: unquote(step_hash),
          work_hash: unquote(work_hash),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs]),
          meta_refs: unquote(escaped_meta_refs)
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
          work: unquote(final_work),
          closure: closure,
          name: step_name,
          hash: step_hash,
          work_hash: work_hash,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs]),
          meta_refs: unquote(escaped_meta_refs)
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

    # Detect context/1 meta expressions and rewrite if found
    {final_work, meta_refs} = maybe_compile_meta_work(work, rewritten_work, __CALLER__)
    escaped_meta_refs = escape_meta_refs(meta_refs)

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
          work: unquote(final_work),
          closure: unquote(closure),
          name: unquote(step_name),
          hash: unquote(step_hash),
          work_hash: unquote(work_hash),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs]),
          meta_refs: unquote(escaped_meta_refs)
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
          work: unquote(final_work),
          closure: closure,
          name: step_name,
          hash: step_hash,
          work_hash: work_hash,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs]),
          meta_refs: unquote(escaped_meta_refs)
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

  ## With Name Option

      iex> require Runic
      iex> cond = Runic.condition(fn x -> x > 10 end, name: :big_number)
      iex> cond.name
      :big_number

  ## Captured Variables with `^`

  Use the pin operator `^` to capture outer scope variables:

      iex> require Runic
      iex> threshold = 10
      iex> cond = Runic.condition(fn x -> x > ^threshold end)
      iex> cond.closure.bindings[:threshold]
      10
      iex> cond.work.(15)
      true

  ## Use Cases

  - **Expensive checks**: When a condition involves costly operations (e.g., API calls,
    database queries), define it once and reference it in multiple rules
  - **Stateful conditions**: Use `state_of/1` to create conditions that depend on
    accumulator or state machine state
  - **Reusability**: Share predicates across rules for consistency

  Note: Conditions should be pure and deterministic - they should not execute side effects.
  """
  defmacro condition({:fn, _, _} = work) do
    source =
      quote do
        Runic.condition(unquote(work))
      end

    {rewritten_work, work_bindings} = traverse_expression(work, __CALLER__)

    # Detect context/1 meta expressions and rewrite if found
    {final_work, meta_refs} = maybe_compile_meta_work(work, rewritten_work, __CALLER__)
    escaped_meta_refs = escape_meta_refs(meta_refs)
    arity = if meta_refs != [], do: 2, else: condition_arity_from_fn_ast(work)

    variable_bindings =
      work_bindings
      |> Enum.uniq()

    closure_source =
      quote do
        Runic.condition(unquote(rewritten_work))
      end

    closure = build_closure(closure_source, variable_bindings, __CALLER__)

    if Enum.empty?(variable_bindings) do
      condition_hash = Components.fact_hash(source)
      work_hash = Components.fact_hash(work)

      quote do
        Condition.new(
          work: unquote(final_work),
          closure: unquote(closure),
          name: unquote(default_component_name("condition", condition_hash)),
          hash: unquote(condition_hash),
          work_hash: unquote(work_hash),
          arity: unquote(arity),
          meta_refs: unquote(escaped_meta_refs)
        )
      end
    else
      normalized_work = normalize_ast(rewritten_work)

      quote do
        closure = unquote(closure)
        condition_hash = closure.hash

        work_hash =
          Components.fact_hash({unquote(Macro.escape(normalized_work)), closure.bindings})

        Condition.new(
          work: unquote(final_work),
          closure: closure,
          name: unquote(default_component_name("condition", "_")) <> "_#{condition_hash}",
          hash: condition_hash,
          work_hash: work_hash,
          arity: unquote(arity),
          meta_refs: unquote(escaped_meta_refs)
        )
      end
    end
  end

  defmacro condition({:&, _, _} = work) do
    source =
      quote do
        Runic.condition(unquote(work))
      end

    condition_hash = Components.fact_hash(source)
    work_hash = Components.fact_hash(work)

    closure_source = source
    closure = build_closure(closure_source, [], __CALLER__)

    quote do
      work_fn = unquote(work)
      arity = Function.info(work_fn, :arity) |> elem(1)

      Condition.new(
        work: work_fn,
        closure: unquote(closure),
        name: unquote(default_component_name("condition", condition_hash)),
        hash: unquote(condition_hash),
        work_hash: unquote(work_hash),
        arity: arity
      )
    end
  end

  defmacro condition(name) when is_atom(name) do
    quote do
      %Runic.Workflow.ConditionRef{name: unquote(name)}
    end
  end

  defmacro condition({:{}, _, [m, f, a]}) do
    quote do
      work_fn = Function.capture(unquote(m), unquote(f), unquote(a))

      Condition.new(
        work: work_fn,
        hash: Components.work_hash(work_fn),
        arity: unquote(a)
      )
    end
  end

  defmacro condition(work, opts) do
    {rewritten_opts, opts_bindings} =
      if is_list(opts), do: traverse_options(opts, __CALLER__), else: {opts, []}

    case work do
      {:fn, _, _} ->
        source =
          quote do
            Runic.condition(unquote(work), unquote(opts))
          end

        {rewritten_work, work_bindings} = traverse_expression(work, __CALLER__)

        # Detect context/1 meta expressions and rewrite if found
        {final_work, meta_refs} = maybe_compile_meta_work(work, rewritten_work, __CALLER__)
        escaped_meta_refs = escape_meta_refs(meta_refs)
        arity = if meta_refs != [], do: 2, else: condition_arity_from_fn_ast(work)

        variable_bindings =
          (work_bindings ++ opts_bindings)
          |> Enum.uniq()

        closure_source =
          quote do
            Runic.condition(unquote(rewritten_work), unquote(opts))
          end

        closure = build_closure(closure_source, variable_bindings, __CALLER__)

        if Enum.empty?(variable_bindings) do
          condition_hash = Components.fact_hash(source)
          work_hash = Components.fact_hash(work)

          condition_name =
            rewritten_opts[:name] || default_component_name("condition", condition_hash)

          quote do
            Condition.new(
              work: unquote(final_work),
              closure: unquote(closure),
              name: unquote(condition_name),
              hash: unquote(condition_hash),
              work_hash: unquote(work_hash),
              arity: unquote(arity),
              meta_refs: unquote(escaped_meta_refs)
            )
          end
        else
          base_name = rewritten_opts[:name]
          normalized_work = normalize_ast(rewritten_work)

          quote do
            closure = unquote(closure)
            condition_hash = closure.hash

            work_hash =
              Components.fact_hash({unquote(Macro.escape(normalized_work)), closure.bindings})

            condition_name =
              if unquote(base_name) do
                unquote(base_name)
              else
                unquote(default_component_name("condition", "_")) <> "_#{condition_hash}"
              end

            Condition.new(
              work: unquote(final_work),
              closure: closure,
              name: condition_name,
              hash: condition_hash,
              work_hash: work_hash,
              arity: unquote(arity),
              meta_refs: unquote(escaped_meta_refs)
            )
          end
        end

      {:&, _, _} ->
        source =
          quote do
            Runic.condition(unquote(work), unquote(opts))
          end

        condition_hash = Components.fact_hash(source)
        work_hash = Components.fact_hash(work)
        closure = build_closure(source, [], __CALLER__)

        condition_name =
          rewritten_opts[:name] || default_component_name("condition", condition_hash)

        quote do
          work_fn = unquote(work)
          arity = Function.info(work_fn, :arity) |> elem(1)

          Condition.new(
            work: work_fn,
            closure: unquote(closure),
            name: unquote(condition_name),
            hash: unquote(condition_hash),
            work_hash: unquote(work_hash),
            arity: arity
          )
        end

      _ ->
        quote do
          Runic.__condition_runtime__(unquote(work), unquote(rewritten_opts))
        end
    end
  end

  @doc false
  def __condition_runtime__(fun, opts \\ []) when is_function(fun) do
    arity = Function.info(fun, :arity) |> elem(1)

    Condition.new(
      work: fun,
      hash: Components.work_hash(fun),
      arity: arity,
      name: opts[:name]
    )
  end

  defp condition_arity_from_fn_ast({:fn, _, clauses}) do
    case clauses do
      [{:->, _, [args, _]} | _] ->
        args
        |> List.flatten()
        |> Enum.count()

      _ ->
        1
    end
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

        {key, {var, meta, ctx} = expr}, {opts_acc, bindings_acc}
        when is_atom(var) and is_atom(ctx) and var != :_ ->
          new_var = Macro.var(var, ctx)
          binding_assignment = {:=, meta, [new_var, expr]}
          {[{key, new_var} | opts_acc], [binding_assignment | bindings_acc]}

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

    inputs = validate_component_schema(rewritten_opts[:inputs], "state_machine", [:reactors])
    outputs = validate_component_schema(rewritten_opts[:outputs], "state_machine", [:accumulator])

    {rewritten_reducer, reducer_bindings} = traverse_expression(reducer, __CALLER__)

    # Detect meta expressions in reducer for accumulator
    {final_reducer, reducer_meta_refs} =
      maybe_compile_meta_reducer(reducer, rewritten_reducer, __CALLER__)

    escaped_reducer_meta_refs = escape_meta_refs(reducer_meta_refs)

    variable_bindings =
      (reducer_bindings ++ opts_bindings)
      |> Enum.uniq()

    bindings = build_bindings(variable_bindings, __CALLER__)

    state_machine_hash = Components.fact_hash({init, rewritten_reducer, reactors})
    state_machine_name = name || default_component_name("state_machine", state_machine_hash)

    # Build the accumulator AST
    accumulator_ast =
      build_state_machine_accumulator(
        init,
        final_reducer,
        state_machine_name,
        escaped_reducer_meta_refs
      )

    # Build reactor rules AST
    reactor_rules_ast = build_reactor_rules(reactors, state_machine_name, __CALLER__)

    # Build derived workflow AST
    workflow_ast =
      build_state_machine_workflow(accumulator_ast, reactor_rules_ast, state_machine_name)

    source =
      quote do
        Runic.state_machine(unquote(opts))
      end

    quote do
      unquote_splicing(Enum.reverse(variable_bindings))

      sm_accumulator = unquote(accumulator_ast)
      sm_reactor_rules = unquote(reactor_rules_ast)

      %StateMachine{
        name: unquote(state_machine_name),
        init: unquote(init),
        reducer: unquote(rewritten_reducer),
        reactors: unquote(reactors),
        accumulator: sm_accumulator,
        reactor_rules: sm_reactor_rules,
        workflow: unquote(workflow_ast),
        source: unquote(Macro.escape(source)),
        hash: unquote(state_machine_hash),
        bindings: unquote(bindings),
        inputs: unquote(inputs),
        outputs: unquote(outputs)
      }
    end
  end

  @doc """
  Creates a `%Saga{}`: a sequence of transaction steps with compensating actions.

  Sagas are explicit forward-then-compensate pipelines. Each transaction step
  must have a corresponding compensate block. On failure, completed steps are
  compensated in reverse order.

  Compiles to an Accumulator (tracking saga state), forward Rules (one per
  transaction step), and compensation Rules (one per compensate block).

  ## Usage

      require Runic

      saga = Runic.saga name: :fulfillment do
        transaction :reserve_inventory do
          fn _input -> {:ok, :reserved} end
        end
        compensate :reserve_inventory do
          fn %{reserve_inventory: _} -> :released end
        end

        transaction :charge_payment do
          fn %{reserve_inventory: _} -> {:ok, :charged} end
        end
        compensate :charge_payment do
          fn %{charge_payment: _} -> :refunded end
        end

        on_complete fn results -> {:saga_completed, results} end
        on_abort fn reason, compensated -> {:saga_aborted, reason, compensated} end
      end
  """
  defmacro saga(opts \\ [], do: block) do
    {name, opts_rest} = Keyword.pop(opts, :name)
    inputs = Keyword.get(opts_rest, :inputs)
    outputs = Keyword.get(opts_rest, :outputs)

    unless name, do: raise(ArgumentError, "Saga requires a :name option")

    {transactions, compensations, on_complete, on_abort} = parse_saga_block(block)

    transaction_names = Enum.map(transactions, fn {n, _} -> n end)

    Enum.each(transaction_names, fn tx_name ->
      unless Enum.any?(compensations, fn {n, _} -> n == tx_name end) do
        raise ArgumentError,
              "Saga #{inspect(name)}: transaction #{inspect(tx_name)} has no corresponding compensate block"
      end
    end)

    compensation_names = Enum.map(compensations, fn {n, _} -> n end)

    saga_hash =
      Components.fact_hash(
        {name, transaction_names, compensation_names, on_complete != nil, on_abort != nil}
      )

    step_names = transaction_names

    init_ast = build_saga_init(step_names)

    reducer_ast = build_saga_reducer_with_steps(transactions, compensations, step_names)

    accumulator_ast = build_saga_accumulator(init_ast, reducer_ast, name)

    terminal_rules_ast = build_saga_terminal_rules(on_complete, on_abort, name)

    workflow_ast =
      build_saga_workflow_simple(accumulator_ast, terminal_rules_ast, name)

    source =
      quote do
        Runic.saga(unquote(opts), do: unquote(Macro.escape(block)))
      end

    quote do
      saga_accumulator = unquote(accumulator_ast)
      saga_terminal_rules = unquote(terminal_rules_ast)

      %Saga{
        name: unquote(name),
        steps: unquote(Macro.escape(Enum.zip(transactions, compensations))),
        on_complete: unquote(Macro.escape(on_complete)),
        on_abort: unquote(Macro.escape(on_abort)),
        accumulator: saga_accumulator,
        forward_rules: saga_terminal_rules,
        compensation_rules: [],
        workflow: unquote(workflow_ast),
        source: unquote(Macro.escape(source)),
        hash: unquote(saga_hash),
        inputs: unquote(inputs),
        outputs: unquote(outputs)
      }
    end
  end

  defp parse_saga_block({:__block__, _, exprs}), do: parse_saga_exprs(exprs)
  defp parse_saga_block(single_expr), do: parse_saga_exprs([single_expr])

  defp parse_saga_exprs(exprs) do
    transactions =
      Enum.flat_map(exprs, fn
        {:transaction, _, [step_name, [do: body]]} -> [{step_name, body}]
        _ -> []
      end)

    compensations =
      Enum.flat_map(exprs, fn
        {:compensate, _, [step_name, [do: body]]} -> [{step_name, body}]
        _ -> []
      end)

    on_complete =
      Enum.find_value(exprs, fn
        {:on_complete, _, [fn_ast]} -> fn_ast
        _ -> nil
      end)

    on_abort =
      Enum.find_value(exprs, fn
        {:on_abort, _, [fn_ast]} -> fn_ast
        _ -> nil
      end)

    {transactions, compensations, on_complete, on_abort}
  end

  defp build_saga_init(step_names) do
    first_step = List.first(step_names)

    quote do
      fn ->
        %{
          status: :pending,
          current_step: unquote(first_step),
          results: %{},
          failure_reason: nil,
          compensated: [],
          step_order: unquote(step_names)
        }
      end
    end
  end

  defp build_saga_reducer_with_steps(transactions, compensations, _step_names) do
    tx_map_entries =
      Enum.map(transactions, fn {step_name, body} ->
        quote do
          {unquote(step_name), unquote(body)}
        end
      end)

    comp_map_entries =
      Enum.map(compensations, fn {step_name, body} ->
        quote do
          {unquote(step_name), unquote(body)}
        end
      end)

    quote generated: true do
      fn _input, state ->
        tx_fns = Map.new([unquote_splicing(tx_map_entries)])
        comp_fns = Map.new([unquote_splicing(comp_map_entries)])

        run_saga_steps = fn run_saga_steps, current_state ->
          case current_state.status do
            status when status in [:pending, :running] ->
              step_name = current_state.current_step

              if step_name == nil do
                current_state
              else
                tx_fn = Map.get(tx_fns, step_name)

                if tx_fn do
                  result =
                    try do
                      tx_fn.(current_state.results)
                    rescue
                      e -> {:error, e}
                    end

                  next_state =
                    case result do
                      {:ok, value} ->
                        new_results = Map.put(current_state.results, step_name, value)
                        step_order = current_state.step_order
                        current_idx = Enum.find_index(step_order, &(&1 == step_name))
                        next_idx = if current_idx, do: current_idx + 1, else: nil

                        if next_idx && next_idx < length(step_order) do
                          next_step = Enum.at(step_order, next_idx)

                          %{
                            current_state
                            | results: new_results,
                              current_step: next_step,
                              status: :running
                          }
                        else
                          %{
                            current_state
                            | results: new_results,
                              current_step: nil,
                              status: :completed
                          }
                        end

                      {:error, reason} ->
                        %{
                          current_state
                          | status: :compensating,
                            failure_reason: {step_name, reason},
                            current_step: nil
                        }

                      other ->
                        new_results = Map.put(current_state.results, step_name, other)
                        step_order = current_state.step_order
                        current_idx = Enum.find_index(step_order, &(&1 == step_name))
                        next_idx = if current_idx, do: current_idx + 1, else: nil

                        if next_idx && next_idx < length(step_order) do
                          next_step = Enum.at(step_order, next_idx)

                          %{
                            current_state
                            | results: new_results,
                              current_step: next_step,
                              status: :running
                          }
                        else
                          %{
                            current_state
                            | results: new_results,
                              current_step: nil,
                              status: :completed
                          }
                        end
                    end

                  run_saga_steps.(run_saga_steps, next_state)
                else
                  current_state
                end
              end

            :compensating ->
              completed_step_names = Map.keys(current_state.results)

              to_compensate =
                Enum.filter(completed_step_names, &(&1 not in current_state.compensated))

              compensated_state =
                Enum.reduce(to_compensate, current_state, fn sn, acc_state ->
                  comp_fn = Map.get(comp_fns, sn)

                  if comp_fn do
                    try do
                      comp_fn.(acc_state.results)
                    rescue
                      _ -> :compensation_error
                    end
                  end

                  new_compensated = [sn | acc_state.compensated]
                  all_done = Enum.all?(completed_step_names, &(&1 in new_compensated))

                  if all_done do
                    %{acc_state | compensated: new_compensated, status: :aborted}
                  else
                    %{acc_state | compensated: new_compensated}
                  end
                end)

              compensated_state

            _ ->
              current_state
          end
        end

        run_saga_steps.(run_saga_steps, state)
      end
    end
  end

  defp build_saga_accumulator(init_ast, reducer_ast, saga_name) do
    acc_hash = Components.fact_hash({init_ast, reducer_ast, saga_name})

    quote generated: true do
      %Accumulator{
        init: unquote(init_ast),
        reducer: unquote(reducer_ast),
        hash: unquote(acc_hash),
        name: :"#{unquote(saga_name)}_accumulator",
        meta_refs: []
      }
    end
  end

  defp build_saga_terminal_rules(on_complete, on_abort, saga_name) do
    rules = []

    rules =
      if on_complete do
        rules ++ [build_saga_on_complete_rule(on_complete, saga_name)]
      else
        rules
      end

    rules =
      if on_abort do
        rules ++ [build_saga_on_abort_rule(on_abort, saga_name)]
      else
        rules
      end

    quote do
      [unquote_splicing(rules)]
    end
  end

  defp build_saga_on_complete_rule(on_complete_fn, saga_name) do
    acc_ref = :__saga_accumulator__

    condition_fn =
      quote generated: true do
        fn _input ->
          saga_state = state_of(unquote(acc_ref))
          saga_state.status == :completed
        end
      end

    condition_meta_refs = detect_meta_expressions(condition_fn)
    rewritten_condition = rewrite_meta_refs_in_ast(condition_fn, condition_meta_refs)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

    final_condition =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_condition).(input)
        end
      end

    condition_hash = Components.fact_hash({condition_fn, saga_name, :on_complete})

    reaction_fn =
      quote generated: true do
        fn _input ->
          saga_state = state_of(unquote(acc_ref))
          handler = unquote(on_complete_fn)
          handler.(saga_state.results)
        end
      end

    reaction_meta_refs = detect_meta_expressions(reaction_fn)
    rewritten_reaction = rewrite_meta_refs_in_ast(reaction_fn, reaction_meta_refs)
    escaped_reaction_meta_refs = escape_meta_refs(reaction_meta_refs)

    final_reaction =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_reaction).(input)
        end
      end

    reaction_hash = Components.fact_hash({reaction_fn, saga_name, :on_complete})

    quote generated: true do
      condition =
        Condition.new(
          work: unquote(final_condition),
          hash: unquote(condition_hash),
          arity: 2,
          meta_refs: unquote(escaped_condition_meta_refs)
        )

      reaction =
        Step.new(
          work: unquote(final_reaction),
          hash: unquote(reaction_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )

      rule_name = :"#{unquote(saga_name)}_on_complete"

      rule_workflow =
        Workflow.new(rule_name)
        |> Workflow.add_step(condition)
        |> Workflow.add_step(condition, reaction)

      %Rule{
        name: rule_name,
        arity: 1,
        workflow: rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: condition.hash,
        reaction_hash: reaction.hash
      }
    end
  end

  defp build_saga_on_abort_rule(on_abort_fn, saga_name) do
    acc_ref = :__saga_accumulator__

    condition_fn =
      quote generated: true do
        fn _input ->
          saga_state = state_of(unquote(acc_ref))
          saga_state.status == :aborted
        end
      end

    condition_meta_refs = detect_meta_expressions(condition_fn)
    rewritten_condition = rewrite_meta_refs_in_ast(condition_fn, condition_meta_refs)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

    final_condition =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_condition).(input)
        end
      end

    condition_hash = Components.fact_hash({condition_fn, saga_name, :on_abort})

    reaction_fn =
      quote generated: true do
        fn _input ->
          saga_state = state_of(unquote(acc_ref))
          handler = unquote(on_abort_fn)
          handler.(saga_state.failure_reason, saga_state.compensated)
        end
      end

    reaction_meta_refs = detect_meta_expressions(reaction_fn)
    rewritten_reaction = rewrite_meta_refs_in_ast(reaction_fn, reaction_meta_refs)
    escaped_reaction_meta_refs = escape_meta_refs(reaction_meta_refs)

    final_reaction =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_reaction).(input)
        end
      end

    reaction_hash = Components.fact_hash({reaction_fn, saga_name, :on_abort})

    quote generated: true do
      condition =
        Condition.new(
          work: unquote(final_condition),
          hash: unquote(condition_hash),
          arity: 2,
          meta_refs: unquote(escaped_condition_meta_refs)
        )

      reaction =
        Step.new(
          work: unquote(final_reaction),
          hash: unquote(reaction_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )

      rule_name = :"#{unquote(saga_name)}_on_abort"

      rule_workflow =
        Workflow.new(rule_name)
        |> Workflow.add_step(condition)
        |> Workflow.add_step(condition, reaction)

      %Rule{
        name: rule_name,
        arity: 1,
        workflow: rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: condition.hash,
        reaction_hash: reaction.hash
      }
    end
  end

  defp build_saga_workflow_simple(accumulator_ast, terminal_rules_ast, saga_name) do
    quote generated: true do
      acc = unquote(accumulator_ast)
      terminal_rules = unquote(terminal_rules_ast)

      base_wrk =
        Workflow.new(unquote(saga_name))
        |> Workflow.add_step(acc)
        |> Workflow.register_component(acc)

      Enum.reduce(terminal_rules, base_wrk, fn rule, wrk ->
        condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
        reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

        wrk =
          wrk
          |> Workflow.add_step(acc, condition)
          |> Workflow.add_step(condition, reaction)
          |> Workflow.register_component(rule)

        wrk =
          Enum.reduce(condition.meta_refs || [], wrk, fn meta_ref, w ->
            Workflow.draw_meta_ref_edge(w, condition.hash, acc.hash, meta_ref)
          end)

        Enum.reduce(reaction.meta_refs || [], wrk, fn meta_ref, w ->
          Workflow.draw_meta_ref_edge(w, reaction.hash, acc.hash, meta_ref)
        end)
      end)
    end
  end

  @doc """
  Creates an `%Aggregate{}`: a CQRS/ES aggregate that validates commands against
  current state, produces domain events, and folds events into state.

  Compiles to an Accumulator (event fold) plus Rules (command handlers).

  ## Usage

      require Runic

      agg = Runic.aggregate name: :counter do
        state 0

        command :increment do
          emit fn _state -> {:incremented, 1} end
        end

        command :decrement do
          where fn state -> state > 0 end
          emit fn _state -> {:decremented, 1} end
        end

        event {:incremented, n}, state do
          state + n
        end

        event {:decremented, n}, state do
          state - n
        end
      end

  ## Options

  - `:name` - Identifier for the aggregate (required)

  ## DSL

  - `state initial_value` - Sets the initial aggregate state
  - `command :name do ... end` - Defines a command handler
    - `where fn state -> bool end` - Optional guard on current state
    - `emit fn state -> event end` - Produces domain events
  - `event pattern, state_var do body end` - Defines an event handler (reducer clause)
  """
  defmacro aggregate(opts, [{:do, block}]) when is_list(opts) do
    name = Keyword.get(opts, :name)

    unless name, do: raise(ArgumentError, "Aggregate requires a :name option")
    unless block, do: raise(ArgumentError, "Aggregate requires a do block")

    {initial_state, command_handlers, event_handlers} = parse_aggregate_block(block)

    # Strip AST metadata for deterministic hashing regardless of source location
    clean_for_hash = fn ast ->
      Macro.prewalk(ast, fn
        {name, _meta, ctx} when is_atom(name) -> {name, [], ctx}
        other -> other
      end)
    end

    clean_cmd_handlers =
      Enum.map(command_handlers, fn {n, w, e} ->
        {n, w && clean_for_hash.(w), clean_for_hash.(e)}
      end)

    clean_evt_handlers =
      Enum.map(event_handlers, fn {p, s, b} ->
        {clean_for_hash.(p), clean_for_hash.(s), clean_for_hash.(b)}
      end)

    agg_hash = Components.fact_hash({name, initial_state, clean_cmd_handlers, clean_evt_handlers})

    reducer_ast = build_aggregate_reducer(event_handlers)

    accumulator_ast = build_aggregate_accumulator(initial_state, reducer_ast, name)

    command_rules_ast = build_aggregate_command_rules(command_handlers, name)

    workflow_ast = build_aggregate_workflow(accumulator_ast, command_rules_ast, name)

    source =
      quote do
        Runic.aggregate(unquote(opts), do: unquote(Macro.escape(block)))
      end

    # Store command/event handler counts for introspection rather than raw AST
    # (raw AST contains unresolvable variable references)
    num_command_handlers = length(command_handlers)
    num_event_handlers = length(event_handlers)

    quote do
      agg_accumulator = unquote(accumulator_ast)
      agg_command_rules = unquote(command_rules_ast)

      %Aggregate{
        name: unquote(name),
        initial_state: unquote(initial_state),
        command_handlers: unquote(num_command_handlers),
        event_handlers: unquote(num_event_handlers),
        accumulator: agg_accumulator,
        command_rules: agg_command_rules,
        workflow: unquote(workflow_ast),
        source: unquote(Macro.escape(source)),
        hash: unquote(agg_hash)
      }
    end
  end

  defp parse_aggregate_block({:__block__, _, exprs}), do: parse_aggregate_exprs(exprs)
  defp parse_aggregate_block(single_expr), do: parse_aggregate_exprs([single_expr])

  defp parse_aggregate_exprs(exprs) do
    initial_state =
      Enum.find_value(exprs, fn
        {:state, _, [value]} -> value
        _ -> nil
      end)

    command_handlers =
      Enum.flat_map(exprs, fn
        {:command, _, [cmd_name, [do: cmd_block]]} ->
          [parse_command_block(cmd_name, cmd_block)]

        _ ->
          []
      end)

    event_handlers =
      Enum.flat_map(exprs, fn
        {:event, _, [pattern, state_var, [do: body]]} ->
          [{pattern, state_var, body}]

        _ ->
          []
      end)

    {initial_state, command_handlers, event_handlers}
  end

  defp parse_command_block(cmd_name, {:__block__, _, exprs}) do
    where_fn =
      Enum.find_value(exprs, fn
        {:where, _, [fn_ast]} -> fn_ast
        _ -> nil
      end)

    emit_fn =
      Enum.find_value(exprs, fn
        {:emit, _, [fn_ast]} -> fn_ast
        _ -> nil
      end) || raise(ArgumentError, "Command #{cmd_name} requires an `emit` function")

    {cmd_name, where_fn, emit_fn}
  end

  defp parse_command_block(cmd_name, {:emit, _, [fn_ast]}) do
    {cmd_name, nil, fn_ast}
  end

  defp parse_command_block(cmd_name, {:where, _, [_fn_ast]}) do
    raise ArgumentError, "Command #{cmd_name} has a `where` but no `emit` function"
  end

  defp build_aggregate_reducer(event_handlers) do
    # Build case clauses from event handler AST.
    # Each event handler has {pattern, state_var, body} where pattern and state_var
    # are raw AST nodes from the caller's context. We must reset variable contexts
    # so they're resolved in the generated code's scope, not the caller's.
    # We also normalize 2-element tuple patterns to explicit {:{}, [], [...]} form
    # to prevent Elixir from interpreting {atom, value} as keyword pairs.
    event_clauses =
      Enum.flat_map(event_handlers, fn {pattern, state_var, body} ->
        clean_pattern = pattern |> normalize_tuple_pattern() |> reset_var_context()
        clean_state_var = reset_var_context(state_var)
        clean_body = reset_var_context(body)

        clause_body =
          quote generated: true do
            unquote(clean_state_var) = current_state
            unquote(clean_body)
          end

        quote generated: true do
          unquote(clean_pattern) -> unquote(clause_body)
        end
      end)

    fallback_clause =
      quote generated: true do
        _ -> current_state
      end

    all_clauses = List.flatten(event_clauses ++ [fallback_clause])

    # Build the case AST manually because unquote_splicing inside `case do`
    # wraps multiple clauses in {:__block__, ...}, but case expects a plain list.
    # Use var! to ensure the event_value variable matches the fn parameter.
    quote generated: true do
      fn var!(event_value, Runic), current_state ->
        unquote(
          {:case, [generated: true],
           [
             {:var!, [generated: true], [{:event_value, [generated: true], nil}, Runic]},
             [do: all_clauses]
           ]}
        )
      end
    end
  end

  # Normalize 2-element tuple patterns {atom, value} to explicit {:{}, [], [atom, value]}
  # AST form to prevent Elixir from treating them as keyword pairs in case clauses.
  defp normalize_tuple_pattern({atom, value}) when is_atom(atom) do
    {:{}, [], [atom, normalize_tuple_pattern(value)]}
  end

  defp normalize_tuple_pattern(other), do: other

  # Reset variable contexts in AST to Runic so they resolve in the generated code scope
  defp reset_var_context(ast) do
    Macro.prewalk(ast, fn
      {name, meta, context} when is_atom(name) and is_atom(context) ->
        {name, Keyword.put(meta, :generated, true), Runic}

      other ->
        other
    end)
  end

  defp build_aggregate_accumulator(initial_state, reducer_ast, agg_name) do
    literal_init_ast =
      quote do
        fn -> unquote(initial_state) end
      end

    acc_hash = Components.fact_hash({literal_init_ast, reducer_ast, agg_name})

    quote generated: true do
      %Accumulator{
        init: unquote(literal_init_ast),
        reducer: unquote(reducer_ast),
        hash: unquote(acc_hash),
        name: :"#{unquote(agg_name)}_accumulator",
        meta_refs: []
      }
    end
  end

  defp build_aggregate_command_rules(command_handlers, agg_name) do
    rule_asts =
      Enum.map(command_handlers, fn {cmd_name, where_fn, emit_fn} ->
        build_aggregate_command_rule(cmd_name, where_fn, emit_fn, agg_name)
      end)

    quote do
      [unquote_splicing(rule_asts)]
    end
  end

  defp build_aggregate_command_rule(cmd_name, where_fn, emit_fn, agg_name) do
    acc_ref = :__agg_accumulator__

    condition_fn = build_aggregate_condition(cmd_name, where_fn, acc_ref)

    condition_meta_refs = detect_meta_expressions(condition_fn)
    rewritten_condition = rewrite_meta_refs_in_ast(condition_fn, condition_meta_refs)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

    # Only use arity-2 wrapper if there are actual meta_refs to resolve
    has_condition_meta_refs = condition_meta_refs != []

    final_condition =
      if has_condition_meta_refs do
        quote generated: true do
          fn input, var!(meta_ctx, Runic) ->
            _ = var!(meta_ctx, Runic)
            unquote(rewritten_condition).(input)
          end
        end
      else
        rewritten_condition
      end

    condition_arity = if has_condition_meta_refs, do: 2, else: 1

    condition_hash = Components.fact_hash({condition_fn, agg_name, cmd_name})

    reaction_fn = build_aggregate_reaction(cmd_name, emit_fn, acc_ref)

    reaction_meta_refs = detect_meta_expressions(reaction_fn)
    rewritten_reaction = rewrite_meta_refs_in_ast(reaction_fn, reaction_meta_refs)
    escaped_reaction_meta_refs = escape_meta_refs(reaction_meta_refs)

    has_reaction_meta_refs = reaction_meta_refs != []

    final_reaction =
      if has_reaction_meta_refs do
        quote generated: true do
          fn input, var!(meta_ctx, Runic) ->
            _ = var!(meta_ctx, Runic)
            unquote(rewritten_reaction).(input)
          end
        end
      else
        rewritten_reaction
      end

    reaction_hash = Components.fact_hash({reaction_fn, agg_name, cmd_name})

    rule_name =
      quote do
        :"#{unquote(agg_name)}_#{unquote(cmd_name)}"
      end

    quote generated: true do
      cmd_rule_name = unquote(rule_name)

      condition =
        Condition.new(
          work: unquote(final_condition),
          hash: unquote(condition_hash),
          arity: unquote(condition_arity),
          meta_refs: unquote(escaped_condition_meta_refs)
        )

      reaction =
        Step.new(
          work: unquote(final_reaction),
          hash: unquote(reaction_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )

      rule_workflow =
        Workflow.new(cmd_rule_name)
        |> Workflow.add_step(condition)
        |> Workflow.add_step(condition, reaction)

      %Rule{
        name: cmd_rule_name,
        arity: 1,
        workflow: rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: condition.hash,
        reaction_hash: reaction.hash
      }
    end
  end

  defp build_aggregate_condition(cmd_name, nil, _acc_ref) do
    quote generated: true do
      fn input ->
        case input do
          unquote(cmd_name) -> true
          {unquote(cmd_name), _} -> true
          _ -> false
        end
      end
    end
  end

  defp build_aggregate_condition(cmd_name, where_fn, acc_ref) do
    quote generated: true do
      fn input ->
        cmd_matches =
          case input do
            unquote(cmd_name) -> true
            {unquote(cmd_name), _} -> true
            _ -> false
          end

        if cmd_matches do
          current_state = state_of(unquote(acc_ref))
          unquote(where_fn).(current_state)
        else
          false
        end
      end
    end
  end

  defp build_aggregate_reaction(_cmd_name, emit_fn, acc_ref) do
    quote generated: true do
      fn input ->
        current_state = state_of(unquote(acc_ref))

        payload =
          case input do
            {_, p} -> p
            _ -> nil
          end

        emit_fn = unquote(emit_fn)

        case :erlang.fun_info(emit_fn, :arity) do
          {_, 1} -> emit_fn.(current_state)
          {_, 2} -> emit_fn.(current_state, payload)
          _ -> emit_fn.(current_state)
        end
      end
    end
  end

  defp build_aggregate_workflow(accumulator_ast, command_rules_ast, agg_name) do
    quote generated: true do
      acc = unquote(accumulator_ast)
      command_rules = unquote(command_rules_ast)

      # Topology:
      #   Root → Accumulator (receives input, initializes state, ignores non-events)
      #   Root → Condition → Reaction → Accumulator (command handler pipeline, events fold into state)
      # The accumulator must also be connected from root so it initializes and its state
      # is available via state_of() meta_refs for conditions and reactions.
      base_wrk =
        Workflow.new(unquote(agg_name))
        |> Workflow.add_step(acc)
        |> Workflow.register_component(acc)

      Enum.reduce(command_rules, base_wrk, fn rule, wrk ->
        condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
        reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

        wrk =
          wrk
          |> Workflow.add_step(condition)
          |> Workflow.add_step(condition, reaction)
          |> Workflow.add_step(reaction, acc)
          |> Workflow.register_component(rule)

        wrk =
          Enum.reduce(condition.meta_refs || [], wrk, fn meta_ref, w ->
            Workflow.draw_meta_ref_edge(w, condition.hash, acc.hash, meta_ref)
          end)

        Enum.reduce(reaction.meta_refs || [], wrk, fn meta_ref, w ->
          Workflow.draw_meta_ref_edge(w, reaction.hash, acc.hash, meta_ref)
        end)
      end)
    end
  end

  @doc """
  Creates a `%ProcessManager{}`: a CQRS-oriented process manager that reacts to
  domain events, maintains coordination state, and emits commands.

  Unlike Saga, ProcessManagers are event-driven and reactive rather than
  sequential. They subscribe to event patterns from multiple sources and
  decide what commands to issue based on accumulated state.

  Compiles to an Accumulator (coordination state) plus Rules (event handlers).

  ## Example

      require Runic

      pm = Runic.process_manager name: :fulfillment do
        state %{order_id: nil, paid: false, shipped: false}

        on {:order_submitted, order_id} do
          update %{order_id: order_id}
          emit {:charge_payment, order_id}
        end

        on {:payment_received, _} do
          update %{paid: true}
        end

        on {:shipment_created, _} do
          update %{shipped: true}
        end

        complete? fn state -> state.shipped end
      end

  ## DSL

  - `state initial_value` - Sets the initial process manager state
  - `on event_pattern do ... end` - Defines an event handler
    - `update map` - Merges updates into the process state
    - `emit value` - Produces a command fact as output
  - `complete? fn state -> bool end` - Completion check (fires when state satisfies predicate)
  - `timeout :name, duration do ... end` - Declares a timeout (scheduling is the Runner's responsibility)

  ## Options

  - `:name` - Identifier for the process manager (required)
  """
  defmacro process_manager(opts, [{:do, block}]) when is_list(opts) do
    name = Keyword.get(opts, :name)
    inputs = Keyword.get(opts, :inputs)
    outputs = Keyword.get(opts, :outputs)

    unless name, do: raise(ArgumentError, "ProcessManager requires a :name option")
    unless block, do: raise(ArgumentError, "ProcessManager requires a do block")

    {initial_state, event_handlers, timeout_handlers, completion_check} =
      parse_pm_block(block)

    unless initial_state do
      raise ArgumentError, "ProcessManager #{inspect(name)} requires a `state` declaration"
    end

    # Build deterministic hash from structural properties only (not raw AST)
    # Strip AST metadata from initial_state for deterministic hashing
    clean_initial_state =
      Macro.prewalk(initial_state, fn
        {name, _meta, ctx} when is_atom(name) -> {name, [], ctx}
        other -> other
      end)

    handler_signatures =
      event_handlers
      |> Enum.with_index()
      |> Enum.map(fn {{_pattern, updates, emits}, idx} ->
        {idx, length(updates), length(emits)}
      end)

    pm_hash =
      Components.fact_hash(
        {name, clean_initial_state, handler_signatures, length(timeout_handlers),
         completion_check != nil}
      )

    accumulator_ast = build_pm_accumulator(initial_state, event_handlers, name)
    event_rules_ast = build_pm_event_rules(event_handlers, name)
    completion_rule_ast = build_pm_completion_rule(completion_check, name)
    workflow_ast = build_pm_workflow(accumulator_ast, event_rules_ast, completion_rule_ast, name)

    source =
      quote do
        Runic.process_manager(unquote(opts), do: unquote(Macro.escape(block)))
      end

    num_event_handlers = length(event_handlers)
    num_timeout_handlers = length(timeout_handlers)

    quote do
      pm_accumulator = unquote(accumulator_ast)
      pm_event_rules = unquote(event_rules_ast)
      pm_completion_rule = unquote(completion_rule_ast)

      %ProcessManager{
        name: unquote(name),
        initial_state: unquote(Macro.escape(initial_state)),
        event_handlers: unquote(num_event_handlers),
        timeout_handlers: unquote(num_timeout_handlers),
        completion_check: unquote(completion_check != nil),
        accumulator: pm_accumulator,
        event_rules: pm_event_rules,
        completion_rule: pm_completion_rule,
        workflow: unquote(workflow_ast),
        source: unquote(Macro.escape(source)),
        hash: unquote(pm_hash),
        inputs: unquote(inputs),
        outputs: unquote(outputs)
      }
    end
  end

  defp parse_pm_block({:__block__, _, exprs}), do: parse_pm_exprs(exprs)
  defp parse_pm_block(single_expr), do: parse_pm_exprs([single_expr])

  defp parse_pm_exprs(exprs) do
    initial_state =
      Enum.find_value(exprs, fn
        {:state, _, [value]} -> value
        _ -> nil
      end)

    event_handlers =
      Enum.flat_map(exprs, fn
        {:on, _, [pattern, [do: handler_block]]} ->
          [
            {pattern, parse_pm_handler_updates(handler_block),
             parse_pm_handler_emits(handler_block)}
          ]

        _ ->
          []
      end)

    timeout_handlers =
      Enum.flat_map(exprs, fn
        {:timeout, _, [timeout_name, duration, [do: handler_block]]} ->
          [{timeout_name, duration, handler_block}]

        _ ->
          []
      end)

    completion_check =
      Enum.find_value(exprs, fn
        {:complete?, _, [fn_ast]} -> fn_ast
        _ -> nil
      end)

    {initial_state, event_handlers, timeout_handlers, completion_check}
  end

  defp parse_pm_handler_updates({:__block__, _, exprs}) do
    Enum.flat_map(exprs, fn
      {:update, _, [update_map]} -> [update_map]
      _ -> []
    end)
  end

  defp parse_pm_handler_updates({:update, _, [update_map]}), do: [update_map]
  defp parse_pm_handler_updates(_), do: []

  defp parse_pm_handler_emits({:__block__, _, exprs}) do
    Enum.flat_map(exprs, fn
      {:emit, _, [value]} -> [value]
      _ -> []
    end)
  end

  defp parse_pm_handler_emits({:emit, _, [value]}), do: [value]
  defp parse_pm_handler_emits(_), do: []

  # Build the accumulator for ProcessManager.
  # The reducer merges update maps into state and handles timeout events.
  defp build_pm_accumulator(initial_state, event_handlers, pm_name) do
    # Build case clauses for each event handler's pattern → state update
    event_clauses =
      Enum.flat_map(event_handlers, fn {pattern, updates, _emits} ->
        clean_pattern = pattern |> normalize_tuple_pattern() |> reset_var_context()

        if updates == [] do
          # No state update for this event — just pass through
          []
        else
          # Merge all updates into state
          merged_update =
            case updates do
              [single] ->
                reset_var_context(single)

              multiple ->
                raise ArgumentError,
                      "ProcessManager event handler should have at most one `update` call, got #{length(multiple)}"
            end

          clause_body =
            quote generated: true do
              Map.merge(current_state, unquote(merged_update))
            end

          quote generated: true do
            unquote(clean_pattern) -> unquote(clause_body)
          end
        end
      end)

    fallback_clause =
      quote generated: true do
        _ -> current_state
      end

    all_clauses = List.flatten(event_clauses ++ [fallback_clause])

    reducer_ast =
      quote generated: true do
        fn var!(event_value, Runic), current_state ->
          unquote(
            {:case, [generated: true],
             [
               {:var!, [generated: true], [{:event_value, [generated: true], nil}, Runic]},
               [do: all_clauses]
             ]}
          )
        end
      end

    literal_init_ast =
      quote do
        fn -> unquote(initial_state) end
      end

    acc_hash = Components.fact_hash({literal_init_ast, reducer_ast, pm_name})

    quote generated: true do
      %Accumulator{
        init: unquote(literal_init_ast),
        reducer: unquote(reducer_ast),
        hash: unquote(acc_hash),
        name: :"#{unquote(pm_name)}_accumulator",
        meta_refs: []
      }
    end
  end

  # Build event handler rules for ProcessManager.
  # Each `on` block with an `emit` compiles to a Rule that matches the event pattern
  # and produces command facts.
  defp build_pm_event_rules(event_handlers, pm_name) do
    rule_asts =
      event_handlers
      |> Enum.with_index()
      |> Enum.flat_map(fn {{pattern, _updates, emits}, idx} ->
        if emits == [] do
          # No commands to emit — no rule needed (state update is handled by accumulator)
          []
        else
          [build_pm_event_rule(pattern, emits, pm_name, idx)]
        end
      end)

    quote do
      [unquote_splicing(rule_asts)]
    end
  end

  defp build_pm_event_rule(pattern, emits, pm_name, idx) do
    acc_ref = :__pm_accumulator__
    rule_name = :"#{pm_name}_on_#{idx}"

    clean_pattern = pattern |> normalize_tuple_pattern() |> reset_var_context()

    # Condition: match the event pattern
    condition_fn =
      quote generated: true do
        fn input ->
          case input do
            unquote(clean_pattern) -> true
            _ -> false
          end
        end
      end

    condition_hash = Components.fact_hash({condition_fn, pm_name, idx})

    # Reaction: emit commands. Use state_of() for state access in emit expressions.
    emit_values =
      case emits do
        [single] ->
          reset_var_context(single)

        multiple ->
          # Multiple emits produce a list
          reset_var_context(multiple)
      end

    # Check if any emit references state_of()
    reaction_fn =
      quote generated: true do
        fn _input ->
          _pm_state = state_of(unquote(acc_ref))
          unquote(emit_values)
        end
      end

    reaction_meta_refs = detect_meta_expressions(reaction_fn)
    rewritten_reaction = rewrite_meta_refs_in_ast(reaction_fn, reaction_meta_refs)
    escaped_reaction_meta_refs = escape_meta_refs(reaction_meta_refs)

    final_reaction =
      if reaction_meta_refs != [] do
        quote generated: true do
          fn input, var!(meta_ctx, Runic) ->
            _ = var!(meta_ctx, Runic)
            unquote(rewritten_reaction).(input)
          end
        end
      else
        quote generated: true do
          fn input ->
            unquote(rewritten_reaction).(input)
          end
        end
      end

    reaction_hash = Components.fact_hash({reaction_fn, pm_name, idx, :reaction})

    quote generated: true do
      condition =
        Condition.new(
          work: unquote(condition_fn),
          hash: unquote(condition_hash),
          arity: 1,
          meta_refs: []
        )

      reaction =
        Step.new(
          work: unquote(final_reaction),
          hash: unquote(reaction_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )

      rule_workflow =
        Workflow.new(unquote(rule_name))
        |> Workflow.add_step(condition)
        |> Workflow.add_step(condition, reaction)

      %Rule{
        name: unquote(rule_name),
        arity: 1,
        workflow: rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: condition.hash,
        reaction_hash: reaction.hash
      }
    end
  end

  # Build completion rule for ProcessManager.
  # Fires when the completion check function returns true for the current state.
  defp build_pm_completion_rule(nil, _pm_name) do
    quote do: nil
  end

  defp build_pm_completion_rule(completion_fn, pm_name) do
    acc_ref = :__pm_accumulator__

    condition_fn =
      quote generated: true do
        fn _input ->
          pm_state = state_of(unquote(acc_ref))
          check = unquote(completion_fn)
          check.(pm_state)
        end
      end

    condition_meta_refs = detect_meta_expressions(condition_fn)
    rewritten_condition = rewrite_meta_refs_in_ast(condition_fn, condition_meta_refs)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

    final_condition =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_condition).(input)
        end
      end

    condition_hash = Components.fact_hash({condition_fn, pm_name, :complete})

    reaction_fn =
      quote generated: true do
        fn _input ->
          {:process_completed, unquote(pm_name)}
        end
      end

    reaction_hash = Components.fact_hash({reaction_fn, pm_name, :complete_reaction})

    quote generated: true do
      condition =
        Condition.new(
          work: unquote(final_condition),
          hash: unquote(condition_hash),
          arity: 2,
          meta_refs: unquote(escaped_condition_meta_refs)
        )

      reaction =
        Step.new(
          work: unquote(reaction_fn),
          hash: unquote(reaction_hash),
          meta_refs: []
        )

      rule_name = :"#{unquote(pm_name)}_complete"

      rule_workflow =
        Workflow.new(rule_name)
        |> Workflow.add_step(condition)
        |> Workflow.add_step(condition, reaction)

      %Rule{
        name: rule_name,
        arity: 1,
        workflow: rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: condition.hash,
        reaction_hash: reaction.hash
      }
    end
  end

  defp build_pm_workflow(accumulator_ast, event_rules_ast, completion_rule_ast, pm_name) do
    quote generated: true do
      acc = unquote(accumulator_ast)
      event_rules = unquote(event_rules_ast)
      completion_rule = unquote(completion_rule_ast)

      base_wrk =
        Workflow.new(unquote(pm_name))
        |> Workflow.add_step(acc)
        |> Workflow.register_component(acc)

      # Wire event handler rules: conditions receive events from root,
      # reactions produce commands as output facts
      wrk =
        Enum.reduce(event_rules, base_wrk, fn rule, wrk ->
          condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
          reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

          wrk =
            wrk
            |> Workflow.add_step(condition)
            |> Workflow.add_step(condition, reaction)
            |> Workflow.register_component(rule)

          wrk =
            Enum.reduce(condition.meta_refs || [], wrk, fn meta_ref, w ->
              Workflow.draw_meta_ref_edge(w, condition.hash, acc.hash, meta_ref)
            end)

          Enum.reduce(reaction.meta_refs || [], wrk, fn meta_ref, w ->
            Workflow.draw_meta_ref_edge(w, reaction.hash, acc.hash, meta_ref)
          end)
        end)

      # Wire completion rule if present
      if completion_rule do
        condition =
          Map.get(completion_rule.workflow.graph.vertices, completion_rule.condition_hash)

        reaction = Map.get(completion_rule.workflow.graph.vertices, completion_rule.reaction_hash)

        wrk =
          wrk
          |> Workflow.add_step(acc, condition)
          |> Workflow.add_step(condition, reaction)
          |> Workflow.register_component(completion_rule)

        wrk =
          Enum.reduce(condition.meta_refs || [], wrk, fn meta_ref, w ->
            Workflow.draw_meta_ref_edge(w, condition.hash, acc.hash, meta_ref)
          end)

        Enum.reduce(reaction.meta_refs || [], wrk, fn meta_ref, w ->
          Workflow.draw_meta_ref_edge(w, reaction.hash, acc.hash, meta_ref)
        end)
      else
        wrk
      end
    end
  end

  @doc """
  Creates a `%FSM{}`: a finite state machine with discrete states and guarded transitions.

  FSMs compile to an Accumulator (holding the current state atom) plus Rules
  (one per transition, using `state_of()` to gate on current state). Entry actions
  are additional rules that fire on state changes.

  ## Example

      require Runic

      fsm = Runic.fsm name: :traffic_light do
        initial_state :red

        state :red do
          on :timer, to: :green
          on :emergency, to: :red
          on_entry fn -> {:notify, :traffic_stopped} end
        end

        state :green do
          on :timer, to: :yellow
          on :emergency, to: :red
        end

        state :yellow do
          on :timer, to: :red
          on :emergency, to: :red
        end
      end

  Each transition compiles to a named Rule: `:"fsm_name_from_state_on_event"`.
  """
  defmacro fsm(opts \\ [], do: block) do
    {name, opts_rest} = Keyword.pop(opts, :name)
    inputs = Keyword.get(opts_rest, :inputs)
    outputs = Keyword.get(opts_rest, :outputs)

    {initial_state, states} = parse_fsm_block(block)

    state_names = Enum.map(states, fn {name, _} -> name end)

    validate_fsm!(initial_state, states, state_names)

    fsm_name = name || :"fsm_#{Components.fact_hash({initial_state, states})}"

    fsm_hash = Components.fact_hash({initial_state, states})

    accumulator_ast = build_fsm_accumulator(initial_state, fsm_name)

    transition_rules_ast = build_fsm_transition_rules(states, fsm_name)

    entry_rules_ast = build_fsm_entry_rules(states, fsm_name)

    workflow_ast =
      build_fsm_workflow(accumulator_ast, transition_rules_ast, entry_rules_ast, fsm_name)

    states_map = Macro.escape(Map.new(states))

    source =
      quote do
        Runic.fsm(unquote(opts), do: unquote(Macro.escape(block)))
      end

    quote do
      fsm_accumulator = unquote(accumulator_ast)
      fsm_transition_rules = unquote(transition_rules_ast)
      fsm_entry_rules = unquote(entry_rules_ast)

      %FSM{
        name: unquote(fsm_name),
        initial_state: unquote(initial_state),
        states: unquote(states_map),
        accumulator: fsm_accumulator,
        transition_rules: fsm_transition_rules,
        entry_rules: fsm_entry_rules,
        workflow: unquote(workflow_ast),
        source: unquote(Macro.escape(source)),
        hash: unquote(fsm_hash),
        inputs: unquote(inputs),
        outputs: unquote(outputs)
      }
    end
  end

  defp parse_fsm_block({:__block__, _, exprs}) do
    parse_fsm_exprs(exprs)
  end

  defp parse_fsm_block(single_expr) do
    parse_fsm_exprs([single_expr])
  end

  defp parse_fsm_exprs(exprs) do
    initial_state =
      Enum.find_value(exprs, fn
        {:initial_state, _, [state]} when is_atom(state) -> state
        _ -> nil
      end)

    states =
      Enum.flat_map(exprs, fn
        {:state, _, [state_name, [do: state_block]]} when is_atom(state_name) ->
          [{state_name, parse_state_block(state_block)}]

        {:state, _, [state_name]} when is_atom(state_name) ->
          [{state_name, %{transitions: [], on_entry: nil}}]

        _ ->
          []
      end)

    {initial_state, states}
  end

  defp parse_state_block({:__block__, _, exprs}) do
    parse_state_exprs(exprs)
  end

  defp parse_state_block(single_expr) do
    parse_state_exprs([single_expr])
  end

  defp parse_state_exprs(exprs) do
    transitions =
      Enum.flat_map(exprs, fn
        {:on, _, [event, opts]} when is_atom(event) and is_list(opts) ->
          target = Keyword.fetch!(opts, :to)
          guard = Keyword.get(opts, :guard)
          [{event, target, guard}]

        _ ->
          []
      end)

    on_entry =
      Enum.find_value(exprs, fn
        {:on_entry, _, [fn_ast]} -> fn_ast
        _ -> nil
      end)

    %{transitions: transitions, on_entry: on_entry}
  end

  defp validate_fsm!(initial_state, states, state_names) do
    unless initial_state do
      raise ArgumentError, "FSM requires an initial_state declaration"
    end

    unless initial_state in state_names do
      raise ArgumentError,
            "initial_state #{inspect(initial_state)} is not a declared state. Declared states: #{inspect(state_names)}"
    end

    for {state_name, %{transitions: transitions}} <- states,
        {_event, target, _guard} <- transitions do
      unless target in state_names do
        raise ArgumentError,
              "transition target #{inspect(target)} from state #{inspect(state_name)} is not a declared state. Declared states: #{inspect(state_names)}"
      end
    end

    seen = MapSet.new()

    Enum.reduce(states, seen, fn {state_name, %{transitions: transitions}}, seen ->
      Enum.reduce(transitions, seen, fn {event, _target, _guard}, seen ->
        key = {state_name, event}

        if MapSet.member?(seen, key) do
          raise ArgumentError,
                "Duplicate transition: state #{inspect(state_name)} already has a transition for event #{inspect(event)}"
        end

        MapSet.put(seen, key)
      end)
    end)

    :ok
  end

  defp build_fsm_accumulator(initial_state, fsm_name) do
    init_ast =
      quote do
        fn -> unquote(initial_state) end
      end

    reducer_ast =
      quote do
        fn
          {_event, target_state}, _current_state -> target_state
          _other, current_state -> current_state
        end
      end

    acc_hash = Components.fact_hash({init_ast, reducer_ast, fsm_name})

    quote generated: true do
      %Accumulator{
        init: unquote(init_ast),
        reducer: unquote(reducer_ast),
        hash: unquote(acc_hash),
        name: :"#{unquote(fsm_name)}_accumulator",
        meta_refs: []
      }
    end
  end

  defp build_fsm_transition_rules(states, fsm_name) do
    rule_asts =
      Enum.flat_map(states, fn {from_state, %{transitions: transitions}} ->
        Enum.map(transitions, fn {event, target, guard} ->
          build_fsm_transition_rule(from_state, event, target, guard, fsm_name)
        end)
      end)

    quote do
      [unquote_splicing(rule_asts)]
    end
  end

  defp build_fsm_transition_rule(from_state, event, target, guard, fsm_name) do
    acc_ref = :__fsm_accumulator__
    rule_name = :"#{fsm_name}_#{from_state}_on_#{event}"

    condition_fn =
      if guard do
        quote generated: true do
          fn input ->
            state_of(unquote(acc_ref)) == unquote(from_state) and
              input == unquote(event) and
              unquote(guard).(input)
          end
        end
      else
        quote generated: true do
          fn input ->
            state_of(unquote(acc_ref)) == unquote(from_state) and
              input == unquote(event)
          end
        end
      end

    condition_meta_refs = detect_meta_expressions(condition_fn)
    rewritten_condition = rewrite_meta_refs_in_ast(condition_fn, condition_meta_refs)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

    final_condition =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_condition).(input)
        end
      end

    condition_hash = Components.fact_hash({condition_fn, fsm_name, from_state, event})

    reaction_fn =
      quote generated: true do
        fn _input -> {unquote(event), unquote(target)} end
      end

    reaction_hash = Components.fact_hash({reaction_fn, fsm_name, from_state, event, target})

    quote generated: true do
      condition =
        Condition.new(
          work: unquote(final_condition),
          hash: unquote(condition_hash),
          arity: 2,
          meta_refs: unquote(escaped_condition_meta_refs)
        )

      reaction =
        Step.new(
          work: unquote(reaction_fn),
          hash: unquote(reaction_hash),
          meta_refs: []
        )

      rule_workflow =
        Workflow.new(unquote(rule_name))
        |> Workflow.add_step(condition)
        |> Workflow.add_step(condition, reaction)

      %Rule{
        name: unquote(rule_name),
        arity: 1,
        workflow: rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: condition.hash,
        reaction_hash: reaction.hash
      }
    end
  end

  defp build_fsm_entry_rules(states, fsm_name) do
    entry_asts =
      states
      |> Enum.filter(fn {_name, %{on_entry: on_entry}} -> on_entry != nil end)
      |> Enum.map(fn {state_name, %{on_entry: on_entry_fn}} ->
        build_fsm_entry_rule(state_name, on_entry_fn, fsm_name)
      end)

    quote do
      [unquote_splicing(entry_asts)]
    end
  end

  defp build_fsm_entry_rule(state_name, on_entry_fn, fsm_name) do
    acc_ref = :__fsm_accumulator__
    rule_name = :"#{fsm_name}_#{state_name}_entry"

    condition_fn =
      quote generated: true do
        fn _input ->
          state_of(unquote(acc_ref)) == unquote(state_name)
        end
      end

    condition_meta_refs = detect_meta_expressions(condition_fn)
    rewritten_condition = rewrite_meta_refs_in_ast(condition_fn, condition_meta_refs)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

    final_condition =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_condition).(input)
        end
      end

    condition_hash = Components.fact_hash({condition_fn, fsm_name, state_name, :entry})

    reaction_fn =
      quote generated: true do
        fn _input -> unquote(on_entry_fn).() end
      end

    reaction_hash = Components.fact_hash({on_entry_fn, fsm_name, state_name, :entry_reaction})

    quote generated: true do
      entry_condition =
        Condition.new(
          work: unquote(final_condition),
          hash: unquote(condition_hash),
          arity: 2,
          meta_refs: unquote(escaped_condition_meta_refs)
        )

      entry_reaction =
        Step.new(
          work: unquote(reaction_fn),
          hash: unquote(reaction_hash),
          meta_refs: []
        )

      entry_rule_workflow =
        Workflow.new(unquote(rule_name))
        |> Workflow.add_step(entry_condition)
        |> Workflow.add_step(entry_condition, entry_reaction)

      %Rule{
        name: unquote(rule_name),
        arity: 1,
        workflow: entry_rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: entry_condition.hash,
        reaction_hash: entry_reaction.hash
      }
    end
  end

  defp build_fsm_workflow(accumulator_ast, transition_rules_ast, entry_rules_ast, fsm_name) do
    quote generated: true do
      acc = unquote(accumulator_ast)
      transition_rules = unquote(transition_rules_ast)
      entry_rules = unquote(entry_rules_ast)

      base_wrk =
        Workflow.new(unquote(fsm_name))
        |> Workflow.add_step(acc)
        |> Workflow.register_component(acc)

      wrk =
        Enum.reduce(transition_rules, base_wrk, fn rule, wrk ->
          condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
          reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

          wrk =
            wrk
            |> Workflow.add_step(condition)
            |> Workflow.add_step(condition, reaction)
            |> Workflow.add_step(reaction, acc)
            |> Workflow.register_component(rule)

          wrk =
            Enum.reduce(condition.meta_refs || [], wrk, fn meta_ref, w ->
              Workflow.draw_meta_ref_edge(w, condition.hash, acc.hash, meta_ref)
            end)

          Enum.reduce(reaction.meta_refs || [], wrk, fn meta_ref, w ->
            Workflow.draw_meta_ref_edge(w, reaction.hash, acc.hash, meta_ref)
          end)
        end)

      Enum.reduce(entry_rules, wrk, fn rule, wrk ->
        condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
        reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

        wrk =
          wrk
          |> Workflow.add_step(acc, condition)
          |> Workflow.add_step(condition, reaction)
          |> Workflow.register_component(rule)

        wrk =
          Enum.reduce(condition.meta_refs || [], wrk, fn meta_ref, w ->
            Workflow.draw_meta_ref_edge(w, condition.hash, acc.hash, meta_ref)
          end)

        Enum.reduce(reaction.meta_refs || [], wrk, fn meta_ref, w ->
          Workflow.draw_meta_ref_edge(w, reaction.hash, acc.hash, meta_ref)
        end)
      end)
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

    # Detect context/1 meta expressions and rewrite if found
    {final_reducer, meta_refs} =
      maybe_compile_meta_reducer(reducer_fun, rewritten_reducer_fun, __CALLER__)

    escaped_meta_refs = escape_meta_refs(meta_refs)

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
            reducer: unquote(final_reducer),
            hash: unquote(fan_in_hash),
            name: unquote(reduce_name),
            meta_refs: unquote(escaped_meta_refs)
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
            reducer: unquote(final_reducer),
            hash: fan_in_hash,
            name: reduce_name,
            meta_refs: unquote(escaped_meta_refs)
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

    # Detect context/1 meta expressions and rewrite if found
    {final_reducer, meta_refs} =
      maybe_compile_meta_reducer(reducer_fun, rewritten_reducer_fun, __CALLER__)

    escaped_meta_refs = escape_meta_refs(meta_refs)

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
          reducer: unquote(final_reducer),
          hash: unquote(accumulator_hash),
          reduce_hash: unquote(reduce_hash),
          closure: unquote(closure),
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs]),
          meta_refs: unquote(escaped_meta_refs)
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
          reducer: unquote(final_reducer),
          hash: accumulator_hash,
          reduce_hash: reduce_hash,
          closure: closure,
          inputs: unquote(rewritten_opts[:inputs]),
          outputs: unquote(rewritten_opts[:outputs]),
          meta_refs: unquote(escaped_meta_refs)
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

  @doc """
  References an external runtime value by key inside Runic macros.

  Used inside `step`, `condition`, `rule`, `accumulator`, `map`, and `reduce`
  macros to declare a dependency on a value provided via `Workflow.put_run_context/2`
  or the `:run_context` option on `react_until_satisfied/3`.

  Values are scoped by component name and resolved during the prepare phase.
  The `_global` key in `run_context` is merged into every component's context.

  Resolves to `nil` when the key is not present in `run_context`.
  Use `context/2` to provide a default instead.

  ## Examples

      require Runic
      alias Runic.Workflow

      step = Runic.step(fn _x -> context(:api_key) end, name: :call_llm)

      rule =
        Runic.rule name: :gated do
          given(val: v)
          where(v > context(:threshold))
          then(fn %{val: v} -> {:ok, v} end)
        end

      acc = Runic.accumulator(0, fn x, s -> s + x * context(:factor) end, name: :scaled)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{call_llm: %{api_key: "sk-..."}})

  Dot access is supported for map-valued context keys:

      Runic.step(fn x -> x + context(:config).pool_size end, name: :pooled)
  """
  def context(key), do: doc!([key])

  @doc """
  References an external runtime value by key with a default fallback.

  Behaves like `context/1` but uses the provided default when the key is not
  present in `run_context`. The default can be a literal value or a zero-arity
  function that is called lazily when needed.

  Keys with defaults are not reported as missing by `Workflow.validate_run_context/2`
  and appear as `{:optional, default}` in `Workflow.required_context_keys/1`.

  Defaults are embedded in the compiled closure and participate in content
  hashing — two components with different defaults produce different hashes.

  ## Examples

      require Runic

      # Literal default
      step = Runic.step(fn _x -> context(:model, default: "gpt-4") end, name: :call_llm)

      # Function default — called lazily when key is missing
      step = Runic.step(
        fn _x -> context(:api_key, default: fn -> System.get_env("API_KEY") end) end,
        name: :call_llm
      )

      # In rule where clauses
      rule =
        Runic.rule name: :default_rule do
          given(val: v)
          where(v > context(:threshold, default: 100))
          then(fn %{val: v} -> {:over, v} end)
        end

      # In accumulator reducers
      acc = Runic.accumulator(0, fn x, s -> s + x * context(:factor, default: 1) end,
        name: :scaled
      )
  """
  def context(key, opts), do: doc!([key, opts])

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

  # =============================================================================
  # StateMachine Compilation Helpers
  # =============================================================================

  defp build_state_machine_accumulator({:fn, _, _} = init, reducer, sm_name, meta_refs) do
    acc_hash = Components.fact_hash({init, reducer, sm_name})

    quote generated: true do
      %Accumulator{
        init: unquote(init),
        reducer: unquote(reducer),
        hash: unquote(acc_hash),
        name: :"#{unquote(sm_name)}_accumulator",
        meta_refs: unquote(meta_refs)
      }
    end
  end

  defp build_state_machine_accumulator({:&, _, _} = init, reducer, sm_name, meta_refs) do
    acc_hash = Components.fact_hash({init, reducer, sm_name})

    quote generated: true do
      %Accumulator{
        init: unquote(init),
        reducer: unquote(reducer),
        hash: unquote(acc_hash),
        name: :"#{unquote(sm_name)}_accumulator",
        meta_refs: unquote(meta_refs)
      }
    end
  end

  defp build_state_machine_accumulator({:{}, _, _} = init, reducer, sm_name, meta_refs) do
    init_fun =
      quote do
        {m, f, a} = unquote(init)
        Function.capture(m, f, a)
      end

    acc_hash = Components.fact_hash({init, reducer, sm_name})

    quote generated: true do
      %Accumulator{
        init: unquote(init_fun),
        reducer: unquote(reducer),
        hash: unquote(acc_hash),
        name: :"#{unquote(sm_name)}_accumulator",
        meta_refs: unquote(meta_refs)
      }
    end
  end

  defp build_state_machine_accumulator(literal_init, reducer, sm_name, meta_refs) do
    literal_init_ast =
      quote do
        fn -> unquote(literal_init) end
      end

    acc_hash = Components.fact_hash({literal_init_ast, reducer, sm_name})

    quote generated: true do
      %Accumulator{
        init: unquote(literal_init_ast),
        reducer: unquote(reducer),
        hash: unquote(acc_hash),
        name: :"#{unquote(sm_name)}_accumulator",
        meta_refs: unquote(meta_refs)
      }
    end
  end

  defp build_reactor_rules(nil, _sm_name, _env), do: quote(do: [])

  defp build_reactor_rules(reactors, sm_name, env) when is_list(reactors) do
    reactor_asts =
      reactors
      |> Enum.with_index()
      |> Enum.map(fn
        # Named reactor: {name, fn ... end}
        {{name, reactor_fn}, _idx} when is_atom(name) ->
          build_single_reactor_rule(reactor_fn, sm_name, name, env)

        # Unnamed reactor: fn ... end
        {reactor_fn, idx} ->
          build_single_reactor_rule(reactor_fn, sm_name, idx, env)
      end)

    quote do
      [unquote_splicing(reactor_asts)]
    end
  end

  defp build_single_reactor_rule(
         {:fn, _, [{:->, _, [[lhs], rhs]}]},
         sm_name,
         rule_name_or_idx,
         _env
       ) do
    # Use a placeholder atom for state_of target; at connect time, the meta_ref
    # edges will resolve by the accumulator's actual name
    acc_ref = :__sm_accumulator__

    # Build condition: check state_of(accumulator) matches the reactor's pattern
    condition_fn =
      quote generated: true do
        fn _input ->
          case state_of(unquote(acc_ref)) do
            unquote(lhs) -> true
            _ -> false
          end
        end
      end

    # Detect meta expressions in the condition (state_of)
    condition_meta_refs = detect_meta_expressions(condition_fn)
    rewritten_condition = rewrite_meta_refs_in_ast(condition_fn, condition_meta_refs)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

    # Wrap condition to be arity-2 (input, meta_ctx)
    final_condition =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_condition).(input)
        end
      end

    condition_hash = Components.fact_hash({condition_fn, sm_name})

    # Build reaction: run the reactor function with state
    reaction_fn =
      quote generated: true do
        fn _input ->
          case state_of(unquote(acc_ref)) do
            unquote(lhs) -> unquote(rhs)
            _ -> nil
          end
        end
      end

    # Detect meta expressions in the reaction (state_of)
    reaction_meta_refs = detect_meta_expressions(reaction_fn)
    rewritten_reaction = rewrite_meta_refs_in_ast(reaction_fn, reaction_meta_refs)
    escaped_reaction_meta_refs = escape_meta_refs(reaction_meta_refs)

    # Wrap reaction to be arity-2 (input, meta_ctx)
    final_reaction =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_reaction).(input)
        end
      end

    reaction_hash = Components.fact_hash({reaction_fn, sm_name})

    # Build the rule name: atom if given, or derive from sm_name at runtime
    rule_name_ast = reactor_rule_name_ast(sm_name, rule_name_or_idx)

    # Build condition and step, then assemble rule
    quote generated: true do
      sm_rule_name = unquote(rule_name_ast)

      condition =
        Condition.new(
          work: unquote(final_condition),
          hash: unquote(condition_hash),
          arity: 2,
          meta_refs: unquote(escaped_condition_meta_refs)
        )

      reaction =
        Step.new(
          work: unquote(final_reaction),
          hash: unquote(reaction_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )

      rule_workflow =
        Workflow.new(sm_rule_name)
        |> Workflow.add_step(condition)
        |> Workflow.add_step(condition, reaction)

      %Rule{
        name: sm_rule_name,
        arity: 1,
        workflow: rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: condition.hash,
        reaction_hash: reaction.hash
      }
    end
  end

  # Handle multi-clause reactor fns
  defp build_single_reactor_rule({:fn, _, clauses}, sm_name, rule_name_or_idx, _env)
       when length(clauses) > 1 do
    acc_ref = :__sm_accumulator__

    # Build a condition that checks if any clause matches
    match_clauses =
      Enum.map(clauses, fn {:->, _, [[lhs], _rhs]} ->
        quote generated: true do
          unquote(lhs) -> true
        end
      end)

    fallback_clause =
      quote generated: true do
        _ -> false
      end

    all_clauses = List.flatten(match_clauses) ++ [fallback_clause]

    condition_fn =
      quote generated: true do
        fn _input ->
          case state_of(unquote(acc_ref)) do
            (unquote_splicing(all_clauses))
          end
        end
      end

    condition_meta_refs = detect_meta_expressions(condition_fn)
    rewritten_condition = rewrite_meta_refs_in_ast(condition_fn, condition_meta_refs)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

    final_condition =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_condition).(input)
        end
      end

    condition_hash = Components.fact_hash({condition_fn, sm_name})

    # Build reaction clauses
    reaction_clauses =
      Enum.map(clauses, fn {:->, _, [[lhs], rhs]} ->
        quote generated: true do
          unquote(lhs) -> unquote(rhs)
        end
      end)

    reaction_fallback =
      quote generated: true do
        _ -> {:error, :no_match_of_lhs_in_reactor_fn}
      end

    all_reaction_clauses = List.flatten(reaction_clauses) ++ [reaction_fallback]

    reaction_fn =
      quote generated: true do
        fn _input ->
          case state_of(unquote(acc_ref)) do
            (unquote_splicing(all_reaction_clauses))
          end
        end
      end

    reaction_meta_refs = detect_meta_expressions(reaction_fn)
    rewritten_reaction = rewrite_meta_refs_in_ast(reaction_fn, reaction_meta_refs)
    escaped_reaction_meta_refs = escape_meta_refs(reaction_meta_refs)

    final_reaction =
      quote generated: true do
        fn input, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten_reaction).(input)
        end
      end

    reaction_hash = Components.fact_hash({reaction_fn, sm_name})

    rule_name_ast = reactor_rule_name_ast(sm_name, rule_name_or_idx)

    quote generated: true do
      sm_rule_name = unquote(rule_name_ast)

      condition =
        Condition.new(
          work: unquote(final_condition),
          hash: unquote(condition_hash),
          arity: 2,
          meta_refs: unquote(escaped_condition_meta_refs)
        )

      reaction =
        Step.new(
          work: unquote(final_reaction),
          hash: unquote(reaction_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )

      rule_workflow =
        Workflow.new(sm_rule_name)
        |> Workflow.add_step(condition)
        |> Workflow.add_step(condition, reaction)

      %Rule{
        name: sm_rule_name,
        arity: 1,
        workflow: rule_workflow,
        hash: Components.fact_hash({unquote(condition_hash), unquote(reaction_hash)}),
        condition_hash: condition.hash,
        reaction_hash: reaction.hash
      }
    end
  end

  # Generates the rule name AST. If rule_name_or_idx is an atom, use it directly.
  # If it's an integer index, derive the name from sm_name at runtime.
  defp reactor_rule_name_ast(_sm_name, name) when is_atom(name) do
    quote do: unquote(name)
  end

  defp reactor_rule_name_ast(sm_name, idx) when is_integer(idx) do
    quote do: :"#{unquote(sm_name)}_reactor_#{unquote(idx)}"
  end

  defp build_state_machine_workflow(accumulator_ast, reactor_rules_ast, sm_name) do
    quote generated: true do
      acc = unquote(accumulator_ast)
      reactor_rules = unquote(reactor_rules_ast)

      base_wrk =
        Workflow.new(unquote(sm_name))
        |> Workflow.add_step(acc)
        |> Workflow.register_component(acc)

      Enum.reduce(reactor_rules, base_wrk, fn rule, wrk ->
        condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
        reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

        wrk =
          wrk
          |> Workflow.add_step(acc, condition)
          |> Workflow.add_step(condition, reaction)
          |> Workflow.register_component(rule)

        # Create meta_ref edges pointing to the accumulator for state_of() resolution
        wrk =
          Enum.reduce(condition.meta_refs || [], wrk, fn meta_ref, w ->
            Workflow.draw_meta_ref_edge(w, condition.hash, acc.hash, meta_ref)
          end)

        Enum.reduce(reaction.meta_refs || [], wrk, fn meta_ref, w ->
          Workflow.draw_meta_ref_edge(w, reaction.hash, acc.hash, meta_ref)
        end)
      end)
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

    # Check for condition references in the where clause
    has_condition_refs = contains_condition_refs?(where_clause)

    if has_condition_refs do
      compile_given_when_then_rule_with_condition_refs(
        where_clause,
        then_clause,
        pattern_ast,
        top_binding,
        binding_vars,
        block,
        opts,
        env
      )
    else
      compile_given_when_then_rule_standard(
        where_clause,
        then_clause,
        pattern_ast,
        top_binding,
        binding_vars,
        block,
        opts,
        env
      )
    end
  end

  defp compile_given_when_then_rule_standard(
         where_clause,
         then_clause,
         pattern_ast,
         top_binding,
         binding_vars,
         block,
         opts,
         env
       ) do
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

  defp compile_given_when_then_rule_with_condition_refs(
         where_clause,
         then_clause,
         pattern_ast,
         top_binding,
         binding_vars,
         block,
         opts,
         env
       ) do
    # Build boolean IR from the where clause AST
    bool_tree = flatten_boolean_tree(where_clause)

    # Compile reaction
    reaction_meta_refs = detect_meta_expressions(then_clause)
    has_reaction_meta = reaction_meta_refs != []

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
    arity = 1

    # Build workflow from boolean IR
    {workflow, condition_hash, reaction_hash, rule_condition_refs_ast} =
      build_condition_ref_workflow_from_tree(
        bool_tree,
        reaction_fn,
        pattern_ast,
        top_binding,
        binding_vars,
        env,
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

    # Collect bindings from inline where expressions (for pin operators)
    where_bindings =
      Enum.flat_map(collect_inline_exprs(bool_tree), fn expr ->
        {_rewritten, bindings} = traverse_expression(expr, env)
        bindings
      end)

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
          outputs: unquote(rewritten_opts[:outputs]),
          condition_refs: unquote(rule_condition_refs_ast)
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
          outputs: unquote(rewritten_opts[:outputs]),
          condition_refs: unquote(rule_condition_refs_ast)
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
    escaped_reaction_meta_refs = escape_meta_refs(reaction_meta_refs)

    reaction_step =
      quote do
        Step.new(
          work: unquote(reaction),
          hash: unquote(reaction_ast_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )
      end

    condition_ast_hash = Components.fact_hash(condition)
    escaped_condition_meta_refs = escape_meta_refs(condition_meta_refs)

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
    :all_facts_of,
    :context
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

  # Handle 2-arity context/2 with opts (e.g., context(:key, default: "value"))
  defp collect_meta_ref({:context, _, [target, opts]} = node, acc)
       when is_atom(target) and is_list(opts) do
    existing = find_ref_by_target(acc, target, :context)

    unless existing do
      context_key = build_context_key(target, :context)
      default = Keyword.get(opts, :default)

      ref = %{
        kind: :context,
        target: target,
        field_path: [],
        context_key: context_key,
        default: default
      }

      {node, [ref | acc]}
    else
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

  # Base case: context(:key)
  defp extract_meta_expression_with_fields({:context, _, [target]}) do
    {:ok, :context, target, []}
  end

  # Base case: context(:key, default: value)
  defp extract_meta_expression_with_fields({:context, _, [target, opts]})
       when is_atom(target) and is_list(opts) do
    {:ok, :context, target, []}
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

  defp build_context_key(target, :context) when is_atom(target), do: target

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

        # context(:key).field - dot access on context expression
        {{:., dot_meta, [{:context, _, [target]}, field]}, call_meta, []} ->
          ref = find_ref_by_target(meta_refs, target, :context)

          if ref do
            map_get = quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key), %{}))
            {{:., dot_meta, [map_get, field]}, call_meta, []}
          else
            node
          end

        # context(:key, default: val).field - dot access on context/2 expression
        {{:., dot_meta, [{:context, _, [target, _opts]}, field]}, call_meta, []}
        when is_atom(target) ->
          ref = find_ref_by_target(meta_refs, target, :context)

          if ref do
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

        # context(:key, default: val) with default — 2-arity form
        {:context, _, [target, _opts]} when is_atom(target) ->
          ref = find_ref_by_target(meta_refs, target, :context)

          if ref do
            value_expr = quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key)))
            apply_default_expr(value_expr, ref)
          else
            node
          end

        # context(:key) without field access
        {:context, _, [target]} when is_atom(target) ->
          ref = find_ref_by_target(meta_refs, target, :context)

          if ref do
            value_expr = quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key)))
            apply_default_expr(value_expr, ref)
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

  # Escapes meta_refs for embedding in generated code.
  # Handles function AST defaults by injecting them directly instead of double-escaping.
  defp escape_meta_refs(meta_refs) do
    refs_with_escaped_defaults =
      Enum.map(meta_refs, fn ref ->
        case Map.get(ref, :default) do
          {:fn, _, _} = fn_ast ->
            escaped_ref = ref |> Map.delete(:default) |> Macro.escape()

            quote generated: true do
              Map.put(unquote(escaped_ref), :default, unquote(fn_ast))
            end

          _ ->
            Macro.escape(ref)
        end
      end)

    refs_with_escaped_defaults
  end

  defp apply_default_expr(value_expr, ref) do
    default = Map.get(ref, :default)

    case default do
      nil ->
        value_expr

      # Function AST: fn -> ... end — inject and call at runtime
      {:fn, _, _} = fn_ast ->
        quote generated: true do
          case unquote(value_expr) do
            nil -> unquote(fn_ast).()
            val -> val
          end
        end

      # Already-compiled function (e.g., from runtime meta_ref construction)
      default when is_function(default) ->
        quote generated: true do
          case unquote(value_expr) do
            nil -> unquote(Macro.escape(default)).()
            val -> val
          end
        end

      # Literal value
      default ->
        quote generated: true do
          case unquote(value_expr) do
            nil -> unquote(Macro.escape(default))
            val -> val
          end
        end
    end
  end

  # Detects context/1 meta expressions in a step or condition's work function AST.
  # If found, rewrites the work function to be arity-2 (input, meta_ctx) with
  # meta expression references resolved from the meta context map.
  # Returns {rewritten_work_ast, meta_refs_list}.
  defp maybe_compile_meta_work(work_ast, rewritten_work, _env) do
    meta_refs = detect_meta_expressions(work_ast)

    if meta_refs != [] do
      rewritten = rewrite_meta_refs_in_ast(rewritten_work, meta_refs)

      wrapped =
        quote generated: true do
          fn input, var!(meta_ctx, Runic) ->
            _ = var!(meta_ctx, Runic)
            unquote(rewritten).(input)
          end
        end

      {wrapped, meta_refs}
    else
      {rewritten_work, []}
    end
  end

  defp maybe_compile_meta_reducer(reducer_ast, rewritten_reducer, _env) do
    meta_refs = detect_meta_expressions(reducer_ast)

    if meta_refs != [] do
      rewritten = rewrite_meta_refs_in_ast(rewritten_reducer, meta_refs)

      wrapped =
        quote generated: true do
          fn value, acc, var!(meta_ctx, Runic) ->
            _ = var!(meta_ctx, Runic)
            unquote(rewritten).(value, acc)
          end
        end

      {wrapped, meta_refs}
    else
      {rewritten_reducer, []}
    end
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

  # =============================================================================
  # Condition Reference Detection & Boolean Decomposition (Phase 4)
  # =============================================================================

  defp contains_condition_refs?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:condition, _, [name]} = node, _acc when is_atom(name) -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # Flatten a boolean expression AST into an IR tree of :and/:or/:inline/:ref nodes.
  # This supports arbitrary nesting like (a and b) or (c and d).
  defp flatten_boolean_tree({:or, _, [lhs, rhs]}) do
    {:or, flatten_or_branches(lhs) ++ flatten_or_branches(rhs)}
  end

  defp flatten_boolean_tree({:||, _, [lhs, rhs]}) do
    {:or, flatten_or_branches(lhs) ++ flatten_or_branches(rhs)}
  end

  defp flatten_boolean_tree({:and, _, [_lhs, _rhs]} = ast) do
    {:and, flatten_and_parts(ast)}
  end

  defp flatten_boolean_tree({:&&, _, [_lhs, _rhs]} = ast) do
    {:and, flatten_and_parts(ast)}
  end

  defp flatten_boolean_tree({:condition, _, [name]} = _ast) when is_atom(name) do
    {:ref, name}
  end

  defp flatten_boolean_tree(expr) do
    {:inline, expr}
  end

  defp flatten_or_branches({:or, _, [lhs, rhs]}),
    do: flatten_or_branches(lhs) ++ flatten_or_branches(rhs)

  defp flatten_or_branches({:||, _, [lhs, rhs]}),
    do: flatten_or_branches(lhs) ++ flatten_or_branches(rhs)

  defp flatten_or_branches(expr), do: [flatten_boolean_tree(expr)]

  defp flatten_and_parts({:and, _, [lhs, rhs]}),
    do: flatten_and_parts(lhs) ++ flatten_and_parts(rhs)

  defp flatten_and_parts({:&&, _, [lhs, rhs]}),
    do: flatten_and_parts(lhs) ++ flatten_and_parts(rhs)

  defp flatten_and_parts({:condition, _, [name]}) when is_atom(name) do
    [{:ref, name}]
  end

  defp flatten_and_parts(expr), do: [{:inline, expr}]

  defp compile_inline_condition_expr(expr, pattern_ast, top_binding, binding_vars, env) do
    compile_when_clause(expr, pattern_ast, top_binding, binding_vars, env)
  end

  # Build workflow from boolean IR tree.
  # NOTE: Consider introducing a %Disjunction{} struct in the future if boolean
  # logic becomes more elaborate (e.g., negation, nested mixed expressions).
  # For now, `or` is modeled as multiple independent flow paths to the reaction —
  # the runtime deduplicates via mark_runnable_as_ran.
  defp build_condition_ref_workflow_from_tree(
         bool_tree,
         reaction_fn,
         pattern_ast,
         top_binding,
         binding_vars,
         env,
         reaction_meta_refs
       ) do
    reaction_ast_hash = Components.fact_hash(reaction_fn)
    escaped_reaction_meta_refs = escape_meta_refs(reaction_meta_refs)

    reaction_step =
      quote do
        Step.new(
          work: unquote(reaction_fn),
          hash: unquote(reaction_ast_hash),
          meta_refs: unquote(escaped_reaction_meta_refs)
        )
      end

    case bool_tree do
      {:and, parts} ->
        build_and_branch_workflow(
          parts,
          reaction_step,
          reaction_ast_hash,
          pattern_ast,
          top_binding,
          binding_vars,
          env
        )

      {:or, branches} ->
        build_or_branches_workflow(
          branches,
          reaction_step,
          reaction_ast_hash,
          pattern_ast,
          top_binding,
          binding_vars,
          env
        )

      {:ref, name} ->
        build_single_ref_workflow(name, reaction_step, reaction_ast_hash)

      {:inline, expr} ->
        build_single_inline_workflow(
          expr,
          reaction_step,
          reaction_ast_hash,
          pattern_ast,
          top_binding,
          binding_vars,
          env
        )
    end
  end

  # Build workflow for a single and-group: inline conditions + refs → Conjunction → reaction
  defp build_and_branch_workflow(
         parts,
         reaction_step,
         reaction_ast_hash,
         pattern_ast,
         top_binding,
         binding_vars,
         env
       ) do
    {condition_refs, inline_exprs} = partition_and_parts(parts)

    inline_conditions =
      Enum.map(inline_exprs, fn expr ->
        condition_fn =
          compile_inline_condition_expr(expr, pattern_ast, top_binding, binding_vars, env)

        condition_ast_hash = Components.fact_hash(condition_fn)

        condition_node =
          quote do
            Condition.new(
              work: unquote(condition_fn),
              hash: unquote(condition_ast_hash),
              arity: 1
            )
          end

        {condition_node, condition_ast_hash}
      end)

    inline_hashes = Enum.map(inline_conditions, &elem(&1, 1))
    escaped_refs = Macro.escape(condition_refs)

    conjunction =
      quote do
        Conjunction.new(unquote(inline_hashes), unquote(escaped_refs))
      end

    workflow =
      quote do
        import Runic

        wrk = Workflow.new()

        wrk =
          Enum.reduce(
            unquote(Enum.map(inline_conditions, &elem(&1, 0))),
            wrk,
            fn cond_node, w -> Workflow.add_step(w, cond_node) end
          )

        conj = unquote(conjunction)
        inline_conds = Workflow.conditions(wrk)

        wrk =
          Enum.reduce(inline_conds, wrk, fn cond_node, w ->
            Workflow.add_step(w, cond_node, conj)
          end)

        Workflow.add_step(wrk, conj, unquote(reaction_step))
      end

    conjunction_hash =
      quote do
        Conjunction.new(unquote(inline_hashes), unquote(escaped_refs)).hash
      end

    rule_condition_refs =
      quote do
        conj_hash = unquote(conjunction_hash)
        Enum.map(unquote(escaped_refs), fn ref_name -> {ref_name, conj_hash} end)
      end

    {workflow, conjunction_hash, reaction_ast_hash, rule_condition_refs}
  end

  # Build workflow for or-branches: each branch independently flows to the reaction step.
  defp build_or_branches_workflow(
         branches,
         reaction_step,
         reaction_ast_hash,
         pattern_ast,
         top_binding,
         binding_vars,
         env
       ) do
    compiled_branches =
      Enum.map(branches, fn branch ->
        compile_or_branch(branch, pattern_ast, top_binding, binding_vars, env)
      end)

    # Compute a synthetic condition hash from all branches
    branch_hash_basis =
      Enum.map(compiled_branches, fn
        {:ref_branch, name} -> {:ref, name}
        {:inline_branch, _node, hash} -> {:hash, hash}
        {:and_branch, _inline_conds, _refs, conj_hash_ast} -> {:conj, conj_hash_ast}
      end)

    # Separate compile-time-resolvable and runtime hash components
    {static_parts, dynamic_parts} =
      Enum.split_with(branch_hash_basis, fn
        {:ref, _} -> true
        {:hash, _} -> true
        {:conj, _} -> false
      end)

    static_basis = Enum.sort(static_parts)

    workflow =
      quote do
        import Runic

        reaction = unquote(reaction_step)
        wrk = Workflow.new()
        wrk = %Workflow{wrk | graph: Graph.add_vertex(wrk.graph, reaction, reaction.hash)}

        unquote(build_or_branch_wiring(compiled_branches))
      end

    condition_hash =
      if Enum.empty?(dynamic_parts) do
        Components.fact_hash({:or, static_basis})
      else
        quote do
          dynamic_hashes =
            Enum.map(unquote(Macro.escape(dynamic_parts)), fn
              {:conj, hash} -> {:conj_hash, hash}
            end)

          Components.fact_hash({:or, unquote(Macro.escape(static_basis)) ++ dynamic_hashes})
        end
      end

    # Collect condition_refs: direct ref branches wire to reaction,
    # and-branch refs wire to their conjunction
    rule_condition_refs =
      Enum.reduce(compiled_branches, [], fn
        {:ref_branch, name}, acc ->
          [{name, reaction_ast_hash} | acc]

        {:and_branch, _inline_conds, refs, conj_hash_ast}, acc ->
          and_refs = Enum.map(refs, fn ref_name -> {ref_name, conj_hash_ast} end)
          and_refs ++ acc

        {:inline_branch, _node, _hash}, acc ->
          acc
      end)
      |> Enum.reverse()

    # Separate static and dynamic refs
    {static_refs, dynamic_refs} =
      Enum.split_with(rule_condition_refs, fn {_name, target} -> is_integer(target) end)

    rule_condition_refs_ast =
      if Enum.empty?(dynamic_refs) do
        Macro.escape(static_refs)
      else
        quote do
          unquote(Macro.escape(static_refs)) ++
            unquote(
              Enum.map(dynamic_refs, fn {name, hash_ast} ->
                quote do
                  {unquote(name), unquote(hash_ast)}
                end
              end)
            )
        end
      end

    {workflow, condition_hash, reaction_ast_hash, rule_condition_refs_ast}
  end

  # Compile a single or-branch into a tagged tuple for workflow wiring
  defp compile_or_branch({:ref, name}, _pattern_ast, _top_binding, _binding_vars, _env) do
    {:ref_branch, name}
  end

  defp compile_or_branch({:inline, expr}, pattern_ast, top_binding, binding_vars, env) do
    condition_fn =
      compile_inline_condition_expr(expr, pattern_ast, top_binding, binding_vars, env)

    condition_ast_hash = Components.fact_hash(condition_fn)

    condition_node =
      quote do
        Condition.new(
          work: unquote(condition_fn),
          hash: unquote(condition_ast_hash),
          arity: 1
        )
      end

    {:inline_branch, condition_node, condition_ast_hash}
  end

  defp compile_or_branch({:and, parts}, pattern_ast, top_binding, binding_vars, env) do
    {condition_refs, inline_exprs} = partition_and_parts(parts)

    inline_conditions =
      Enum.map(inline_exprs, fn expr ->
        condition_fn =
          compile_inline_condition_expr(expr, pattern_ast, top_binding, binding_vars, env)

        condition_ast_hash = Components.fact_hash(condition_fn)

        condition_node =
          quote do
            Condition.new(
              work: unquote(condition_fn),
              hash: unquote(condition_ast_hash),
              arity: 1
            )
          end

        {condition_node, condition_ast_hash}
      end)

    inline_hashes = Enum.map(inline_conditions, &elem(&1, 1))
    escaped_refs = Macro.escape(condition_refs)

    conj_hash_ast =
      quote do
        Conjunction.new(unquote(inline_hashes), unquote(escaped_refs)).hash
      end

    {:and_branch, inline_conditions, condition_refs, conj_hash_ast}
  end

  # Generate AST that wires each compiled branch to the reaction step in the workflow
  defp build_or_branch_wiring(compiled_branches) do
    Enum.reduce(compiled_branches, nil, fn branch, acc ->
      branch_ast =
        case branch do
          {:ref_branch, _name} ->
            # Condition ref branches have no inline nodes to add — they're wired at connect-time.
            # The reaction step is already in the workflow; the ref's condition will be wired
            # to the reaction by Component.connect/3 when the rule is added to a workflow.
            nil

          {:inline_branch, condition_node, _hash} ->
            quote do
              cond_node = unquote(condition_node)
              wrk = Workflow.add_step(wrk, cond_node)
              wrk = Workflow.add_step(wrk, cond_node, reaction)
            end

          {:and_branch, inline_conditions, condition_refs, _conj_hash_ast} ->
            inline_nodes_ast = Enum.map(inline_conditions, &elem(&1, 0))
            inline_hashes = Enum.map(inline_conditions, &elem(&1, 1))
            escaped_refs = Macro.escape(condition_refs)

            quote do
              conj = Conjunction.new(unquote(inline_hashes), unquote(escaped_refs))

              wrk =
                Enum.reduce(
                  unquote(inline_nodes_ast),
                  wrk,
                  fn cond_node, w -> Workflow.add_step(w, cond_node) end
                )

              branch_inline_conds =
                Enum.filter(Graph.vertices(wrk.graph), fn
                  %Condition{hash: h} -> h in unquote(inline_hashes)
                  _ -> false
                end)

              wrk =
                Enum.reduce(branch_inline_conds, wrk, fn cond_node, w ->
                  Workflow.add_step(w, cond_node, conj)
                end)

              wrk = Workflow.add_step(wrk, conj, reaction)
            end
        end

      case {acc, branch_ast} do
        {nil, nil} ->
          nil

        {nil, ast} ->
          ast

        {acc, nil} ->
          acc

        {acc, ast} ->
          quote do
            unquote(acc)
            unquote(ast)
          end
      end
    end)
    |> case do
      nil ->
        quote do
          wrk
        end

      ast ->
        quote do
          unquote(ast)
          wrk
        end
    end
  end

  # Build workflow for a single condition ref flowing directly to reaction
  defp build_single_ref_workflow(name, reaction_step, reaction_ast_hash) do
    workflow =
      quote do
        import Runic
        wrk = Workflow.new()
        reaction = unquote(reaction_step)
        %Workflow{wrk | graph: Graph.add_vertex(wrk.graph, reaction, reaction.hash)}
      end

    condition_hash = Components.fact_hash({:or, [{:ref, name}]})
    rule_condition_refs = Macro.escape([{name, reaction_ast_hash}])
    {workflow, condition_hash, reaction_ast_hash, rule_condition_refs}
  end

  # Build workflow for a single inline condition flowing directly to reaction
  defp build_single_inline_workflow(
         expr,
         reaction_step,
         reaction_ast_hash,
         pattern_ast,
         top_binding,
         binding_vars,
         env
       ) do
    condition_fn =
      compile_inline_condition_expr(expr, pattern_ast, top_binding, binding_vars, env)

    condition_ast_hash = Components.fact_hash(condition_fn)

    condition_node =
      quote do
        Condition.new(
          work: unquote(condition_fn),
          hash: unquote(condition_ast_hash),
          arity: 1
        )
      end

    workflow =
      quote do
        import Runic
        wrk = Workflow.new()
        cond_node = unquote(condition_node)
        wrk = Workflow.add_step(wrk, cond_node)
        Workflow.add_step(wrk, cond_node, unquote(reaction_step))
      end

    condition_hash = condition_ast_hash
    {workflow, condition_hash, reaction_ast_hash, Macro.escape([])}
  end

  # Extract refs and inline expressions from and-group parts
  defp partition_and_parts(parts) do
    Enum.reduce(parts, {[], []}, fn
      {:ref, name}, {refs, inlines} -> {[name | refs], inlines}
      {:inline, expr}, {refs, inlines} -> {refs, [expr | inlines]}
    end)
    |> then(fn {refs, inlines} -> {Enum.reverse(refs), Enum.reverse(inlines)} end)
  end

  # Recursively collect all inline expressions from a boolean IR tree
  defp collect_inline_exprs({:inline, expr}), do: [expr]
  defp collect_inline_exprs({:ref, _}), do: []
  defp collect_inline_exprs({:and, parts}), do: Enum.flat_map(parts, &collect_inline_exprs/1)
  defp collect_inline_exprs({:or, branches}), do: Enum.flat_map(branches, &collect_inline_exprs/1)
end
