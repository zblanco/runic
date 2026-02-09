# Runic for LLMs & AI Agents — Use Case Exploration

This document explores how Runic's workflow composition primitives map onto the problem space of building AI/LLM-powered agents. It walks through a fully integrated AI chat agent design, demonstrates several Runic modeling approaches for LLM workflows, and ends with a wishlist of Runic features that would simplify these use cases.

All LLM API interaction uses [ReqLLM](https://hexdocs.pm/req_llm/ReqLLM.html).

---

## Table of Contents

- [Part 1: Conceptual Mapping](#part-1-conceptual-mapping)
- [Part 2: Fully Integrated Chat Agent](#part-2-fully-integrated-chat-agent)
  - [Module Outline](#module-outline)
  - [The Workflow Graph](#the-workflow-graph)
  - [Chat Accumulator — The Instruction Loop](#chat-accumulator--the-instruction-loop)
  - [Tool Use Parsing](#tool-use-parsing)
  - [Rules as Command Handlers](#rules-as-command-handlers)
  - [state_of for Flow Control](#state_of-for-flow-control)
  - [Metadata Tracking — Dependent Steps & Reducers](#metadata-tracking--dependent-steps--reducers)
  - [Dynamic Tool Registration](#dynamic-tool-registration)
  - [GenServer Interface — handle_cast for User Input](#genserver-interface--handle_cast-for-user-input)
  - [Runtime Workflow Generation — Complex Tool Calls](#runtime-workflow-generation--complex-tool-calls)
  - [Task Supervisor Pool — Dispatch & Execution](#task-supervisor-pool--dispatch--execution)
  - [handle_info — Apply Phase for Completed Tasks](#handle_info--apply-phase-for-completed-tasks)
  - [Error Handling & Retries](#error-handling--retries)
  - [Rate Limiting & Throttling](#rate-limiting--throttling)
- [Part 3: Alternative Runic Modeling Approaches](#part-3-alternative-runic-modeling-approaches)
- [Part 4: Wishlist — Runic Features for LLM Workflows](#part-4-wishlist--runic-features-for-llm-workflows)

---

## Part 1: Conceptual Mapping

LLM agent loops have a natural correspondence to Runic's primitives:

| LLM Agent Concept | Runic Primitive | Why |
|-|-|-|
| Conversation history | **Accumulator** | Stateful fold over messages — each turn appends to history |
| LLM API call | **Step** | Pure input→output: messages in, response out |
| Tool call dispatch | **Rule** | Pattern match on `finish_reason: :tool_calls`, route to handler |
| Tool result → next turn | **Rule / Step pipeline** | Feed tool results back into accumulator as new facts |
| Multi-step tool plan | **Runtime Workflow** | Build a DAG of dependent tool calls, dispatch as a unit |
| Token/message counters | **Accumulator / Step** | Dependent reducers downstream of the LLM step |
| Rate limiting | **Accumulator + Rule** | Track request timestamps, gate on `state_of(:rate_limiter)` |
| Session lifecycle | **State Machine** | `:idle → :generating → :tool_calling → :idle` |

---

## Part 2: Fully Integrated Chat Agent

### Module Outline

```elixir
defmodule MyApp.Agent do
  @moduledoc """
  A dynamically supervised GenServer chat agent backed by a Runic workflow.
  Each session is a separate process registered via a `:via` tuple.
  """
  use GenServer

  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Invokable

  # --- Public API ---

  def start_link(session_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {session_id, opts}, name: via(session_id))
  end

  def send_message(session_id, content) do
    GenServer.cast(via(session_id), {:user_message, content})
  end

  def add_tool(session_id, tool) do
    GenServer.cast(via(session_id), {:add_tool, tool})
  end

  def remove_tool(session_id, tool_name) do
    GenServer.cast(via(session_id), {:remove_tool, tool_name})
  end

  def get_history(session_id) do
    GenServer.call(via(session_id), :get_history)
  end

  defp via(session_id) do
    {:via, Registry, {MyApp.AgentRegistry, session_id}}
  end

  # --- Callbacks ---

  @impl true
  def init({session_id, opts}) do
    model = opts[:model] || "anthropic:claude-sonnet-4-20250514"
    system_prompt = opts[:system_prompt] || "You are a helpful assistant."
    tools = opts[:tools] || []

    workflow = build_workflow(model, system_prompt, tools)

    state = %{
      session_id: session_id,
      workflow: workflow,
      model: model,
      system_prompt: system_prompt,
      tools: tools,
      pending_tasks: %{},
      subscribers: opts[:subscribers] || []
    }

    {:ok, state}
  end

  # ... (continued in sections below)
end
```

### The Workflow Graph

The agent's core workflow is a DAG with the following shape:

```
                    ┌──────────┐
                    │   root   │
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │  :chat   │  (accumulator — message history)
                    │  history │
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │ :llm_call│  (step — ReqLLM.generate_text)
                    └────┬─────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
         ┌────▼───┐ ┌───▼────┐ ┌──▼──────────┐
         │:parse  │ │:token  │ │:msg_counter  │
         │tool    │ │counter │ │ (accumulator)│
         │calls   │ │(accum) │ └──────────────┘
         └────┬───┘ └────────┘
              │
     ┌────────▼─────────┐
     │ :tool_dispatch    │
     │ (rule: route to   │
     │  tool handlers)   │
     └────────┬──────────┘
              │
     ┌────────▼──────────┐
     │ :tool_result_to   │
     │ _chat (step: fold │
     │  result back in)  │
     └───────────────────┘
```

### Chat Accumulator — The Instruction Loop

The conversation history is modeled as an accumulator. Each input (user message, tool result, etc.) is reduced into the running context. The accumulator's state *is* the full message list.

```elixir
defp build_chat_accumulator(system_prompt) do
  initial_context = ReqLLM.context(ReqLLM.Context.system(system_prompt))

  Runic.accumulator(
    initial_context,
    fn input, context ->
      case input do
        {:user, content} ->
          msg = ReqLLM.Context.user(content)
          ReqLLM.context([context, msg] |> List.flatten())

        {:assistant, content} ->
          msg = ReqLLM.Context.assistant(content)
          ReqLLM.context([context, msg] |> List.flatten())

        {:tool_result, tool_call_id, result} ->
          msg = ReqLLM.Context.tool_result(tool_call_id, result)
          ReqLLM.context([context, msg] |> List.flatten())

        %ReqLLM.Response{} = response ->
          response.context

        _ ->
          context
      end
    end,
    name: :chat_history
  )
end
```

This is the heart of the agent loop. Every turn — user message, assistant response, tool result — folds through this accumulator. Downstream steps always see the latest conversation state via `state_of(:chat_history)`.

### Tool Use Parsing

A step downstream of the LLM call extracts tool calls from the response:

```elixir
defp build_tool_parser do
  Runic.step(
    fn response ->
      case ReqLLM.Response.finish_reason(response) do
        :tool_calls ->
          tool_calls = ReqLLM.Response.tool_calls(response)
          {:tool_calls, tool_calls, response}

        :stop ->
          text = ReqLLM.Response.text(response)
          {:text_response, text, response}

        :length ->
          {:max_tokens_reached, ReqLLM.Response.text(response), response}

        other ->
          {:unexpected_finish, other, response}
      end
    end,
    name: :parse_response
  )
end
```

### Rules as Command Handlers

Rules pattern-match on the parsed response to route control flow. This is where Runic's rule system shines — each command type gets its own handler:

```elixir
defp build_command_rules(tools) do
  tool_dispatch_rule =
    Runic.rule(
      name: :dispatch_tools,
      condition: fn {:tool_calls, _calls, _resp} -> true end,
      reaction: fn {:tool_calls, calls, response} ->
        {:execute_tools, calls, response}
      end
    )

  text_response_rule =
    Runic.rule(
      name: :handle_text,
      condition: fn {:text_response, _text, _resp} -> true end,
      reaction: fn {:text_response, text, response} ->
        {:assistant_reply, text, response}
      end
    )

  max_tokens_rule =
    Runic.rule(
      name: :handle_max_tokens,
      condition: fn {:max_tokens_reached, _text, _resp} -> true end,
      reaction: fn {:max_tokens_reached, text, response} ->
        {:partial_response, text, response}
      end
    )

  [tool_dispatch_rule, text_response_rule, max_tokens_rule]
end
```

Each rule is added to the workflow as a child of `:parse_response`. The rule engine evaluates all conditions and fires only the matching ones — no manual `cond` or `case` branching needed, and new command types can be added at runtime.

### `state_of` for Flow Control

Runic's `state_of/1` lets rules gate on accumulator state without coupling to the accumulator's internals. This is powerful for controlling the agent loop:

```elixir
max_turns_rule =
  Runic.rule name: :max_turns_guard do
    given(x: x)
    where(state_of(:msg_counter) >= 50)
    then(fn %{x: _x} -> {:error, :max_turns_exceeded} end)
  end

rate_limit_rule =
  Runic.rule name: :rate_limit_guard do
    given(x: x)
    where(state_of(:rate_tracker) |> then(fn tracker ->
      recent = Enum.count(tracker.timestamps, fn t ->
        DateTime.diff(DateTime.utc_now(), t, :second) < 60
      end)
      recent >= tracker.max_per_minute
    end))
    then(fn %{x: _x} -> {:error, :rate_limited} end)
  end

budget_rule =
  Runic.rule name: :budget_guard do
    given(x: x)
    where(state_of(:token_counter) > 100_000)
    then(fn %{x: _x} -> {:error, :token_budget_exceeded} end)
  end
```

These rules sit upstream of the LLM call step. If any fires, the call is short-circuited. The rules compose naturally — adding a new guard is just adding another rule to the workflow at runtime.

### Metadata Tracking — Dependent Steps & Reducers

Accumulators and steps downstream of the LLM call compute running metadata:

```elixir
defp build_metadata_trackers do
  token_counter =
    Runic.accumulator(
      %{input: 0, output: 0, total_cost: 0.0},
      fn response, acc ->
        usage = ReqLLM.Response.usage(response) || %{}
        %{
          input: acc.input + Map.get(usage, :input_tokens, 0),
          output: acc.output + Map.get(usage, :output_tokens, 0),
          total_cost: acc.total_cost + Map.get(usage, :total_cost, 0.0)
        }
      end,
      name: :token_counter
    )

  message_counter =
    Runic.accumulator(
      0,
      fn _response, count -> count + 1 end,
      name: :msg_counter
    )

  latency_tracker =
    Runic.step(
      fn response ->
        %{
          model: response.model,
          finish_reason: ReqLLM.Response.finish_reason(response),
          usage: ReqLLM.Response.usage(response),
          timestamp: DateTime.utc_now()
        }
      end,
      name: :latency_tracker
    )

  {token_counter, message_counter, latency_tracker}
end
```

These are added as children of `:llm_call` in the workflow. They execute in parallel (or in the same react cycle) after each LLM response, keeping counters always in sync.

### Dynamic Tool Registration

Tools are Runic steps that can be added or removed at runtime. The GenServer modifies the workflow graph on the fly:

```elixir
@impl true
def handle_cast({:add_tool, tool_def}, state) do
  tool = ReqLLM.tool(
    name: tool_def.name,
    description: tool_def.description,
    parameters: tool_def.parameters,
    callback: tool_def.callback
  )

  tool_step = Runic.step(
    fn {:execute_tool, ^tool_def.name, args} ->
      case ReqLLM.Tool.execute(tool, args) do
        {:ok, result} -> {:tool_result, tool_def.name, result}
        {:error, reason} -> {:tool_error, tool_def.name, reason}
      end
    end,
    name: String.to_existing_atom("tool_#{tool_def.name}")
  )

  workflow =
    state.workflow
    |> Workflow.add(tool_step, to: :dispatch_tools)

  tools = [tool | state.tools]

  {:noreply, %{state | workflow: workflow, tools: tools}}
end

@impl true
def handle_cast({:remove_tool, tool_name}, state) do
  # Rebuild the workflow without the removed tool
  tools = Enum.reject(state.tools, &(&1.name == tool_name))
  workflow = build_workflow(state.model, state.system_prompt, tools)

  {:noreply, %{state | workflow: workflow, tools: tools}}
end
```

Because Runic workflows are data, adding a tool is just `Workflow.add/3`. Removing requires a rebuild (or a future `Workflow.remove/2` API — see wishlist).

### GenServer Interface — `handle_cast` for User Input

The public `send_message/2` function casts into the GenServer. The cast triggers the full agent loop: fold the user message into history, call the LLM, parse the response, dispatch tools if needed.

```elixir
@impl true
def handle_cast({:user_message, content}, state) do
  input = {:user, content}

  workflow =
    state.workflow
    |> Workflow.plan_eagerly(input)

  {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

  state = dispatch_runnables(runnables, %{state | workflow: workflow})

  {:noreply, state}
end
```

`dispatch_runnables/2` sends each runnable to the Task supervisor pool (see below). The GenServer never blocks on LLM calls — everything is async.

### Runtime Workflow Generation — Complex Tool Calls

When the LLM requests multiple tool calls with dependencies (e.g., "search the web, then summarize the results, then write a report"), the agent builds a *new* Runic workflow at runtime:

```elixir
defp build_tool_plan_workflow(tool_calls, available_tools) do
  require Runic

  {independent, dependent} = classify_tool_calls(tool_calls)

  base_workflow = Runic.workflow(name: "tool_plan_#{:erlang.unique_integer([:positive])}")

  # Add independent tool calls as root steps
  base_workflow =
    Enum.reduce(independent, base_workflow, fn call, wrk ->
      tool = find_tool(available_tools, call.name)
      step = Runic.step(
        fn _input ->
          case ReqLLM.Tool.execute(tool, call.arguments) do
            {:ok, result} -> {:tool_result, call.id, call.name, result}
            {:error, reason} -> {:tool_error, call.id, call.name, reason}
          end
        end,
        name: :"tool_#{call.id}"
      )
      Workflow.add(wrk, step)
    end)

  # Add dependent calls as children of their dependencies
  Enum.reduce(dependent, base_workflow, fn {call, depends_on}, wrk ->
    tool = find_tool(available_tools, call.name)
    step = Runic.step(
      fn prior_results ->
        merged_args = Map.merge(call.arguments, %{"context" => prior_results})
        case ReqLLM.Tool.execute(tool, merged_args) do
          {:ok, result} -> {:tool_result, call.id, call.name, result}
          {:error, reason} -> {:tool_error, call.id, call.name, reason}
        end
      end,
      name: :"tool_#{call.id}"
    )
    parent_names = Enum.map(depends_on, &:"tool_#{&1}")
    Workflow.add(wrk, step, to: parent_names)
  end)
end
```

This dynamically constructed workflow is then dispatched to a temporary process:

```elixir
defp dispatch_tool_plan(tool_calls, state) do
  workflow = build_tool_plan_workflow(tool_calls, state.tools)

  task = Task.Supervisor.async_nolink(
    MyApp.Agent.TaskSupervisor,
    fn ->
      workflow
      |> Workflow.react_until_satisfied(nil, async: true, timeout: :infinity)
      |> Workflow.raw_productions()
    end
  )

  pending = Map.put(state.pending_tasks, task.ref, {:tool_plan, tool_calls})
  %{state | pending_tasks: pending}
end
```

### Task Supervisor Pool — Dispatch & Execution

Runic's three-phase execution model maps perfectly onto OTP's Task supervisor:

```elixir
defp dispatch_runnables(runnables, state) do
  Enum.reduce(runnables, state, fn runnable, acc ->
    task = Task.Supervisor.async_nolink(
      MyApp.Agent.TaskSupervisor,
      fn ->
        Invokable.execute(runnable.node, runnable)
      end
    )

    pending = Map.put(acc.pending_tasks, task.ref, {:runnable, runnable})
    %{acc | pending_tasks: pending}
  end)
end
```

The Task supervisor provides:
- Automatic cleanup on crash
- Isolation — a failing tool call doesn't take down the agent
- Concurrency — independent runnables execute in parallel
- Backpressure via `max_children` on the supervisor

### `handle_info` — Apply Phase for Completed Tasks

When a Task completes, the GenServer receives `{ref, result}`. This is the **apply phase** — results are folded back into the workflow:

```elixir
@impl true
def handle_info({ref, executed_runnable}, state) do
  Process.demonitor(ref, [:flush])

  case Map.pop(state.pending_tasks, ref) do
    {{:runnable, _original}, pending} ->
      workflow = Workflow.apply_runnable(state.workflow, executed_runnable)

      state = %{state | workflow: workflow, pending_tasks: pending}

      # If there's more work, dispatch the next wave
      state =
        if Workflow.is_runnable?(workflow) do
          {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
          dispatch_runnables(runnables, %{state | workflow: workflow})
        else
          # Cycle complete — extract productions and notify subscribers
          productions = Workflow.raw_productions(workflow)
          notify_subscribers(state.subscribers, productions)
          state
        end

      {:noreply, state}

    {{:tool_plan, original_calls}, pending} ->
      # Tool plan completed — fold results back as tool results
      tool_results = executed_runnable
      state = %{state | pending_tasks: pending}

      Enum.reduce(tool_results, state, fn result, acc ->
        case result do
          {:tool_result, call_id, _name, value} ->
            input = {:tool_result, call_id, Jason.encode!(value)}
            workflow = Workflow.plan_eagerly(acc.workflow, input)
            {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
            dispatch_runnables(runnables, %{acc | workflow: workflow})

          {:tool_error, call_id, name, reason} ->
            input = {:tool_result, call_id, "Error executing #{name}: #{inspect(reason)}"}
            workflow = Workflow.plan_eagerly(acc.workflow, input)
            {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
            dispatch_runnables(runnables, %{acc | workflow: workflow})
        end
      end)
      |> then(&{:noreply, &1})

    {nil, _} ->
      {:noreply, state}
  end
end

# Handle task failures
@impl true
def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
  case Map.pop(state.pending_tasks, ref) do
    {{:runnable, runnable}, pending} ->
      state = handle_task_failure(runnable, reason, %{state | pending_tasks: pending})
      {:noreply, state}

    _ ->
      {:noreply, state}
  end
end
```

### Error Handling & Retries

Wrap the LLM step with retry logic. Runic steps are just functions — the retry can live inside the step or be modeled as a state machine:

```elixir
defp build_llm_step_with_retries(model, max_retries \\ 3) do
  Runic.step(
    fn context ->
      do_llm_call(model, context, max_retries, 0)
    end,
    name: :llm_call
  )
end

defp do_llm_call(_model, _context, max_retries, attempt) when attempt >= max_retries do
  {:error, :max_retries_exceeded}
end

defp do_llm_call(model, context, max_retries, attempt) do
  case ReqLLM.generate_text(model, context) do
    {:ok, response} ->
      response

    {:error, %{status: status}} when status in [429, 500, 502, 503, 529] ->
      backoff = min(:timer.seconds(2 ** attempt), :timer.seconds(30))
      Process.sleep(backoff)
      do_llm_call(model, context, max_retries, attempt + 1)

    {:error, reason} ->
      {:error, {:llm_error, reason}}
  end
end
```

Alternatively, model retries as a Runic state machine for visibility:

```elixir
defp build_retry_state_machine do
  Runic.state_machine(
    name: :retry_tracker,
    init: %{attempts: 0, last_error: nil, backoff_ms: 1000},
    reducer: fn event, state ->
      case event do
        {:attempt_failed, reason} ->
          %{state |
            attempts: state.attempts + 1,
            last_error: reason,
            backoff_ms: min(state.backoff_ms * 2, 30_000)}

        :attempt_succeeded ->
          %{state | attempts: 0, last_error: nil, backoff_ms: 1000}
      end
    end,
    reactors: [
      fn %{attempts: n} when n >= 3 -> :max_retries_exceeded end,
      fn %{attempts: n} when n > 0 -> :should_retry end
    ]
  )
end
```

### Rate Limiting & Throttling

Track request timestamps in an accumulator and gate the LLM call with a rule:

```elixir
defp build_rate_tracker(max_per_minute \\ 20) do
  Runic.accumulator(
    %{timestamps: [], max_per_minute: max_per_minute},
    fn _input, state ->
      now = DateTime.utc_now()
      one_minute_ago = DateTime.add(now, -60, :second)

      recent =
        [now | state.timestamps]
        |> Enum.filter(&(DateTime.compare(&1, one_minute_ago) == :gt))
        |> Enum.take(state.max_per_minute * 2)

      %{state | timestamps: recent}
    end,
    name: :rate_tracker
  )
end

defp build_rate_limit_gate do
  Runic.rule name: :rate_gate do
    given(x: x)
    where(
      state_of(:rate_tracker) |> then(fn tracker ->
        recent_count = Enum.count(tracker.timestamps, fn t ->
          DateTime.diff(DateTime.utc_now(), t, :second) < 60
        end)
        recent_count < tracker.max_per_minute
      end)
    )
    then(fn %{x: x} -> x end)
  end
end
```

ReqLLM also exposes rate limit headers from provider responses. These can be fed into the accumulator for provider-aware throttling:

```elixir
defp extract_rate_limit_info(response) do
  meta = response.provider_meta || %{}
  %{
    remaining: meta[:rate_limit_remaining],
    reset_at: meta[:rate_limit_reset],
    tokens_remaining: meta[:tokens_remaining]
  }
end
```

### Putting It All Together — `build_workflow/3`

```elixir
defp build_workflow(model, system_prompt, tools) do
  require Runic

  chat_acc = build_chat_accumulator(system_prompt)
  llm_step = build_llm_step_with_retries(model)
  parser = build_tool_parser()
  {token_counter, msg_counter, latency_tracker} = build_metadata_trackers()
  rate_tracker = build_rate_tracker()
  command_rules = build_command_rules(tools)

  workflow =
    Workflow.new(:chat_agent)
    |> Workflow.add(chat_acc)
    |> Workflow.add(rate_tracker, to: :chat_history)
    |> Workflow.add(llm_step, to: :chat_history)
    |> Workflow.add(parser, to: :llm_call)
    |> Workflow.add(token_counter, to: :llm_call)
    |> Workflow.add(msg_counter, to: :llm_call)
    |> Workflow.add(latency_tracker, to: :llm_call)

  # Add command routing rules as children of the parser
  workflow =
    Enum.reduce(command_rules, workflow, fn rule, wrk ->
      Workflow.add(wrk, rule, to: :parse_response)
    end)

  # Add tool execution steps for each registered tool
  Enum.reduce(tools, workflow, fn tool, wrk ->
    tool_step = Runic.step(
      fn {:execute_tools, calls, _response} ->
        call = Enum.find(calls, &(&1.name == tool.name))
        if call do
          case ReqLLM.Tool.execute(tool, call.arguments) do
            {:ok, result} -> {:tool_result, call.id, Jason.encode!(result)}
            {:error, reason} -> {:tool_error, call.id, tool.name, reason}
          end
        end
      end,
      name: :"tool_#{tool.name}"
    )
    Workflow.add(wrk, tool_step, to: :dispatch_tools)
  end)
end
```

### Dynamic Supervisor Setup

```elixir
defmodule MyApp.Agent.Supervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: MyApp.AgentRegistry},
      {DynamicSupervisor, name: MyApp.AgentSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: MyApp.Agent.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def start_session(session_id, opts \\ []) do
    DynamicSupervisor.start_child(
      MyApp.AgentSupervisor,
      {MyApp.Agent, {session_id, opts}}
    )
  end

  def stop_session(session_id) do
    case Registry.lookup(MyApp.AgentRegistry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(MyApp.AgentSupervisor, pid)
      [] -> {:error, :not_found}
    end
  end
end
```

---

## Part 3: Alternative Runic Modeling Approaches

Runic is flexible enough to model LLM workflows in several different ways. Each trades off between explicitness, composability, and simplicity.

### Approach A: Flat Accumulator + Post-hoc Rules

The simplest approach — a single accumulator *is* the entire agent state, and rules run after each accumulation to decide what happens next:

```elixir
agent_state = Runic.accumulator(
  %{messages: [], tools: [], turn: 0, status: :idle},
  fn event, state ->
    case event do
      {:user_msg, content} ->
        %{state |
          messages: state.messages ++ [%{role: :user, content: content}],
          turn: state.turn + 1,
          status: :needs_llm_call}

      {:llm_response, response} ->
        %{state |
          messages: state.messages ++ [response.message],
          status: if(response.finish_reason == :tool_calls, do: :tool_calling, else: :idle)}

      {:tool_result, id, result} ->
        %{state |
          messages: state.messages ++ [%{role: :tool, tool_call_id: id, content: result}],
          status: :needs_llm_call}
    end
  end,
  name: :agent
)

needs_call_rule = Runic.rule name: :trigger_llm do
  given(x: _x)
  where(state_of(:agent).status == :needs_llm_call)
  then(fn _bindings -> :do_llm_call end)
end
```

**Pros:** Minimal components, easy to reason about.
**Cons:** The accumulator does too much — business logic, message formatting, status tracking all in one reducer. Hard to compose or extend.

### Approach B: State Machine as Session Controller

Use a Runic state machine as the top-level orchestrator. The state machine models the agent's lifecycle and its reactors trigger downstream actions:

```elixir
session = Runic.state_machine(
  name: :session,
  init: :idle,
  reducer: fn event, current_state ->
    case {current_state, event} do
      {:idle, {:user_msg, _}} -> :generating
      {:generating, {:llm_done, %{finish_reason: :stop}}} -> :idle
      {:generating, {:llm_done, %{finish_reason: :tool_calls}}} -> :tool_calling
      {:tool_calling, {:tools_done, _}} -> :generating
      {state, :timeout} -> {:error, :timeout, state}
      {_, :shutdown} -> :terminated
      {state, _} -> state
    end
  end,
  reactors: [
    fn :generating -> :call_llm end,
    fn :tool_calling -> :execute_tools end,
    fn :terminated -> :cleanup end,
    fn {:error, reason, _} -> {:notify_error, reason} end
  ]
)
```

**Pros:** Clear lifecycle model, reactors are declarative, easy to visualize.
**Cons:** Reactors are passive signals — you still need separate steps/rules to actually do the work. The state machine itself doesn't call the LLM.

### Approach C: Pipeline-per-Turn with Workflow Composition

Build a fresh workflow for each turn, merging it with accumulated state:

```elixir
defp build_turn_workflow(messages, model, tools) do
  require Runic

  call_step = Runic.step(
    fn _input ->
      tool_schemas = Enum.map(tools, &ReqLLM.Tool.to_schema/1)
      ReqLLM.generate_text(model, messages, tools: tool_schemas)
    end,
    name: :call
  )

  parse_step = Runic.step(
    fn {:ok, response} -> response end,
    name: :parse
  )

  Runic.workflow(
    name: "turn_#{:erlang.unique_integer([:positive])}",
    steps: [
      {call_step, [parse_step]}
    ]
  )
end
```

**Pros:** Each turn is isolated and easy to test. No long-lived state in the workflow.
**Cons:** Loses Runic's stateful primitives (accumulators, state machines). The workflow is essentially just a function pipeline.

### Approach D: Hooks for Side Effects, Steps for Pure Logic

Use Runic's hook system for all side effects (sending messages to subscribers, logging, persisting) while keeping steps and rules pure:

```elixir
workflow = Runic.workflow(
  name: :agent,
  steps: [
    {Runic.step(&format_messages/1, name: :format),
     [Runic.step(&call_llm/1, name: :call)]}
  ],
  after_hooks: [
    call: [
      fn %HookEvent{result: fact}, _ctx ->
        {:apply, fn workflow ->
          # Persist the response, notify subscribers, etc.
          MyApp.Persistence.save_turn(fact.value)
          MyApp.PubSub.broadcast(fact.value)
          workflow
        end}
      end
    ]
  ]
)
```

**Pros:** Clean separation of pure workflow logic and side effects. Hooks compose well.
**Cons:** Hooks are less visible than steps in the workflow graph. Error handling in hooks requires care.

---

## Part 4: Wishlist — Runic Features for LLM Workflows

These are features that would be natural extensions of Runic's existing abstractions and would significantly simplify LLM/agent use cases without coupling Runic to any specific LLM library.

### 1. `Workflow.remove/2` — Remove Components by Name or Hash

Currently, removing a tool from a running agent requires rebuilding the entire workflow. A `remove` API would allow surgical modification:

```elixir
# Wishlist
workflow = Workflow.remove(workflow, :tool_web_search)
```

This should remove the component and its edges while preserving the rest of the graph. Useful for dynamic tool registration/deregistration.

### 2. Looping / Cyclic Subgraph Support

LLM agent loops are inherently cyclic: user → LLM → tool → LLM → tool → ... → user. Runic's DAG constraint means the loop must be driven externally (via GenServer re-entry). A first-class loop primitive would simplify this:

```elixir
# Wishlist: a loop component that re-feeds outputs matching a condition back to an ancestor
Runic.loop(
  name: :agent_loop,
  from: :parse_response,
  back_to: :chat_history,
  while: fn result -> match?({:tool_calls, _, _}, result) end
)
```

This would allow the workflow itself to express the "call LLM, execute tools, call LLM again" pattern without external orchestration. The loop terminates when the `while` predicate returns false.

### 3. Async Step / Deferred Step

A step variant that signals "this work is long-running and should not block the react cycle." The workflow would pause at that node and resume when the result arrives:

```elixir
# Wishlist
Runic.async_step(
  fn context -> ReqLLM.generate_text(model, context) end,
  name: :llm_call,
  timeout: :timer.seconds(60)
)
```

Currently this requires manual three-phase orchestration. An async step would let `react_until_satisfied` automatically dispatch long-running work to a Task and collect results.

### 4. Error/Retry Component

A composable retry wrapper that can be attached to any step:

```elixir
# Wishlist
Runic.retry(
  step: :llm_call,
  max_attempts: 3,
  backoff: :exponential,
  on: fn {:error, %{status: s}} -> s in [429, 500, 502, 503] end
)
```

This would integrate with the three-phase model — failed runnables would be re-queued with backoff metadata rather than immediately failing.

### 5. Workflow.subscribe / Event Stream

A built-in way to subscribe to workflow events (fact produced, step completed, rule fired) without hooks:

```elixir
# Wishlist
{:ok, event_stream} = Workflow.subscribe(workflow)

event_stream
|> Stream.filter(&match?(%{event: :fact_produced, component: :llm_call}, &1))
|> Stream.each(fn event -> broadcast_to_client(event.fact.value) end)
|> Stream.run()
```

This would decouple observation from execution and support multiple concurrent observers.

### 6. Conditional Edges / Edge Predicates

Allow edges between components to carry a predicate. The downstream node only receives the fact if the edge predicate passes:

```elixir
# Wishlist
Workflow.add(workflow, tool_step, to: :parse_response,
  when: fn fact -> match?({:tool_calls, _, _}, fact.value) end
)
```

Currently this requires an intermediate rule. Conditional edges would reduce boilerplate for routing patterns.

### 7. Component Middleware / Interceptors

A composable middleware stack that wraps any component's execution. Useful for cross-cutting concerns like logging, metrics, auth, and rate limiting:

```elixir
# Wishlist
Runic.with_middleware(:llm_call, [
  &MyApp.Middleware.log_timing/3,
  &MyApp.Middleware.rate_limit/3,
  &MyApp.Middleware.track_tokens/3
])
```

### 8. First-Class Timeout on Steps

Steps and runnables currently rely on external timeout management (Task.async_stream options, GenServer timeouts). A per-step timeout would integrate with the three-phase model:

```elixir
# Wishlist
Runic.step(fn ctx -> ReqLLM.generate_text(model, ctx) end,
  name: :llm_call,
  timeout: :timer.seconds(30),
  on_timeout: fn -> {:error, :llm_timeout} end
)
```

### 9. Workflow Snapshots / Checkpoints

Save and restore workflow state at specific points. Critical for long-running agent sessions:

```elixir
# Wishlist
checkpoint = Workflow.checkpoint(workflow)

# Later, after a crash or restart:
workflow = Workflow.restore(checkpoint)
```

This extends `build_log/from_log` with accumulated state (fact memory, accumulator values).

### 10. Accumulator Projections

Read a derived view of an accumulator's state without modifying it. Useful for extracting metrics or summaries without adding dedicated steps:

```elixir
# Wishlist
Workflow.project(:chat_history, fn context ->
  Enum.count(context, &(&1.role == :user))
end)
# => 7
```

### 11. Workflow.branch / Subworkflow Isolation

Run a sub-section of the workflow in isolation, returning results without modifying the parent:

```elixir
# Wishlist
{results, _sub_workflow} = Workflow.branch(workflow, from: :parse_response, input: tool_calls)
```

This would support the "dispatch a tool plan as an isolated workflow" pattern without manually constructing a new workflow.

### 12. Generalized Streaming Step

A step variant that produces a stream of facts rather than a single fact. Essential for LLM streaming responses:

```elixir
# Wishlist
Runic.stream_step(
  fn context ->
    {:ok, response} = ReqLLM.stream_text(model, context)
    ReqLLM.StreamResponse.tokens(response)
  end,
  name: :llm_stream,
  collect: true  # downstream steps wait for full stream; :emit sends each chunk
)
```

---

## Summary

Runic's primitives — steps, rules, accumulators, state machines, and the three-phase execution model — provide a natural vocabulary for expressing LLM agent architectures. The key insight is that an agent loop is fundamentally a *reactive workflow with stateful accumulation*, which is exactly what Runic was designed for.

The main friction points are around cyclic control flow (agent loops), async I/O integration (LLM API calls), and dynamic graph modification (tool registration). The wishlist items above address these gaps while staying true to Runic's core principles: purely functional composition, process-agnostic execution, and runtime workflow modification as data.
