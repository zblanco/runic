defmodule Runic.Runner do
  @moduledoc """
  Built-in workflow execution infrastructure.

  Provides supervision, persistence, registry, and lifecycle management
  for running workflows as managed processes.

  ## Starting a Runner

      {:ok, _pid} = Runic.Runner.start_link(name: MyApp.Runner)

  ## Running Workflows

      {:ok, pid} = Runic.Runner.start_workflow(MyApp.Runner, :my_workflow, workflow)
      :ok = Runic.Runner.run(MyApp.Runner, :my_workflow, input)
      {:ok, results} = Runic.Runner.get_results(MyApp.Runner, :my_workflow)
  """

  use Supervisor

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    store_module = Keyword.get(opts, :store, Runic.Runner.Store.ETS)
    store_opts = Keyword.get(opts, :store_opts, []) |> Keyword.put(:runner_name, name)

    task_supervisor_opts = Keyword.get(opts, :task_supervisor, [])

    children = [
      {store_module, store_opts},
      {Registry, keys: :unique, name: Module.concat(name, Registry)},
      build_task_supervisor_child(name, task_supervisor_opts),
      {DynamicSupervisor, name: Module.concat(name, WorkerSupervisor), strategy: :one_for_one}
    ]

    :persistent_term.put({__MODULE__, name, :store_module}, store_module)
    :persistent_term.put({__MODULE__, name, :store_opts}, store_opts)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp build_task_supervisor_child(name, opts) when is_list(opts) do
    {Task.Supervisor, Keyword.put(opts, :name, Module.concat(name, TaskSupervisor))}
  end

  defp build_task_supervisor_child(name, {:partition, n}) do
    {PartitionSupervisor,
     child_spec: Task.Supervisor, name: Module.concat(name, TaskSupervisor), partitions: n}
  end

  # --- Workflow Lifecycle ---

  @doc """
  Starts a new workflow under this runner.

  Returns `{:ok, pid}` or `{:error, {:already_started, pid}}`.
  """
  def start_workflow(runner, workflow_id, workflow, opts \\ []) do
    worker_spec =
      {Runic.Runner.Worker,
       Keyword.merge(opts,
         runner: runner,
         workflow_id: workflow_id,
         workflow: workflow
       )}

    DynamicSupervisor.start_child(
      Module.concat(runner, WorkerSupervisor),
      worker_spec
    )
  end

  @doc """
  Feeds input to a running workflow.
  """
  def run(runner, workflow_id, input, opts \\ []) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:run, input, opts})
    end
  end

  @doc """
  Returns the raw productions from a running workflow.
  """
  def get_results(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_results)
    end
  end

  @doc """
  Returns the full workflow struct from a running workflow.
  """
  def get_workflow(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_workflow)
    end
  end

  @doc """
  Stops a running workflow.

  Options:
    - `persist: true` (default) — saves final state to the store before stopping
    - `persist: false` — stops without saving
  """
  def stop(runner, workflow_id, opts \\ []) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:stop, opts})
    end
  end

  @doc """
  Triggers an explicit checkpoint for a running workflow.

  Persists the current workflow state to the store regardless of
  the configured checkpoint strategy. Useful with `checkpoint_strategy: :manual`.
  """
  def checkpoint(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :checkpoint)
    end
  end

  @doc """
  Lists all active workflow IDs managed by this runner.
  """
  def list_workflows(runner) do
    registry = Module.concat(runner, Registry)

    Registry.select(registry, [
      {{{Runic.Runner.Worker, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
  end

  @doc """
  Looks up the PID of a running workflow by ID.

  Returns `pid` or `nil`.
  """
  def lookup(runner, workflow_id) do
    registry = Module.concat(runner, Registry)

    case Registry.lookup(registry, {Runic.Runner.Worker, workflow_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Resumes a workflow from persisted state.

  Loads the workflow log from the store, rebuilds the workflow via
  `Workflow.from_log/1`, and starts a new Worker.
  """
  def resume(runner, workflow_id, opts \\ []) do
    {store_mod, store_state} = get_store(runner)

    case store_mod.load(workflow_id, store_state) do
      {:ok, log} ->
        workflow = Runic.Workflow.from_log(log)
        start_workflow(runner, workflow_id, workflow, opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the via tuple for addressing a worker through the registry.
  """
  def via(runner, workflow_id) do
    {:via, Registry, {Module.concat(runner, Registry), {Runic.Runner.Worker, workflow_id}}}
  end

  @doc """
  Returns the `{store_module, store_state}` tuple for this runner.

  The store state is initialized lazily on first access and cached in persistent_term.
  """
  def get_store(runner) do
    case :persistent_term.get({__MODULE__, runner, :store}, nil) do
      nil ->
        store_module = :persistent_term.get({__MODULE__, runner, :store_module})
        store_opts = :persistent_term.get({__MODULE__, runner, :store_opts})
        {:ok, store_state} = store_module.init_store(store_opts)
        :persistent_term.put({__MODULE__, runner, :store}, {store_module, store_state})
        {store_module, store_state}

      result ->
        result
    end
  end
end
