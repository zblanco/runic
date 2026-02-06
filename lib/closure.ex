defmodule Runic.Closure do
  @moduledoc """
  Serializable closure representation for Runic components.

  A Closure combines the source AST, runtime bindings, and compile-time
  metadata into a single serializable structure. This allows components
  to be reconstructed from logs using `term_to_binary/1` and `binary_to_term/1`.

  ## Fields

  - `:source` - The original quoted AST for the closure
  - `:bindings` - Map of variable names to their captured values
  - `:metadata` - `%Runic.ClosureMetadata{}` for environment reconstruction
  - `:hash` - Content-addressable hash of the closure

  ## Examples

      outer_var = 42
      
      closure = Runic.Closure.new(
        quote(do: fn x -> x + outer_var end),
        %{outer_var: 42},
        __ENV__
      )
      
      # Closures are serializable
      binary = :erlang.term_to_binary(closure)
      roundtrip = :erlang.binary_to_term(binary)
      
      # Can be evaluated in a different context
      {fun, _} = Runic.Closure.eval(closure)
      fun.(10) # => 52
  """

  alias Runic.ClosureMetadata
  alias Runic.Workflow.Components

  @type t :: %__MODULE__{
          source: Macro.t(),
          bindings: map(),
          metadata: ClosureMetadata.t() | nil,
          hash: integer() | nil
        }

  @derive {Inspect, only: [:hash, :bindings]}
  defstruct [
    # Quoted AST
    :source,
    # Map of var => value
    :bindings,
    # %ClosureMetadata{}
    :metadata,
    # Content hash
    :hash
  ]

  @doc """
  Creates a new Closure from source AST, bindings, and caller environment.

  Validates that all bindings are serializable before creating the closure.
  Raises `ArgumentError` if any binding contains non-serializable values.
  """
  def new(source, bindings, caller_env_or_metadata)

  def new(source, bindings, %Macro.Env{} = caller) when is_map(bindings) do
    # Validate bindings are serializable
    validate_bindings!(bindings)

    # Extract metadata from caller environment
    metadata = ClosureMetadata.from_caller(caller)

    # Compute hash from source and bindings
    hash = Components.fact_hash({source, bindings})

    %__MODULE__{
      source: source,
      bindings: bindings,
      metadata: metadata,
      hash: hash
    }
  end

  def new(source, bindings, %ClosureMetadata{} = metadata) when is_map(bindings) do
    # Validate bindings are serializable
    validate_bindings!(bindings)

    # Compute hash from source and bindings
    hash = Components.fact_hash({source, bindings})

    %__MODULE__{
      source: source,
      bindings: bindings,
      metadata: metadata,
      hash: hash
    }
  end

  def new(source, bindings, nil) when is_map(bindings) do
    # No metadata case - for closures without environment dependencies
    validate_bindings!(bindings)

    hash = Components.fact_hash({source, bindings})

    %__MODULE__{
      source: source,
      bindings: bindings,
      metadata: nil,
      hash: hash
    }
  end

  @doc """
  Evaluates a closure, returning the result and updated bindings.

  This reconstructs the evaluation environment from the closure's metadata
  and evaluates the source AST with the stored bindings.

  ## Options

  - `:base_env` - Override the base environment for evaluation
  """
  def eval(%__MODULE__{} = closure, opts \\ []) do
    # Build evaluation environment from metadata
    env =
      if closure.metadata do
        ClosureMetadata.to_eval_env(closure.metadata, opts)
      else
        build_minimal_env()
      end

    # Convert bindings map to keyword list for evaluation
    binding_list = Map.to_list(closure.bindings)

    # Evaluate the source with bindings
    # Note: This works because the original macro expansion in Runic.step
    # already rewrites the AST to use the binding values
    Code.eval_quoted(closure.source, binding_list, env)
  end

  @doc """
  Validates that a value can be serialized with `term_to_binary/1`.

  Returns `:ok` if serializable, `{:error, reason}` otherwise.

  Note: PIDs, references, and ports can technically be serialized but they
  are not valid across sessions/nodes, so we reject them.
  """
  def validate_value(value) do
    cond do
      # Reject runtime-specific values even though they serialize
      is_pid(value) ->
        {:error, detailed_error(value)}

      is_reference(value) ->
        {:error, detailed_error(value)}

      is_port(value) ->
        {:error, detailed_error(value)}

      is_function(value) ->
        # Check if it's an external function (those are OK)
        info = Function.info(value)

        case Keyword.get(info, :type) do
          :external ->
            :ok

          _ ->
            {:error, detailed_error(value)}
        end

      true ->
        # Try serialization roundtrip
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
            {:error, "Value cannot be serialized"}
        end
    end
  end

  @doc """
  Validates that all bindings in a map are serializable.

  Raises `ArgumentError` if any binding is not serializable.
  """
  def validate_bindings!(bindings) when is_map(bindings) do
    Enum.each(bindings, fn {key, value} ->
      case validate_value(value) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError, """
          Cannot serialize binding `#{key}` in closure: #{reason}

          Value: #{inspect(value, limit: 3)}

          Only serializable values are supported in runtime bindings.
          Use module functions (&Module.function/arity) instead of closures.
          """
      end
    end)

    :ok
  end

  # Provide detailed error messages for common non-serializable types
  defp detailed_error(value) when is_function(value) do
    case Function.info(value) do
      [module: m, name: f, arity: a, type: :external] ->
        "Anonymous function (use &#{m}.#{f}/#{a} instead)"

      info when is_list(info) ->
        case Keyword.get(info, :type) do
          :local ->
            "Anonymous closure cannot be serialized (captures local variables)"

          _ ->
            "Anonymous function cannot be serialized"
        end

      _ ->
        "Anonymous function cannot be serialized"
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

  # Build a minimal evaluation environment
  # We cache the environment in the process dictionary to avoid recreating it
  defp build_minimal_env do
    case Process.get({__MODULE__, :base_env}) do
      nil ->
        # Create a clean environment with necessary imports
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

        env = result |> Macro.Env.prune_compile_info() |> Code.env_for_eval()
        Process.put({__MODULE__, :base_env}, env)
        env

      env ->
        env
    end
  end
end
