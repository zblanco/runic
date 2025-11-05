defmodule Runic.ClosureMetadata do
  @moduledoc """
  Serializable metadata for reconstructing closures from logs.

  This struct captures the minimal compile-time environment information needed
  to reconstruct a closure in a different runtime context. Unlike `%Macro.Env{}`,
  this struct only contains serializable data (atoms, lists, module names).

  ## Fields

  - `:imports` - List of module names that were imported in the calling context
  - `:aliases` - List of `{short_alias, full_module}` tuples
  - `:requires` - List of module names that were required

  ## Examples

      iex> metadata = Runic.ClosureMetadata.from_caller(__ENV__)
      %Runic.ClosureMetadata{
        imports: [Enum, String],
        aliases: [{MyAlias, My.Full.Module}],
        requires: [Logger]
      }
      
      iex> env = Runic.ClosureMetadata.to_eval_env(metadata)
      # Returns a %Macro.Env{} suitable for Code.eval_quoted/3
  """

  @derive {Inspect, only: [:imports, :aliases, :requires, :module]}
  defstruct [
    # [module_name]
    :imports,
    # [{short, full}]
    :aliases,
    # [module_name]
    :requires,
    # module name where closure was defined
    :module
  ]

  @doc """
  Extracts serializable metadata from a `%Macro.Env{}` struct.

  Only captures module names and alias information - no functions,
  no compile-time state, no context that cannot be serialized.
  """
  def from_caller(%Macro.Env{} = env) do
    %__MODULE__{
      imports: extract_imports(env),
      aliases: env.aliases,
      requires: env.requires,
      module: env.module
    }
  end

  @doc """
  Reconstructs a `%Macro.Env{}` suitable for evaluating quoted code.

  This creates a minimal evaluation environment with the captured
  imports, aliases, and requires restored. Uses best-effort approach
  for imports - if a module isn't loaded, it's skipped.

  ## Options

  - `:base_env` - Base environment to start from (defaults to current __ENV__)
  """
  def to_eval_env(%__MODULE__{} = meta, opts \\ []) do
    base_env = Keyword.get(opts, :base_env, build_base_env())

    env = base_env

    # Use the module from metadata if available
    env = if meta.module, do: %{env | module: meta.module}, else: env

    # Apply requires
    env = %{env | requires: meta.requires}

    # Apply aliases
    env = %{env | aliases: meta.aliases}

    # Apply imports (best effort - skip modules that aren't loaded)
    env =
      Enum.reduce(meta.imports, env, fn mod, acc ->
        case Code.ensure_loaded(mod) do
          {:module, ^mod} ->
            case Macro.Env.define_import(acc, [], mod) do
              {:ok, new_env} -> new_env
              {:error, _reason} -> acc
            end

          _ ->
            acc
        end
      end)

    # Convert to eval environment
    env
    |> Macro.Env.prune_compile_info()
    |> Code.env_for_eval()
  end

  # Extract imported module names from environment
  # Only captures module names, not the full function/macro lists
  defp extract_imports(env) do
    imported_modules =
      (env.functions ++ env.macros)
      |> Enum.map(fn {mod, _funs} -> mod end)
      |> Enum.uniq()

    imported_modules
  end

  # Build a base environment for evaluation
  # We cache the environment in the process dictionary to avoid recreating it
  defp build_base_env do
    case Process.get({__MODULE__, :base_env}) do
      nil ->
        # Create a clean environment with necessary imports
        # We eval in the Elixir module context to get a clean slate
        {result, _} =
          Code.eval_string(
            """
            require Runic
            import Runic
            alias Runic.Workflow
            __ENV__
            """,
            [],
            file: "nofile",
            line: 1
          )

        Process.put({__MODULE__, :base_env}, result)
        result

      env ->
        env
    end
  end
end
