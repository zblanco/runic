# Usage: mix run bench/issue19/run.exs --label baseline --sizes 128,512 --cases collect,sum
# Independent passes: --pass timing (3 samples), memory, envelopes. Default: all.
# --preparation eager|bounded --execution inline|task|peer_tcp --coordination legacy|batch
Code.ensure_loaded!(Runic.Workflow)

compiled =
  for file <- ["scenarios.ex", "runner.ex", "measure.ex"],
      pair <- Code.compile_file(Path.join(__DIR__, file)),
      do: pair

{opts, [], []} =
  OptionParser.parse(System.argv(),
    strict: [
      label: :string,
      sizes: :string,
      cases: :string,
      preparation: :string,
      execution: :string,
      coordination: :string,
      limit: :integer,
      concurrency: :integer,
      pass: :string,
      repeats: :integer
    ]
  )

allowed = fn value, choices ->
  Enum.find(choices, &(Atom.to_string(&1) == value)) || raise("invalid option #{value}")
end

config = %{
  label: opts[:label] || "unnamed",
  preparation: allowed.(opts[:preparation] || "eager", [:eager, :bounded]),
  execution: allowed.(opts[:execution] || "inline", [:inline, :task, :peer_tcp]),
  coordination: allowed.(opts[:coordination] || "legacy", [:legacy, :batch]),
  limit: opts[:limit] || 64,
  concurrency: opts[:concurrency] || 8,
  peer: nil
}

sizes = String.split(opts[:sizes] || "128,512", ",") |> Enum.map(&String.to_integer/1)

cases =
  String.split(opts[:cases] || "collect,sum,deep,binary,repeated,stream", ",")
  |> Enum.map(
    &allowed.(&1, [:collect, :sum, :deep, :binary, :repeated, :stream, :slow_first, :latency])
  )

if config.preparation == :bounded and
     not function_exported?(Runic.Workflow, :prepare_for_dispatch, 2),
   do: raise("bounded preparation unavailable on this branch")

if config.coordination == :batch and not Map.has_key?(%Runic.Workflow.FanIn{}, :coordination),
  do: raise("batch coordination unavailable on this branch")

peer =
  if config.execution == :peer_tcp do
    # Alternative peer RPC over loopback TCP: separate VM and real serialization,
    # not native Erlang distribution, not WAN latency. Startup excluded from timing.
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: {{127, 0, 0, 1}, 0},
        args: [~c"+S", ~c"2:2"],
        wait_boot: 30_000
      })

    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:runic])

    for {module, binary} <- compiled do
      {:module, ^module} =
        :peer.call(peer, :code, :load_binary, [module, ~c"issue19-bench", binary])
    end

    peer
  end

config = %{config | peer: peer}

columns = [
  :label,
  :pass,
  :repeat,
  :case,
  :n,
  :preparation,
  :execution,
  :coordination,
  :limit,
  :concurrency,
  :elapsed_us,
  :waves,
  :prepared,
  :fan_in_prepared,
  :max_prepared,
  :facts,
  :edges,
  :mapped_entries,
  :request_bytes,
  :response_bytes,
  :max_request_bytes,
  :request_flat_words,
  :max_context_words,
  :retained_external_bytes,
  :owner_peak_bytes,
  :tree_peak_bytes,
  :referenced_binary_peak_bytes,
  :descendant_count,
  :result_ok
]

IO.puts(
  "# commit=#{System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim()} elixir=#{System.version()} otp=#{System.otp_release()} schedulers=#{System.schedulers_online()}"
)

IO.puts(Enum.join(columns, ","))

try do
  for kind <- cases do
    warm = Map.merge(config, %{case: kind, n: 8})
    Runic.Bench.Issue19.Measure.timing(warm)

    for n <- sizes do
      c = Map.merge(config, %{case: kind, n: n})

      passes =
        if (opts[:pass] || "all") == "all",
          do: [:timing, :memory, :envelopes],
          else: [allowed.(opts[:pass], [:timing, :memory, :envelopes])]

      for pass <- passes, repeat <- 1..if(pass == :timing, do: opts[:repeats] || 3, else: 1) do
        measurements = apply(Runic.Bench.Issue19.Measure, pass, [c])
        row = Map.merge(c, measurements) |> Map.merge(%{pass: pass, repeat: repeat})
        IO.puts(Enum.map_join(columns, ",", &Map.get(row, &1, "")))
      end
    end
  end
after
  if peer, do: :peer.stop(peer)
end
