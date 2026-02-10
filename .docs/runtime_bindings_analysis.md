# Runtime Bindings & Environment Context Analysis

## Current Architecture

### How It Works Now

1. **Macro-Time Analysis** (`traverse_expression/2`)
   - Walks function AST to identify free variables (variables not in function params)
   - Skips nested functions (line 735-738)
   - Captures both pinned (`^var`) and unpinned (`var`) references
   - Excludes special forms (`__MODULE__`, `__ENV__`, etc.)

2. **Binding Capture** (`build_bindings/2`, line 1302-1319)
   ```elixir
   %{
     outer_var: 42,
     multiplier: 5,
     __caller_context__: %Macro.Env{...}  # <-- PROBLEM
   }
   ```

3. **Serialization** (`Workflow.build_log/1`)
   - Creates `%ComponentAdded{}` events with:
     - `source`: Quoted AST (serializable)
     - `bindings`: Map with values + `__caller_context__`
   - Uses `term_to_binary/1` for hashing

4. **Deserialization** (`Workflow.from_log/1`, lines 313-347)
   - Extracts `__caller_context__` from bindings
   - Rebuilds `Macro.Env` with imports/context modules
   - Calls `Code.eval_quoted(source, bindings, env)`

### The Problem

**`%Macro.Env{}` is NOT serializable with `term_to_binary/1`:**

```elixir
iex> :erlang.term_to_binary(%Macro.Env{})
# Works but loses critical compile-time information
# Cannot reliably reconstruct the exact environment
```

**Specific issues:**
- Functions in `Macro.Env` (callbacks, tracers) cannot serialize
- Module references may not exist when deserializing
- Lexical scope information is compile-time only
- File/line metadata is contextual, not portable

---

## Alternative Approaches

### Option 1: Explicit Closure Reification (Runtime Function Construction)

**Idea:** Instead of storing AST + bindings, store a data structure that can rebuild the closure.

```elixir
defmodule Runic.Closure do
  @moduledoc "Serializable closure representation"
  
  defstruct [
    :ast,           # The function AST
    :bindings,      # Map of variable name => value
    :imports,       # List of {module, opts} for required imports
    :aliases,       # List of {alias, module} pairs
    :module_context # String module name where defined
  ]
  
  def new(ast, bindings, caller) do
    %__MODULE__{
      ast: ast,
      bindings: Map.delete(bindings, :__caller_context__),
      imports: extract_imports(caller),
      aliases: extract_aliases(caller),
      module_context: caller.module
    }
  end
  
  defp extract_imports(%Macro.Env{} = env) do
    # Extract only what's needed for evaluation
    Enum.map(env.requires, fn mod -> {mod, []} end) ++
    Enum.map(env.functions, fn {mod, _funs} -> {mod, [only: :functions]} end)
  end
  
  defp extract_aliases(%Macro.Env{} = env) do
    Enum.map(env.aliases, fn {short, full} -> {short, full} end)
  end
  
  def eval(%__MODULE__{} = closure, args \\ []) do
    # Build minimal evaluation environment
    env = build_eval_env(closure)
    
    # Apply bindings and evaluate
    Code.eval_quoted(closure.ast, Map.to_list(closure.bindings), env)
  end
  
  defp build_eval_env(closure) do
    base_env = __ENV__
    
    # Apply imports
    env = Enum.reduce(closure.imports, base_env, fn {mod, _opts}, acc ->
      case Code.ensure_loaded(mod) do
        {:module, _} -> Macro.Env.define_import(acc, [], mod) |> elem(1)
        _ -> acc
      end
    end)
    
    # Apply aliases
    %{env | aliases: closure.aliases}
  end
end
```

**In Components:**
```elixir
defmodule Runic.Workflow.Step do
  defstruct [
    :name,
    :hash,
    :closure,  # %Runic.Closure{} instead of raw function
    :source,
    :bindings
  ]
end
```

**Pros:**
- Explicit about what environment context is captured
- Serializable with `term_to_binary/1`
- Can reconstruct minimal necessary environment
- Clear separation of concerns

**Cons:**
- More complex implementation
- May miss edge cases (macros, special forms)
- Runtime overhead for environment reconstruction


### Option 2: Module-Based Component Registry

**Idea:** Generate modules at compile-time for each component, eliminating runtime bindings.

```elixir
defmacro step(work) do
  {rewritten_work, bindings} = traverse_expression(work, __CALLER__)
  
  # Generate a unique module for this step
  module_name = unique_module_name(__CALLER__, bindings)
  
  quote do
    defmodule unquote(module_name) do
      # Bake bindings into module attributes
      unquote_splicing(
        for {var, val} <- bindings do
          quote do: @var unquote(var)
        end
      )
      
      def work, do: unquote(rewritten_work)
      def bindings, do: unquote(bindings)
      def source, do: unquote(Macro.escape(work))
    end
    
    %Step{
      name: unquote(module_name),
      work: &unquote(module_name).work/0,
      source: {unquote(module_name), :source, 0},
      bindings: {unquote(module_name), :bindings, 0}
    }
  end
end
```

**Serialization:**
```elixir
# Store MFA tuples instead of closures
%ComponentAdded{
  source: {MyApp.Steps.Step_abc123, :source, 0},
  bindings: {MyApp.Steps.Step_abc123, :bindings, 0}
}
```

**Pros:**
- Completely serializable (MFA tuples)
- No runtime environment reconstruction needed
- Deterministic naming via content hashing
- BEAM-native approach

**Cons:**
- Module proliferation (could be thousands)
- Compile-time overhead
- Module hot-swapping complexity
- Not truly "runtime defined"


### Option 3: Binding Substitution (Inline Values into AST)

**Idea:** Rewrite the AST to inline captured values as literals, eliminating bindings entirely.

```elixir
defp inline_bindings({:fn, meta, clauses}, bindings) do
  new_clauses = Enum.map(clauses, fn {:->, cm, [args, body]} ->
    new_body = Macro.prewalk(body, fn
      {var, vm, ctx} when is_atom(var) and is_map_key(bindings, var) ->
        # Replace variable with its literal value
        quote do: unquote(bindings[var])
        
      node -> node
    end)
    
    {:->, cm, [args, new_body]}
  end)
  
  {:fn, meta, new_clauses}
end
```

**Example transformation:**
```elixir
# Before (with binding)
outer_var = 100
fn x -> x * outer_var end
# bindings: %{outer_var: 100}

# After (inlined)
fn x -> x * 100 end
# bindings: %{}
```

**Pros:**
- Completely eliminates binding storage
- Pure AST is serializable
- Simplest deserialization (just eval AST)
- No environment context needed

**Cons:**
- **Cannot handle all value types** (functions, PIDs, refs, ports)
- **Cannot handle mutable references** (changing values)
- **AST size explosion** for large data structures
- Loses semantic information about what was captured


### Option 4: Hybrid - Serializable Bindings Only

**Idea:** Split bindings into serializable and non-serializable, handle each differently.

```elixir
defmodule Runic.BindingClassifier do
  def classify(bindings) do
    Enum.reduce(bindings, {%{}, %{}, []}, fn {k, v}, {serializable, refs, errors} ->
      cond do
        is_serializable?(v) ->
          {Map.put(serializable, k, v), refs, errors}
          
        is_reference_type?(v) ->
          {serializable, Map.put(refs, k, reference_descriptor(v)), errors}
          
        true ->
          {serializable, refs, [{k, v, :unsupported} | errors]}
      end
    end)
  end
  
  defp is_serializable?(val) do
    try do
      :erlang.term_to_binary(val)
      :erlang.binary_to_term(:erlang.term_to_binary(val)) == val
    rescue
      _ -> false
    end
  end
  
  defp is_reference_type?(val) when is_function(val), do: true
  defp is_reference_type?(val) when is_pid(val), do: true
  defp is_reference_type?(val) when is_reference(val), do: true
  defp is_reference_type?(val) when is_port(val), do: true
  defp is_reference_type?(_), do: false
  
  defp reference_descriptor(fun) when is_function(fun) do
    case Function.info(fun) do
      [module: m, name: f, arity: a, type: :external] ->
        {:mfa, m, f, a}
      _ ->
        {:error, :anonymous_function}
    end
  end
  
  defp reference_descriptor(pid) when is_pid(pid) do
    {:pid, registered_name(pid) || :anonymous}
  end
  
  defp reference_descriptor(val), do: {:error, {:unsupported, val}}
end
```

**In component creation:**
```elixir
{serializable, refs, errors} = BindingClassifier.classify(bindings)

unless Enum.empty?(errors) do
  raise ArgumentError, """
  Cannot serialize bindings: #{inspect(errors)}
  
  Suggestion: Use captured functions `&Mod.fun/arity` instead of anonymous functions
  """
end

%Step{
  bindings: serializable,
  references: refs,  # MFA tuples, named process references
  ...
}
```

**Pros:**
- Clear error messages when unsupported
- Handles common cases (numbers, strings, atoms, lists, maps)
- Can support external functions via MFA
- Fail-fast on truly unsupported types

**Cons:**
- Still doesn't solve `__caller_context__` problem
- Limited to simple value types
- Doesn't support closures over other closures


### Option 5: Event Sourcing with Replay

**Idea:** Instead of serializing components, serialize the *operations* that created them.

```elixir
defmodule Runic.BuildEvent do
  defstruct [:type, :module, :code, :context, :timestamp]
end

# Instead of:
step = Runic.step(fn x -> x * outer_var end)

# Log:
%BuildEvent{
  type: :step_definition,
  module: __MODULE__,
  code: "fn x -> x * outer_var end",  # String source
  context: %{
    file: __ENV__.file,
    line: __ENV__.line,
    bindings: %{outer_var: 100}
  }
}
```

**Replay:**
```elixir
defmodule Runic.Replayer do
  def replay_build_log(events, initial_bindings \\ %{}) do
    Enum.reduce(events, {Workflow.new(), initial_bindings}, fn event, {wrk, bindings} ->
      case event.type do
        :step_definition ->
          # Compile and evaluate in current context with merged bindings
          {component, new_bindings} = 
            compile_step(event.code, Map.merge(bindings, event.context.bindings))
          
          {Workflow.add_step(wrk, component), new_bindings}
          
        :binding_update ->
          {wrk, Map.put(bindings, event.var, event.value)}
      end
    end)
  end
  
  defp compile_step(code_string, bindings) do
    # Parse string to AST
    {ast, _} = Code.string_to_quoted!(code_string)
    
    # Evaluate with bindings
    {fun, _} = Code.eval_quoted(ast, Map.to_list(bindings))
    
    {%Step{work: fun, bindings: bindings}, bindings}
  end
end
```

**Pros:**
- Source code is always serializable (strings)
- Can capture full context at definition time
- Human-readable event log
- Natural audit trail

**Cons:**
- **Security risk**: Evaluating arbitrary code strings
- Parsing overhead on deserialization
- Requires source code preservation
- Version compatibility issues


---

## Recommended Approach: **Hybrid (Option 4) + Explicit Closure (Option 1)**

### Implementation Strategy

1. **Remove `__caller_context__` from bindings entirely**
2. **Extract minimal environment info** (imports, aliases) at macro time
3. **Validate bindings are serializable** at component creation
4. **Store explicit closure metadata** in component structs

### Concrete Changes

#### 1. New Closure Metadata Struct

```elixir
# lib/runic/closure_metadata.ex
defmodule Runic.ClosureMetadata do
  @moduledoc """
  Serializable metadata for reconstructing closures from logs.
  """
  
  defstruct [
    :imports,    # [{module, opts}]
    :aliases,    # [{short, full}]
    :requires    # [module]
  ]
  
  def from_caller(%Macro.Env{} = env) do
    %__MODULE__{
      imports: extract_imports(env),
      aliases: env.aliases,
      requires: env.requires
    }
  end
  
  defp extract_imports(env) do
    # Only capture module names, not the full function lists
    Enum.map(env.functions ++ env.macros, fn {mod, _} -> mod end)
    |> Enum.uniq()
  end
  
  def to_eval_env(%__MODULE__{} = meta, base_env \\ __ENV__) do
    env = base_env
    
    # Apply requires
    env = %{env | requires: meta.requires}
    
    # Apply aliases
    env = %{env | aliases: meta.aliases}
    
    # Apply imports (best effort)
    env = Enum.reduce(meta.imports, env, fn mod, acc ->
      case Code.ensure_loaded(mod) do
        {:module, ^mod} ->
          case Macro.Env.define_import(acc, [], mod) do
            {:ok, new_env} -> new_env
            {:error, _} -> acc
          end
        _ -> acc
      end
    end)
    
    env
  end
end
```

#### 2. Update `build_bindings/2`

```elixir
defp build_bindings(variable_bindings, caller_context) do
  if not Enum.empty?(variable_bindings) do
    # Build bindings map
    bindings_ast = quote do
      %{
        unquote_splicing(
          Enum.map(variable_bindings, fn {:=, _, [{left_var, _, _}, right]} ->
            {left_var, right}
          end)
        )
      }
    end
    
    # Extract closure metadata at compile time
    closure_metadata = Runic.ClosureMetadata.from_caller(caller_context)
    
    quote do
      bindings = unquote(bindings_ast)
      
      # Validate all bindings are serializable
      Enum.each(bindings, fn {key, val} ->
        case Runic.BindingValidator.check(val) do
          :ok -> :ok
          {:error, reason} ->
            raise ArgumentError, """
            Cannot serialize binding `#{key}` in component: #{reason}
            
            Value: #{inspect(val, limit: 3)}
            
            Only serializable values are supported in runtime bindings.
            Use module functions (&Module.function/arity) instead of closures.
            """
        end
      end)
      
      {bindings, unquote(Macro.escape(closure_metadata))}
    end
  else
    quote do
      {%{}, nil}
    end
  end
end
```

#### 3. Update Component Structs

```elixir
# lib/runic/workflow/step.ex
defmodule Runic.Workflow.Step do
  defstruct [
    :name,
    :work,
    :hash,
    :work_hash,
    :source,
    :bindings,           # Map of var => serializable_value
    :closure_metadata,   # %Runic.ClosureMetadata{} | nil
    :inputs,
    :outputs
  ]
  
  # ... existing code ...
end
```

#### 4. Update Macro Code Generation

```elixir
# In step/1 macro (line 110)
quote do
  {bindings, closure_metadata} = unquote(bindings)
  step_hash = Components.fact_hash({unquote(Macro.escape(source)), bindings})
  work_hash = Components.fact_hash({unquote(Macro.escape(work)), bindings})

  Step.new(
    work: unquote(rewritten_work),
    source: unquote(Macro.escape(source)),
    name: unquote(default_component_name("step", "_")) <> "_#{step_hash}",
    hash: step_hash,
    work_hash: work_hash,
    bindings: bindings,
    closure_metadata: closure_metadata,
    inputs: nil,
    outputs: nil
  )
end
```

#### 5. Update Deserialization

```elixir
# In workflow.ex component_from_added/1
defp component_from_added(%ComponentAdded{
  source: source,
  bindings: bindings,
  closure_metadata: closure_metadata
} = event) do
  # Build evaluation environment from metadata
  env = if closure_metadata do
    Runic.ClosureMetadata.to_eval_env(closure_metadata, build_eval_env())
  else
    build_eval_env()
  end
  
  # Evaluate with clean bindings (no __caller_context__)
  {component, _} = Code.eval_quoted(source, Map.to_list(bindings), env)
  
  Map.put(component, :name, event.name)
end
```

#### 6. Add Binding Validator

```elixir
# lib/runic/binding_validator.ex
defmodule Runic.BindingValidator do
  @moduledoc """
  Validates that bindings can be serialized with term_to_binary/1.
  """
  
  def check(value) do
    try do
      binary = :erlang.term_to_binary(value)
      roundtrip = :erlang.binary_to_term(binary)
      
      if value == roundtrip do
        :ok
      else
        {:error, "Value does not roundtrip through serialization"}
      end
    rescue
      ArgumentError ->
        {:error, detailed_error(value)}
    end
  end
  
  defp detailed_error(value) when is_function(value) do
    case Function.info(value) do
      [module: m, name: f, arity: a, type: :external] ->
        "Anonymous function. Use &#{m}.#{f}/#{a} instead"
      _ ->
        "Anonymous closure cannot be serialized"
    end
  end
  
  defp detailed_error(value) when is_pid(value) do
    "PIDs cannot be serialized across sessions"
  end
  
  defp detailed_error(value) when is_reference(value) do
    "References cannot be serialized"
  end
  
  defp detailed_error(value) when is_port(value) do
    "Ports cannot be serialized"
  end
  
  defp detailed_error(_value) do
    "Value type is not serializable"
  end
end
```

---

## Migration Path

1. **Phase 1**: Add validation (non-breaking)
   - Add `BindingValidator` with warnings (not errors)
   - Add `ClosureMetadata` struct
   - Update component structs to include `closure_metadata` field

2. **Phase 2**: Update macro code generation
   - Modify `build_bindings/2` to return `{bindings, metadata}` tuple
   - Update all macro definitions to use new format
   - Keep backward compatibility for existing logs

3. **Phase 3**: Update deserialization
   - Modify `component_from_added/1` to handle both old and new formats
   - Prefer `closure_metadata` when available, fall back to `__caller_context__`

4. **Phase 4**: Remove `__caller_context__` (breaking)
   - Remove `__caller_context__` from `build_bindings/2`
   - Turn binding validation errors from warnings to exceptions
   - Update all tests

---

## Testing Strategy

```elixir
# test/closure_serializability_test.exs
defmodule Runic.ClosureSerializabilityTest do
  use ExUnit.Case
  
  test "serializable bindings roundtrip correctly" do
    outer_val = 42
    step = Runic.step(fn x -> x + outer_val end)
    
    # Serialize
    binary = :erlang.term_to_binary(step.bindings)
    
    # Deserialize
    roundtrip = :erlang.binary_to_term(binary)
    
    assert roundtrip == step.bindings
  end
  
  test "unsupported bindings raise helpful errors" do
    unsupported_fn = fn -> :ok end
    
    assert_raise ArgumentError, ~r/Cannot serialize binding/, fn ->
      Runic.step(fn x -> x + unsupported_fn.() end)
    end
  end
  
  test "workflow can be rebuilt from log with serializable bindings" do
    multiplier = 10
    
    wrk = Runic.workflow(
      steps: [
        Runic.step(fn x -> x * multiplier end, name: :multiply)
      ]
    )
    
    log = Runic.Workflow.build_log(wrk)
    
    # Serialize and deserialize the log
    binary = :erlang.term_to_binary(log)
    deserialized_log = :erlang.binary_to_term(binary)
    
    # Rebuild workflow
    rebuilt = Runic.Workflow.from_log(deserialized_log)
    
    # Verify it works
    result = Runic.Workflow.react_until_satisfied(rebuilt, 5)
    assert 50 in Runic.Workflow.raw_productions(result)
  end
  
  test "closure metadata preserves imports" do
    wrk = Runic.workflow(
      steps: [
        Runic.step(fn list -> Enum.map(list, &(&1 * 2)) end)
      ]
    )
    
    log = Runic.Workflow.build_log(wrk)
    rebuilt = Runic.Workflow.from_log(log)
    
    # Should still have access to Enum
    result = Runic.Workflow.react_until_satisfied(rebuilt, [1, 2, 3])
    assert [2, 4, 6] in Runic.Workflow.raw_productions(result)
  end
end
```

---

## Open Questions

1. **What about external function captures?**
   - `&MyModule.function/2` - Need to ensure module is loaded
   - Store as MFA tuple instead of function reference?

2. **How to handle evolving code?**
   - Workflow created with version 1, deserialized in version 2
   - Module refactoring changes function signatures
   - Consider versioning in `ClosureMetadata`?

3. **Performance implications?**
   - Validation overhead at component creation
   - Environment reconstruction overhead at deserialization
   - Cache reconstructed environments?

4. **Distributed system concerns?**
   - Different nodes may have different modules loaded
   - How to handle missing modules gracefully?
   - Consider shipping bytecode with logs?

