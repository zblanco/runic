# Run from the Runic root: MIX_ENV=test mix run examples/fact_modes/check.exs
require Runic

alias Runic.Examples.{FactBoundary, LocalValue}
alias Runic.Workflow
alias Runic.Workflow.{Execution, Fact}

# A cache client remains in context. The facts contain a portable request/result.
lookup = Runic.step(fn key -> context(:fetch).(key) end, name: :lookup)
definition = Runic.workflow(steps: [lookup])
fetch = fn "invoice-17" -> %{amount: 120} end
cache_context = %{lookup: %{fetch: fetch}}
:ok = Workflow.validate_run_context(definition, cache_context)
true = is_function(fetch, 1)

{_workflow, execution} =
  Workflow.execute(definition, "invoice-17", run_context: cache_context)

[%{amount: 120}] = Execution.outputs(execution)
:ok = FactBoundary.check(Execution.outputs(execution), :output)
IO.puts("Context example: portable request and result; live cache client is transient.")

# Some consumers need a live value in their data. Their adapter owns the wrapper.
first = Runic.step(fn input -> LocalValue.map(input, &Map.put(&1, :stage, 1)) end, name: :first)
second = Runic.step(fn input -> LocalValue.map(input, &Map.put(&1, :stage, 2)) end, name: :second)
local_definition = Runic.workflow(steps: [{first, [second]}])
raw = %{reply_to: self(), request: make_ref(), work: fn x -> x + 1 end}
wrapped = LocalValue.new(raw)
{_local, local_execution} = Workflow.execute(local_definition, wrapped)

[%LocalValue{value: %{stage: 1}}, %LocalValue{value: %{stage: 2}}] =
  Execution.outputs(local_execution)

{:error, %{field: :input, reason: {:unsupported, :local_identity}}} =
  FactBoundary.check(wrapped, :input)

# A root with a supplied digest is only a feasibility probe. Native child
# construction cannot inherit this choice. It is not a supported local mode.
root_probe = fn ->
  digest =
    Runic.Identity.digest(:payload, %{
      codec: :example_local_term,
      digest: :crypto.hash(:sha256, :erlang.term_to_binary(raw, [:deterministic]))
    })

  Fact.new(value: raw, payload_digest: digest)
end

probe = root_probe.()

try do
  Fact.new(value: raw, ancestry: {:probe, probe.hash})
  raise "a native child must reject the raw local value"
rescue
  _ in Runic.Identity.CanonicalError -> :ok
end

iterations = 5_000

measure = fn work ->
  {elapsed, _} = :timer.tc(fn -> for _ <- 1..iterations, do: work.() end)
  elapsed
end

IO.inspect(
  %{
    iterations: iterations,
    wrapped_root_us: measure.(fn -> Fact.new(value: LocalValue.new(raw)) end),
    native_root_probe_us: measure.(root_probe),
    raw_etf_bytes: byte_size(:erlang.term_to_binary(raw, [:deterministic])),
    wrapped_etf_bytes: byte_size(:erlang.term_to_binary(wrapped, [:deterministic]))
  },
  label: "Single-VM sample; root probe excludes inheritance and persistence checks"
)
