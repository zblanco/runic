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

  @doc """
  Creates a %Step{}: a basic lambda expression that can be added to a workflow.

  Steps are basic input -> output dataflow primatives that can be connected together in a workflow.

  A Step implements the Runic.Workflow.Activation, and Runic.Workflow.Component protocols
  to be composable and possible to evaluate at runtime with inputs.
  """
  alias Runic.Workflow.Step

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
end
