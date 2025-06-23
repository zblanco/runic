# Runic Agent Guide

Runic is a purely functional workflow composition tool useful for dataflow parallel data pipelines,
rule based expert systems, and low-code workflow engine functionality.

Runic is uniquely designed to be purely functional and lazily evaluated using a performant multigraph DAG & label indexed model. This design enables Runic to not assume runtime topology
and support any user desired process model be it 1-node, distributed, or using any kind of process(s) for the rich Elixir / Erlang / OTP ecosystem.

Runic nodes are typically struct wrappers around a function to produce values that flow downward to next runnable nodes. Values are wrapped in %Fact{} structs and causal reactions are represented by labeled edges for memory.

## Build/Test Commands
- `mix test` - Run all tests
- `mix test test/specific_test.exs` - Run specific test file
- `mix test test/specific_test.exs:123` - Run specific test line
- `mix compile` - Compile the project
- `mix format` - Format code according to .formatter.exs
- `mix deps.get` - Get dependencies
- `mix clean` - Clean compiled files

## Architecture
- **Core modules**: `Runic` (main API mostly construction via macros), `Runic.Workflow` (workflow engine runtime)
- **Components**: Step, Rule, Condition, Map, Reduce, StateMachine, Join
- **Graph-based**: Uses libgraph for DAG (directed acyclic graph) representation
    - Uses an adjacency index in a multigraph structure for efficient traversal across kinds of edges
- **Protocols**: `Invokable`, `Component`, `Transmutable` for extensibility
- **Dataflow**: Facts flow through Steps connected by edges in the workflow graph

## Code Style & Conventions
- Use `mix format` for automatic formatting
- Follow Elixir naming: snake_case for variables/functions, PascalCase for modules
- Import order: Standard library, external deps, internal modules (alias first)  
- Pattern matching preferred over conditionals
- Use `with` for multiple success/failure operations
- Module attributes for compile-time configuration
- Protocols for extensible behavior (see existing Invokable, Component protocols)
