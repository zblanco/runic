<!-- MDOC !-->

# Runic

Runic is a tool for modeling your workflows as data that can be composed together at runtime.

Runic components can be integrated into a Runic.Workflow and evaluated lazily in concurrent contexts.

Runic Workflows are a decorated dataflow graph (a DAG - "directed acyclic graph") capable of modeling rules, pipelines, and state machines and more.

Basic data flow dependencies such as in a pipeline are modeled as %Step{} structs (nodes/vertices) in the graph with directed edges (arrows) between steps.

A step can be thought of as a simple input -> output lambda function. e.g.

```elixir
require Runic

step = Runic.step(fn x -> x + 1 end)
```

And since steps are composable, you can connect them together in a workflow:

```elixir
workflow = Runic.workflow(
  name: "example pipeline workflow",
  steps: [
    Runic.step(fn x -> x + 1 end),
    Runic.step(fn x -> x * 2 end),
    Runic.step(fn x -> x - 1 end)
  ]
)
```

Inputs fed through a workflow are called "Facts". During workflow evaluation various steps are traversed to and invoked producing more Facts.

```elixir
alias Runic.Workflow

workflow
|> Workflow.react_until_satisfied(2)
|> Worfklow.raw_productions()

> [3, 4, 1]
```

Beyond steps, Runic has support for Rules, Joins, and State Machines for more complex control flow and stateful evaluation.

The Runic.Workflow.Invokable protocol is what allows for extension of Runic and composability
  of structures like Workflows, Steps, Rules, and Accumulators by allowing user defined structures to be integrated into a `Runic.Workflow`.

See the Runic.Workflow module for more information about evaluation APIs.

This top level module provides high level functions and macros for building Runic Components
  such as Steps, Rules, Workflows, and Accumulators.

Runic was designed to be used with custom process topologies and/or libraries such as GenStage, Broadway, and Flow.

Runic is meant for dynamic runtime modification of a workflow where you might want to compose pieces of a workflow together at runtime.

These sorts of use cases are common in expert systems, user DSLs (e.g. Excel, low-code tools) where a developer cannot know
  upfront the logic or data flow to be expressed in compiled code.

If the runtime modification of a workflow or complex parallel dataflow evaluation isn't something your use case requires you might not need Runic and vanilla compiled Elixir code will be faster and simpler.

Runic Workflows are essentially a dataflow based virtual machine running within Elixir and will not be faster than compiled Elixir code.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `runic` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:runic, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/runic>.

