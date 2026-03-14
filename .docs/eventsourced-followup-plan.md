# Event-Sourced Model: Follow-Up Implementation Plan

**Status:** Draft  
**Prerequisites:** [Implementation Plan](eventsourced-implementation-plan.md), [Benchmark Analysis](eventsourced-benchmark-analysis.md), [Baseline Benchmarks](baseline-benchmark-results.txt)  
**Breaking Changes:** Noted per item

---

## Motivation

Post Phase 7, the event-sourced model passes performance targets and all 793 tests. Three areas need follow-up:

1. **Fan-out/fan-in fact count discrepancy** — behavioral difference between baseline and event-sourced execution
2. **Uncommitted event buffering** — memory overhead from unconditionally accumulating events even for in-memory scripting use cases
3. **Event extensibility** — `apply_event/2` uses module-level pattern matching, preventing external `Invokable` implementations from defining their own events

---

## Item 1: Fan-Out/Fan-In Fact Count Investigation

### Observed Behavior

Benchmark sanity checks show different fact counts between the baseline (pre-migration) and event-sourced model:

```
                    Baseline                    Event-Sourced
fanout_small:   9 productions, 14 total     6 productions, 11 total
fanout_medium: 21 productions, 32 total    12 productions, 23 total
```

Both produce the correct final reduced value. The difference is in *intermediate* fact counts.

### Root Cause Analysis

The `invoke/3` path (used during `react_until_satisfied`) differs from the three-phase path in how FanIn handles arrival:

**`invoke/3` path** (`FanIn.invoke/3` at `invokable.ex:1432`):
- When `ready?` is true, calls `mark_runnable_as_ran(wrk, fan_in, sister_fact)` for *each* sister fact
- Then calls `mark_runnable_as_ran(wrk, fan_in, reduced_fact)` — marking the *reduced output* as ran against the FanIn
- `prepare_next_runnables` is called which draws activation edges from the reduced fact to downstream nodes
- This results in both the sister facts AND the reduced fact being logged as `:ran` against the FanIn

**Three-phase path** (`execute/2` + `apply_runnable/2`):
- `execute/2` only emits `ActivationConsumed` for the triggering fact
- `maybe_finalize_coordination/2` at `workflow.ex:3111` rechecks readiness, produces `ActivationConsumed` events for all sister facts (excluding the triggering fact)
- `FanInCompleted` event logs the reduced fact and draws `:reduced` edge
- `emit_downstream_activations/2` activates downstream from the reduced fact
- The reduced fact is NOT marked as `:ran` against the FanIn (no extra `mark_runnable_as_ran` for the output fact)

The fact count difference comes from `invoke/3` calling `mark_runnable_as_ran(wrk, fan_in, reduced_fact)` at line 1531, which draws a `:ran` edge from the reduced fact back to the FanIn. This creates an additional edge/connection that the three-phase path does not produce. The `invoke/3` path also calls `prepare_next_runnables` which may re-activate nodes already activated through `emit_downstream_activations`.

### Assessment

The three-phase path behavior is **more correct**. A reduced fact is the *output* of a FanIn — marking it as "ran" against the FanIn is semantically wrong (the FanIn consumed the sister facts, not its own output). The `invoke/3` path's extra `mark_runnable_as_ran` for the output fact was a pre-existing over-counting bug that happened to be harmless.

The fact count difference does not affect correctness — all workflows produce identical final values. The three-phase path simply avoids a spurious `:ran` edge.

### Action

**No change needed.** The event-sourced model's behavior is the correct one. The `invoke/3` path still works because `mark_runnable_as_ran` is idempotent and the extra edge doesn't affect execution flow. If we want consistency between paths, the fix would be in `invoke/3` (remove the `mark_runnable_as_ran(wrk, fan_in, reduced_fact)` call at `invokable.ex:1531`), but this is low priority since `invoke/3` is the legacy internal path.

---

## Item 2: Conditional Event Buffering

### Problem

`apply_runnable/2` unconditionally appends events to `workflow.uncommitted_events` (line 2959):

```elixir
%{wf | uncommitted_events: wf.uncommitted_events ++ events ++ derived_events}
```

For in-memory scripting use cases (`react/2`, `react_until_satisfied/2` without a Store), these events are allocated, concatenated, and never consumed. The benchmark analysis shows this contributes ~250–400 bytes/fact overhead and the list concatenation cost grows with workflow depth.

The Worker (`runner/worker.ex:226-233`) is the only consumer — it drains `uncommitted_events` after each `apply_runnable` call when a stream-capable Store is configured.

### Design Options

#### Option A: `emit_events` Flag on Workflow Struct

Add a boolean field `emit_events` (default `false`) to `%Workflow{}`. When `false`, `apply_runnable/2` skips the uncommitted_events buffer entirely.

```elixir
defstruct [..., emit_events: false, uncommitted_events: []]

# In apply_runnable/2:
wf = if wf.emit_events do
  %{wf | uncommitted_events: wf.uncommitted_events ++ events ++ derived_events}
else
  wf
end
```

The Worker sets `emit_events: true` when initializing workflows for durable execution. In-memory scripting never sets it.

**Pros:** Zero overhead for scripting. Simple boolean check. No API change for existing users.  
**Cons:** Adds a field to the struct. Events are silently discarded unless opted in — could surprise users who read `uncommitted_events` directly.

#### Option B: Runtime Option on `react_until_satisfied/2`

Pass `emit_events: true` as an option to `react_until_satisfied/2`, which threads it through to `apply_runnable/2`:

```elixir
Workflow.react_until_satisfied(workflow, input, emit_events: true)
```

**Pros:** No struct change. Explicit per-call.  
**Cons:** Requires threading the option through react → execute_runnables_serial → apply_runnable. Changes apply_runnable's arity or requires a private option parameter. Awkward for the Worker which calls `apply_runnable/2` directly.

#### Option C: Separate `apply_runnable` Variants

Provide `apply_runnable/2` (no buffering, default) and `apply_runnable_with_events/2` (buffers events):

```elixir
def apply_runnable(%__MODULE__{} = wf, %Runnable{} = r) do
  do_apply_runnable(wf, r, false)
end

def apply_runnable_with_events(%__MODULE__{} = wf, %Runnable{} = r) do
  do_apply_runnable(wf, r, true)
end
```

**Pros:** Explicit API. No struct mutation. No option threading.  
**Cons:** Two public functions for the same operation. The Worker must know to call the `_with_events` variant.

---

**Recommendation: Option A** (`emit_events` flag on struct)

It's the simplest change, avoids API proliferation, and the Worker already owns workflow lifecycle. The flag is set once at Worker init time and stays for the workflow's lifetime. The field name makes intent clear.

For ergonomics, add a convenience function:

```elixir
def enable_event_emission(%__MODULE__{} = wf), do: %{wf | emit_events: true}
def disable_event_emission(%__MODULE__{} = wf), do: %{wf | emit_events: false}
```

### Implementation

1. Add `emit_events: false` to `%Workflow{}` defstruct
2. Guard the `uncommitted_events` concatenation in `apply_runnable/2` behind `wf.emit_events`
3. In `Worker.init/1`, set `emit_events: true` on the workflow when a stream-capable store is configured
4. Add `enable_event_emission/1` / `disable_event_emission/1` convenience functions
5. Document in `@moduledoc` that `uncommitted_events` is only populated when `emit_events` is true

**Breaking change:** None. Default behavior (`emit_events: false`) means existing scripting code sees no change. `uncommitted_events` was always `[]` for non-Worker usage — this just avoids the allocation.

### Validation

- All 793 existing tests pass (they don't read `uncommitted_events`)
- Worker tests that verify event persistence still work (Worker sets `emit_events: true`)
- Benchmark re-run shows reduced memory for scripting path (eliminates ~250-400 B/fact overhead)

---

## Item 3: Performance Optimizations

### 3.1 List Concatenation in `apply_runnable/2`

**Current:** `wf.uncommitted_events ++ events ++ derived_events`

This is O(n) in the length of `uncommitted_events`. For long-running workflows with many cycles, this becomes quadratic.

**Fix:** Use a reverse-prepend + final reverse pattern, or use `:queue` / difference list:

```elixir
# Option: prepend in reverse, final consumer reverses once
%{wf | uncommitted_events: Enum.reverse(derived_events) ++ Enum.reverse(events) ++ wf.uncommitted_events}

# Consumer (Worker checkpoint) reverses once:
events_to_persist = Enum.reverse(state.uncommitted_events)
```

This makes each `apply_runnable/2` call O(k) where k is the number of events produced (typically 2–4), regardless of how many events are already buffered.

**When this matters:** Only for emit_events mode (durability). Item 2 eliminates the cost entirely for scripting.

### 3.2 Event Struct Allocation

Each `execute/2` allocates 2–4 event structs per invocation. For hot paths (linear pipelines, large branching), this is measurable. Two possible optimizations:

**a) Struct pool / flyweight for common patterns:** Not worth it. Elixir structs are maps under the hood and the BEAM allocator is efficient for small maps. The 2–4 structs per invocation are short-lived and GC'd quickly.

**b) Tuple-based events instead of structs:** Replace `%FactProduced{hash: h, value: v, ...}` with `{:fact_produced, h, v, ancestry, label, weight}`. Tuples are more compact than maps.

**Assessment:** Not recommended. The struct-based events provide readability, pattern matching safety, and protocol extensibility (Item 4). The ~5-13% overhead is within budget. Premature optimization here would harm the extensibility goals.

### 3.3 `apply_event/2` Dispatch

Currently `apply_event/2` uses function clause pattern matching on 12 event types. The BEAM compiles this to efficient dispatch (similar to a jump table for struct matches). No optimization needed — this is already the fastest dispatch mechanism available in Elixir.

### 3.4 Recommendation

Only pursue **3.1** (list concatenation fix), and only after Item 2 is implemented (since Item 2 eliminates the buffer entirely for scripting). The fix is trivial and removes the only algorithmic concern (O(n²) → O(n) for long-running durable workflows).

---

## Item 4: Event Extensibility via Protocol Dispatch

### Problem

`apply_event/2` in `workflow.ex` (lines 641–816) uses module-level function pattern matching:

```elixir
def apply_event(%__MODULE__{} = wf, %FactProduced{} = e) do ...
def apply_event(%__MODULE__{} = wf, %ActivationConsumed{} = e) do ...
def apply_event(%__MODULE__{} = wf, %JoinFactReceived{} = e) do ...
# ... 12 clauses total
```

An external library implementing `Invokable` for a custom node type cannot add new event types because:
1. They can't add clauses to `Workflow.apply_event/2`
2. The `Serializer` doesn't know about their event structs
3. `maybe_finalize_coordination/2` pattern-matches on node types — not extensible

This blocks the extensibility promise of the `Invokable` protocol for durable execution scenarios.

### Design Space

The challenge is that `apply_event/2` needs access to the `%Workflow{}` struct's internals (graph, mapped, etc.) to perform mutations. A protocol on the event struct alone can't do this without exposing those internals.

#### Option A: `EventApplicator` Protocol on Event Structs

Define a protocol that event structs implement to describe how they fold into a workflow:

```elixir
defprotocol Runic.Workflow.EventApplicator do
  @doc "Apply this event to the workflow, returning the updated workflow."
  @spec apply(event :: struct(), workflow :: Runic.Workflow.t()) :: Runic.Workflow.t()
  def apply(event, workflow)
end
```

Built-in events implement it using the existing `Workflow` public API:

```elixir
defimpl Runic.Workflow.EventApplicator, for: Runic.Workflow.Events.FactProduced do
  def apply(%{} = e, wf) do
    fact = Runic.Workflow.Fact.new(hash: e.hash, value: e.value, ancestry: e.ancestry)
    wf = Runic.Workflow.log_fact(wf, fact)
    
    case e.ancestry do
      {producer_hash, _} ->
        producer = Map.get(wf.graph.vertices, producer_hash)
        if producer, do: Runic.Workflow.draw_connection(wf, producer, fact, e.producer_label, weight: e.weight || 0), else: wf
      nil -> wf
    end
  end
end
```

`Workflow.apply_event/2` becomes a single-clause dispatcher:

```elixir
def apply_event(%__MODULE__{} = wf, event) when is_struct(event) do
  EventApplicator.apply(event, wf)
end
```

**Pros:**
- Fully extensible — any library can define events and their application logic
- Protocol dispatch is fast (compiled to function lookup, similar overhead to current pattern matching)
- Clean separation — event structs own their application semantics
- Serializer can use `Protocol.extract_impls/1` or a registry to discover event types

**Cons:**
- Event applicators need access to Workflow internals (`graph.vertices`, `mapped`, `draw_connection/4`, `log_fact/2`, `mark_runnable_as_ran/3`). This requires these functions to be public API — some already are (via `@doc` and `@spec`), but some are private helpers.
- Moves logic from one central location (easy to read/audit) to N scattered protocol implementations
- Testing requires the full Workflow context for each event applicator

#### Option B: `Invokable.apply_events/3` — Node-Level Event Application

Extend the `Invokable` protocol with an optional callback that handles event application for events the node type produces:

```elixir
defprotocol Runic.Workflow.Invokable do
  # ... existing callbacks ...

  @doc """
  Optional: Apply node-specific events to the workflow.
  
  Called by apply_runnable/2 for events that are not recognized by the 
  built-in apply_event/2 dispatcher. The implementation should fold the event
  into the workflow and return the updated workflow.
  
  Default implementation returns the workflow unchanged.
  """
  @spec apply_node_event(node :: struct(), event :: struct(), workflow :: Runic.Workflow.t()) :: Runic.Workflow.t()
  def apply_node_event(node, event, workflow)
end
```

`apply_event/2` gains a fallback clause:

```elixir
# After all built-in event clauses:
def apply_event(%__MODULE__{} = wf, event) when is_struct(event) do
  # Try to find the producing node via event metadata
  node_hash = event_producer_hash(event)
  node = Map.get(wf.graph.vertices, node_hash)
  
  if node do
    Invokable.apply_node_event(node, event, wf)
  else
    wf
  end
end
```

**Pros:**
- Keeps event application co-located with the node type (same Invokable impl module)
- No new protocol — extends existing one
- Node is available in scope — can make node-specific decisions

**Cons:**
- Requires events to carry a `node_hash` field for dispatch (or a convention to extract it)
- Couples event application to the producing node type — some events (like `ActivationConsumed`) are generic and not node-specific
- During replay, the node must exist in the graph for dispatch to work — problematic if replaying events before the node is added

#### Option C: Hybrid — Protocol for Custom Events, Pattern Matching for Core

Keep the existing `apply_event/2` pattern matching for the 12 built-in event types (fast, auditable, no protocol overhead). Add a protocol-based fallback for unrecognized events:

```elixir
# Built-in events: direct pattern match (existing code, unchanged)
def apply_event(%__MODULE__{} = wf, %FactProduced{} = e), do: ...
def apply_event(%__MODULE__{} = wf, %ActivationConsumed{} = e), do: ...
# ... all 12 built-in clauses ...

# Fallback: protocol dispatch for custom events
def apply_event(%__MODULE__{} = wf, event) when is_struct(event) do
  EventApplicator.apply(event, wf)
end
```

Built-in events do NOT need to implement `EventApplicator` — they're handled by the pattern match clauses before the fallback is reached. Only custom events need the protocol implementation.

**Pros:**
- Zero overhead for built-in events (no protocol dispatch)
- Built-in events remain centralized and auditable in `workflow.ex`
- External libraries only need to implement the protocol for their custom events
- Graceful degradation — if an event has no `EventApplicator` impl, protocol raises a clear error

**Cons:**
- Two dispatch mechanisms for the same concept (pattern match + protocol)
- Built-in events could optionally implement the protocol too for consistency (e.g., for `from_events/1` replay which uses a generic reduce)

#### Option D: Event Registry with Callback Modules

Instead of a protocol, use a registry pattern:

```elixir
defmodule Runic.Workflow.EventRegistry do
  @moduledoc "Registry for custom event types and their application functions."
  
  use Agent
  
  def register(event_module, applicator_module) do
    Agent.update(__MODULE__, &Map.put(&1, event_module, applicator_module))
  end
  
  def applicator_for(event_module) do
    Agent.get(__MODULE__, &Map.get(&1, event_module))
  end
end
```

**Cons:** Runtime state (Agent), not compile-time. More complex. Not idiomatic Elixir. Not recommended.

---

### Recommendation: Option C (Hybrid)

Option C gives us the best of both worlds:

1. **Zero overhead for the common case** — the 12 built-in events hit pattern match clauses before the protocol fallback. Protocol dispatch is never invoked for standard workflows.

2. **Clean extensibility** — external libraries define their event structs and implement `EventApplicator`. The protocol impl has access to the full `%Workflow{}` struct via the public API surface.

3. **No breaking changes** — existing code continues to work. The fallback clause is additive.

4. **Serialization extensibility** — the `Serializer` module already uses ETF (`:erlang.term_to_binary`) which handles any struct. For type-safe deserialization, the protocol's `extract_impls/1` or a simple module attribute registry can enumerate known event types.

### Coordination Extensibility

`maybe_finalize_coordination/2` also needs extensibility. Currently it pattern-matches on `%Join{}` and `%FanIn{}`. For custom coordination nodes:

Add an optional `Invokable` callback:

```elixir
@doc """
Optional: Post-fold coordination finalization.

Called after all events from execute/2 have been folded into the workflow.
Returns {workflow, derived_events} where derived_events have been folded
into the returned workflow.

Default: {workflow, []} (no coordination needed).
"""
@spec finalize_coordination(node :: struct(), workflow :: Runic.Workflow.t(), runnable :: Runnable.t()) :: 
  {Runic.Workflow.t(), [struct()]}
def finalize_coordination(node, workflow, runnable)
```

`maybe_finalize_coordination/2` becomes:

```elixir
defp maybe_finalize_coordination(%__MODULE__{} = wf, %Runnable{node: node} = runnable) do
  Invokable.finalize_coordination(node, wf, runnable)
end
```

Built-in implementations for `Join` and `FanIn` move their existing logic into `finalize_coordination/3`. All other node types return `{wf, []}` via the protocol's default implementation (using `@fallback_to_any true`).

Similarly, `emit_downstream_activations/2` can be dispatched through an optional `Invokable` callback for node types with non-standard activation patterns (like `FanOut` emitting to all downstream for each fact).

### Implementation Plan

#### Phase A: `EventApplicator` Protocol

1. Define `Runic.Workflow.EventApplicator` protocol in `lib/workflow/event_applicator.ex`
2. Add the fallback clause to `Workflow.apply_event/2` (after all built-in clauses)
3. Ensure sufficient public API surface on `Workflow` for applicators:
   - `log_fact/2` — already public
   - `draw_connection/4,5` — already public
   - `mark_runnable_as_ran/3` — already public
   - `prepare_next_runnables/3` — already public
   - Graph vertex access via `workflow.graph.vertices` — struct field, always accessible
   - `mapped` field access — struct field, always accessible
4. Document the extension pattern in the Invokable `@moduledoc` and protocols guide

#### Phase B: `finalize_coordination/3` on Invokable

1. Add `finalize_coordination/3` to the `Invokable` protocol with `@fallback_to_any true`
2. Default implementation returns `{workflow, []}`
3. Move `Join` coordination logic from `maybe_finalize_coordination/2` into `Invokable` impl for `Join`
4. Move `FanIn` coordination logic into `Invokable` impl for `FanIn`
5. Simplify `maybe_finalize_coordination/2` to single-clause delegation

#### Phase C: `emit_downstream/3` on Invokable (Optional)

1. Add optional `emit_downstream/3` callback to `Invokable`
2. Default implementation: find `:flow` successors, draw activation edges for each (current `emit_downstream_activations/2` logic for `%Fact{}` result)
3. `FanOut` overrides to emit per-fact activations
4. Match nodes override to call `prepare_next_runnables/3`

#### Phase D: Serializer Extension

1. Add `Runic.Workflow.EventApplicator` protocol awareness to the Serializer
2. For ETF serialization, no change needed (`:erlang.term_to_binary` handles any struct)
3. For future JSON serialization, add a `to_json/1` / `from_json/1` optional callback to `EventApplicator`
4. Document event schema versioning strategy (version field on events, upcasting during deserialization)

### Validation

- All 793 tests pass unchanged (built-in events still handled by pattern match)
- Add test for custom `Invokable` + custom event + `EventApplicator` round-trip
- Add test for custom coordination node with `finalize_coordination/3`
- Benchmark to verify zero overhead for built-in event path (protocol fallback never reached)

---

## Implementation Order

| Priority | Item | Effort | Breaking |
|----------|------|--------|----------|
| 1 | Item 2: `emit_events` flag | Small | No |
| 2 | Item 3.1: List concatenation fix | Trivial | No |
| 3 | Item 4 Phase A: `EventApplicator` protocol | Medium | No |
| 4 | Item 4 Phase B: `finalize_coordination/3` | Medium | Yes (protocol change) |
| 5 | Item 4 Phase C: `emit_downstream/3` | Small | Yes (protocol change) |
| 6 | Item 4 Phase D: Serializer extension | Small | No |

Items 1–2 can be done immediately with a benchmark re-run to measure improvement. Items 3–6 are architectural and should be done together as a protocol evolution.

### Protocol Evolution Strategy (Items 4B–4C)

Adding callbacks to the `Invokable` protocol is a breaking change for external implementations. Mitigation:

- Use `@fallback_to_any true` on `Invokable` so existing implementations that don't define the new callbacks get sensible defaults
- Alternatively, define `finalize_coordination/3` and `emit_downstream/3` as separate optional protocols (`Runic.Workflow.Coordinator`, `Runic.Workflow.Activator`) that custom nodes can optionally implement. `apply_runnable/2` checks for implementation via `Protocol.impl_for/1` before dispatching.

The separate-protocol approach is cleaner from an extension standpoint — node types opt in to coordination behavior rather than having default no-ops on every Invokable. But it adds protocol lookup overhead. Given that coordination is rare (only Join and FanIn), the lookup cost is acceptable.

**Recommendation:** Separate protocols for coordination and downstream emission. Keep `Invokable` focused on the three-phase prepare/execute contract. This follows the existing pattern where `Component` and `Transmutable` are separate protocols for different concerns.

```elixir
defprotocol Runic.Workflow.Coordinator do
  @moduledoc "Optional protocol for nodes that need post-fold coordination."
  @spec finalize(node :: struct(), workflow :: Runic.Workflow.t(), runnable :: Runic.Workflow.Runnable.t()) ::
    {Runic.Workflow.t(), [struct()]}
  def finalize(node, workflow, runnable)
end

defprotocol Runic.Workflow.Activator do
  @moduledoc "Optional protocol for nodes with custom downstream activation patterns."
  @spec activate_downstream(node :: struct(), workflow :: Runic.Workflow.t(), result :: term()) ::
    Runic.Workflow.t()
  def activate_downstream(node, workflow, result)
end
```

`apply_runnable/2` checks:

```elixir
# Coordination
{wf, derived} = 
  if Runic.Workflow.Coordinator.impl_for(runnable.node) do
    Runic.Workflow.Coordinator.finalize(runnable.node, wf, runnable)
  else
    {wf, []}
  end

# Downstream activation
wf =
  if derived == [] do
    if Runic.Workflow.Activator.impl_for(runnable.node) do
      Runic.Workflow.Activator.activate_downstream(runnable.node, wf, runnable.result)
    else
      default_emit_downstream(wf, runnable)
    end
  else
    wf
  end
```

---

## References

- [Event-Sourced Implementation Plan](eventsourced-implementation-plan.md) — Phase 1–7 design and rationale
- [Benchmark Analysis](eventsourced-benchmark-analysis.md) — Performance comparison data
- [Baseline Benchmarks](baseline-benchmark-results.txt) — Pre-migration numbers
- `lib/workflow.ex` — `apply_event/2` (L641–816), `apply_runnable/2` (L2932–2981), `maybe_finalize_coordination/2` (L3030–3195)
- `lib/workflow/invokable.ex` — Protocol definition and all Invokable implementations
- `lib/workflow/component.ex` — Component protocol (architectural precedent for separate protocols)
- `lib/runic/runner/worker.ex` — Worker event consumption (L219–242), checkpointing (L396–420)
- `lib/runic/runner/store.ex` — Store behaviour definition
