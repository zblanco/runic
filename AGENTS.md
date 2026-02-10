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

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`
- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason