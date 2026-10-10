# Ordinary custom components

Use a native Step when your component simply calls a function and returns data.
Keep a domain-specific component when its identity, configuration, ports, and
reconstruction deserve their own representation. Neither choice requires writing
Runic lifecycle events.

For a custom node with ordinary readiness and **one output or an explicit
failure**, use `Runic.Workflow.SingleOutput`:

```elixir
defmodule MyApp.Scale do
  use Runic.Workflow.SingleOutput
  alias Runic.Workflow.SingleOutput.Result

  defstruct [:name, :hash, :factor]

  def new(name, factor) do
    %__MODULE__{
      name: name,
      factor: factor,
      hash: Runic.Identity.digest(:component_definition, {:scale, 1, name, factor})
    }
  end

  @impl true
  def run(node, value, _context) when is_number(value) do
    Result.value(value * node.factor, metadata: %{scale: %{factor: node.factor}})
  end

  def run(_node, _value, _context), do: Result.failure(:expected_number)
end
```

This generates the ordinary `Runic.Workflow.Invokable` implementation. Implement
`Runic.Component` separately for composition, ports, identity, and reconstructable
source; `SingleOutput` does not replace it. Put the protocol implementation in
its own file:

```elixir
defimpl Runic.Component, for: MyApp.Scale do
  alias Runic.Workflow

  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :step})
    |> Workflow.register_component(node)
  end

  def source(node) do
    quote do
      MyApp.Scale.new(unquote(node.name), unquote(node.factor))
    end
  end

  def hash(node), do: node.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
```

This example accepts one parent. More involved composition still uses the
existing connection/port contracts; the execution behaviour does not invent
new join semantics. The executable example files are in
[`examples/single_output`](https://github.com/zblanco/runic/tree/main/examples/single_output).
They are exercised by `test/single_output_example_test.exs`.

```elixir
alias Runic.Workflow

workflow = Workflow.new() |> Workflow.add(MyApp.Scale.new(:scale, 3))
rebuilt = workflow |> Workflow.build_log() |> Workflow.from_log()
completed = Workflow.react_until_satisfied(rebuilt, 4)
Workflow.raw_productions(completed, :scale)
# => [12]
```

## What the callback knows

`run(component, input_value, context)` receives a `SingleOutput.Context`:

| Field | Meaning |
| --- | --- |
| `runtime` | Existing component-scoped runtime context, including global defaults |
| `meta` | Prepared graph/context expression bindings, if declared by the node |
| `input_metadata` | Input Fact metadata, for deliberate application propagation |
| `runnable_id`, `activation_id` | Stable correlation for this prepared activation |
| `attempt_id`, `attempt_number` | Current attempt, including retries; numbering starts at zero |

No workflow, hook list, collection bookkeeping, or event constructors are needed.
This is a view of existing context, not a second dependency-resolution system.
Application work, validation, telemetry, and result conversion belong in the
callback. There is no implicit task spawn or extra scheduler.

## Data versus failure

`Result.value({:error, reason})` is successful data. `Result.failure(reason)` is a
failed attempt. Invalid callback returns fail with
`{:invalid_single_output_result, returned_term}`. Exceptions remain exception
structs; throws and catchable exits become `{kind, reason}` failures. An
uncatchable process kill remains the execution backend's responsibility.

Ordinary Steps **do not interpret this contract**: their normally returned terms
remain data, including `{:error, reason}` and a `Result` struct when its contents
are valid Fact data. Callback values remain subject to native Fact identity and
portability constraints; this behaviour does not introduce local-value mode.

Retry, timeout, backoff, and classification remain `SchedulerPolicy` /
`PolicyDriver` responsibilities. Direct `Invokable.execute/2` executes a single
attempt; workflow/Runner policy execution supplies retry attempt identities.
Callbacks must not create a second retry loop unless the application explicitly
intends nested retries.

## Hooks, metadata, and acceptance

The order is before hooks → callback/result interpretation → child Fact → after
hooks → completed Runnable. Native ancestry and activation/collection events are
constructed by Runic. Hook reducers are deferred until workflow application.
Failure publishes neither a successful Fact nor deferred hook changes. Retries
rerun before hooks; success hooks run only after a successful callback and Fact
construction. An after-hook failure can therefore retry already-executed work:
neither hooks nor external I/O are exactly once.

Event/context hooks receive `HookEvent.input_fact` and, for after hooks, the
produced Fact in `HookEvent.result`. Three-argument hooks attached with
`Workflow.attach_before_hook/3` receive the input Fact; those attached with
`Workflow.attach_after_hook/3` receive the produced Fact, including its ancestry
and metadata. These workflow-taking hooks are deferred until application, even
through direct `Invokable.invoke/3`. Their workflow changes run in before/after
order after the native completion events are folded. Errors in deferred
workflow changes occur during application, outside the execution attempt's
hook failure handling.

`Result.value(value, metadata: map)` supplies the output's application metadata.
There is **no implicit inheritance**. Select the application namespaces you need;
do not indiscriminately merge runtime context or input coordination annotations.
The output metadata must be a plain map and cannot set the reserved `:runic`
namespace. Native lineage is not writable through this interface.

A policy fallback `{:value, value}` is already-interpreted replacement data. For
Steps and opted-in nodes it uses the same Fact/event/collection builder, but does
not call the application callback or rerun hooks, and defaults to empty output
metadata. This preserves the existing fallback hook policy. Domain validation
of a replacement value is the fallback author's responsibility.

Computation completion does not acknowledge persistence or broker delivery.
Task cancellation does not roll back an external effect. Existing Runner
ownership, persistence failures, and result-correlation rules still apply.

## Collections and specialized nodes

The shared prepare path understands native Map/Reduce mapped paths and ordinary
nodes directly feeding a FanIn associated with their ancestral FanOut. Custom
composites using that topology no longer need a component-specific
`MapReduceTracked` implementation. An intervening ordinary transformation and
lightweight FactRef ancestors are supported. Uncollected branches do not produce
unused tracking entries.

This is participation in existing collection semantics, **not a new batch API**.
Empty-batch behavior, invocation-scoped batch identity, and arbitrary nested
collectors are not redesigned here. Preserve low-level `Invokable`, `Activator`,
and `Coordinator` for gates, multiple outputs, stateful coordination, and unusual
execution semantics.

## Construction, replay, and runtime resources

Save the component's executable/configuration and result interpretation through
its `Component.source/1` or Runic closure representation. Semantic configuration
must be reflected in component identity. Module names alone are not deployment
version pins. Rebuild requires compatible callback code and captured bindings.
Runic's AST plus captured-binding closure model remains supported; anonymous
functions are not inherently excluded.

Do not store clients, repositories, pools, secrets, or process handles in the
component definition merely to reach the callback. Resolve them through runtime
context and supply fresh values on resume. The native lifecycle never copies
that context into output metadata, but cannot prevent user code from explicitly
returning or capturing it.

`Workflow.from_log/1` rebuilds construction logs. For accepted incremental
lifecycle events, use `Workflow.from_events/2`. Replay folds accepted events
without rerunning the callback or success hooks. A fresh execution of a rebuilt
definition does, naturally, execute work again. No new persisted event schema is
introduced by this behaviour.
