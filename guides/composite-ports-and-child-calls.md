# Composite ports and child calls

Use `Workflow.add/3` with `connections:` to connect public ports. Runic resolves
ordinary nodes, nested workflows, and declared custom endpoints. The caller does
not need to find an internal producer or create a Join.

## Input modes

A connection group uses `input_mode: :all` by default. Runic waits for every
source producer. `input_mode: :any` binds each source producer separately and
runs the target for each source Fact. Each source must supply all required target
ports. The mode does not depend on whether values are lists, maps, or tuples.

```elixir
Workflow.add(workflow, target,
  connections: [
    [from: {:left, :out}, to: :in],
    [from: {:right, :out}, to: :in]
  ],
  input_mode: :any
)
```

For an all-input list, use explicit non-overlapping `target_path` positions:

```elixir
Workflow.add(workflow, nested_flow,
  connections: [
    [from: {:left, :out}, to: :in, target_path: [0]],
    [from: {:right, :out}, to: :in, target_path: [1]]
  ]
)
```

A multi-arity Step receives a list in declared input-port order. Other components
with several input ports receive a map with the declared port names as keys.
A component with one input port receives that port's whole value.

Missing ports, missing required inputs, incompatible whole-port types, and
overlapping assignments raise errors at construction. Projection and target
paths can change types, so their runtime values still need application validation.

## Custom output endpoints

A custom `Component.outputs/1` implementation can declare:

```elixir
[left: [type: :integer, from: :internal_left],
 right: [type: :integer, from: :internal_right]]
```

The component's `connect/3` implementation must install the internal nodes and
register their names. `from:` also accepts a node identity for a private node.
Runic adds the output ownership edges. A declared output uses the whole produced
value when it has its own producer. Ports sharing one producer use named or
positional projection from that producer's value, as in the existing port API.
Custom components can also supply `:component_of` edges with `kind: :output` and
`ports: [...]`. Legacy unambiguous ownership remains supported.

Binders and Joins are compiler nodes. They do not become registered public
components. Bindings preserve application metadata from their input Fact and
replace the native `:runic` input-binding annotation. An all-input Join does not
combine application metadata from several parents; that remains a consumer task.

Build-log replay retains the mode, ports, output endpoint selection, and output.
Old connection events keep all-input behavior.

## Child requests

Create a Call from a one-input Step that returns `ChildInvocation.new/1`.
The Call's public `out` port becomes ready only when its child completes.
Connect consumers to that port with `connections:`.

```elixir
request = Runic.step(fn input ->
  target = Runic.step(fn value -> value * 2 end, name: :double)
  Runic.Workflow.ChildInvocation.new(target: target, input: input)
end, name: :request)

call = Runic.Workflow.Call.new(request, name: :call)
workflow = Workflow.new() |> Workflow.add(call)
```

For targets with several outputs, select `output: :port_name`. The target must
have a reconstructable source. The first version supports ordinary Steps,
SingleOutput custom nodes, and declared stateless workflows built from these
nodes, InputBinding, and Join. It rejects stateful nodes, collection coordination,
nested dynamic Calls, graph metadata references, and targets with attached hooks,
policies, or live runtime context. `input:` is the target's complete native input
value; it is not interpreted as an implicit set of bindings. Runtime context and policies still use the target's
authored node name. Different occurrences have different node hashes.

The parent owns each child as ordinary graph work. Equal calls in separate
`Workflow.execute/3` or `Runner.start_execution/4` scopes have different input
Fact identities and child identities. Retrying one Call activation keeps its
occurrence identity. Legacy content-based inputs need explicit distinct Facts
if the caller wants repeated equal calls.

A child failure uses the parent's existing retry/halt/skip policy. The Call
produces no completed output for that occurrence. A request-Step policy fallback
can supply already interpreted output; an explicit ChildInvocation fallback
requests a child. A new scope can reuse the
graph after the caller makes the runtime's required recovery decision.

Before request acceptance, recovery sees only the parent activation. After
attachment, construction events describe the child occurrence and accepted
runtime events describe its progress. During execution, unaccepted work remains
uncertain and can run again. After completion, replay restores the accepted
output and does not rerun accepted child callbacks. Parent cancellation stops
native child tasks through the same task owner, including tasks that trap exits.

The Call's own Runnable completion records request computation and acceptance.
Its public output port records child completion. Execution observation includes
internal computation outcomes; use component results to read the completed Call
output. These are different boundaries.

The public Call Fact retains the child's application metadata. Runic does not
interpret Jido effects or commit Agent state. Local result acceptance, executor
uncertainty, and Store acknowledgement remain separate states. There is no
exactly-once external-effect guarantee.

Completed child graph nodes remain in the parent. Long-lived callers must
account for this memory cost. Retention and compaction are separate work.

See `examples/child_invocation.exs` for a report service and
`examples/jido_action/child_invocation.ex` for an ordinary Jido Action boundary.
The design comparison and recovery decision are in
`.docs/issue-34-child-invocation-decision.md`.
