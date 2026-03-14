# Future Component Exploration

> **Status**: Exploration  
> **Scope**: Survey of potential Runic components informed by adjacent tools and domains  
> **Context**: With StateMachine, FSM, Aggregate, Saga, and ProcessManager shipped, this document canvases what else users of workflow engines, rule systems, durable execution platforms, and DAG tools might expect — and how each idea maps to Runic's primitives.

---

## Table of Contents

1. [Evaluation Criteria](#evaluation-criteria)
2. [Component Candidates](#component-candidates)
   - [Circuit Breaker](#1-circuit-breaker)
   - [Sensor / Polling Gate](#2-sensor--polling-gate)
   - [Router / Exclusive Gateway](#3-router--exclusive-gateway)
   - [Pipeline](#4-pipeline)
   - [Approval Gate / Human Task](#5-approval-gate--human-task)
   - [Batch Window](#6-batch-window)
   - [Retry Scope](#7-retry-scope)
   - [Constraint / Validation Gate](#8-constraint--validation-gate)
   - [Blackboard](#9-blackboard)
   - [RuleSet / Priority Group](#10-ruleset--priority-group)
   - [Event Router / Content-Based Router](#11-event-router--content-based-router)
   - [Cron / Schedule Trigger](#12-cron--schedule-trigger)
   - [Cache / Memo](#13-cache--memo)
   - [Data Asset / Materialization](#14-data-asset--materialization)
   - [Feedback Controller](#15-feedback-controller)
   - [SubWorkflow / Call Activity](#16-subworkflow--call-activity)
3. [Priority Matrix](#priority-matrix)
4. [Themes & Groupings](#themes--groupings)
5. [What Should NOT Be a Component](#what-should-not-be-a-component)
6. [Open Questions](#open-questions)

---

## Evaluation Criteria

Each candidate is assessed on:

| Criterion | Question |
|-----------|----------|
| **Demand** | Do users of Temporal / Airflow / Camunda / Drools / Step Functions commonly need this? |
| **Primitive gap** | Can this be done today with Step + Rule + Accumulator, or is the boilerplate prohibitive? |
| **Composition value** | Does it enable new composition patterns when combined with existing components? |
| **Invokable boundary** | Does it require a new Invokable node type, or is it compositional sugar? |
| **Runtime coupling** | Does it require Runner-level support, or is it self-contained in the workflow graph? |

The bar for inclusion is: **the component provides meaningful sugar over a pattern that is common, non-trivial to wire by hand, and benefits from being a named, addressable sub-graph.**

---

## Component Candidates

### 1. Circuit Breaker

**Inspired by**: Resilience4j, Polly, Istio circuit breaking, Oban circuit breaker  
**Domain**: Any workflow calling unreliable external services (APIs, databases, third-party integrations)

**What it does**: Tracks failure rates of a downstream step. After N consecutive failures (or a failure rate threshold), the breaker "opens" and short-circuits to a fallback value without invoking the step. After a cooldown period, it transitions to "half-open" and allows a single probe request through.

**Canonical use case — API gateway with degraded mode**:

```elixir
breaker = Runic.circuit_breaker name: :payment_api do
  protect &PaymentService.charge/1

  failure_threshold 5            # open after 5 consecutive failures
  cooldown_seconds 30            # wait 30s before probing
  fallback fn input -> {:queued, input} end  # degrade gracefully

  # Optional: what counts as a failure
  trip_on fn
    {:error, _} -> true
    {:ok, %{status: s}} when s >= 500 -> true
    _ -> false
  end
end
```

**How it maps to primitives**:
- **Accumulator**: holds breaker state `%{status: :closed | :open | :half_open, failure_count: 0, last_failure_at: nil}`
- **Rule (guard)**: condition checks `state_of(:breaker)` — if open and not past cooldown, skip to fallback
- **Step (protected)**: the actual work function, only invoked when breaker is closed or half-open
- **Step (fallback)**: produces the degraded-mode value
- **Rule (trip detector)**: after each invocation, checks result against `trip_on` predicate and updates accumulator

**Why a component**: Wiring this by hand requires 4-5 nodes with careful edge ordering and state feedback. The breaker pattern is universally needed and the state machine is well-defined (closed → open → half-open → closed). Making it a named component also enables `Workflow.get_component(wf, {:payment_api, :accumulator})` for monitoring breaker state.

**Runtime coupling**: Low — self-contained in the graph. Cooldown timers could be purely time-based (check `System.monotonic_time()` in the condition) or Runner-assisted for durable cooldowns.

---

### 2. Sensor / Polling Gate

**Inspired by**: Airflow Sensors, Dagster asset sensors, AWS Step Functions Wait states  
**Domain**: ETL pipelines, data engineering, infrastructure automation

**What it does**: Blocks downstream execution until an external condition is met. The sensor periodically evaluates a "poke" function; when it returns truthy, the gate opens and the input passes through.

**Canonical use case — wait for a file to appear before processing**:

```elixir
sensor = Runic.sensor name: :file_ready do
  poke fn -> File.exists?("/data/incoming/daily_report.csv") end
  interval_ms 5_000
  timeout_ms 300_000   # give up after 5 minutes
  on_timeout :skip     # or :error
end
```

**Another use case — wait for a database record**:

```elixir
sensor = Runic.sensor name: :order_settled do
  poke fn -> 
    case Repo.get_by(Settlement, order_id: context(:order_id)) do
      nil -> false
      record -> {:ok, record}
    end
  end
  interval_ms 1_000
  timeout_ms 60_000
  on_timeout fn -> {:error, :settlement_timeout} end
end
```

**How it maps to primitives**:
- **Accumulator**: holds `%{status: :waiting | :satisfied | :timed_out, attempts: 0, result: nil}`
- **Rule (poke)**: condition is always true while status is `:waiting`; reaction invokes the poke function and updates accumulator
- **Condition (gate)**: downstream nodes only activate when `state_of(:sensor).status == :satisfied`

**Why a component**: Sensors are the #1 missing primitive when porting Airflow DAGs. The polling + timeout + gate pattern is repetitive to build and universally needed in data pipelines.

**Runtime coupling**: Medium — the polling interval requires external scheduling (Runner timers or a GenServer loop). The workflow graph itself can represent the state machine, but repeated re-evaluation needs a scheduler.

---

### 3. Router / Exclusive Gateway

**Inspired by**: BPMN Exclusive Gateway, AWS Step Functions Choice state, Camunda decision tables  
**Domain**: Any workflow with mutually exclusive branching based on data

**What it does**: Evaluates an input against an ordered list of conditions and routes to exactly one branch — the first match wins. Unlike rules (which can fire in parallel for all matching conditions), a router enforces mutual exclusion.

**Canonical use case — order routing by priority tier**:

```elixir
router = Runic.router name: :order_router do
  route :vip,      when: fn %{tier: :vip} -> true end,       to: :express_fulfillment
  route :standard, when: fn %{tier: :standard} -> true end,   to: :normal_fulfillment
  route :default,  to: :bulk_fulfillment
end
```

**Decision table variant**:

```elixir
router = Runic.router name: :pricing do
  match %{region: region, quantity: qty} do
    route :wholesale  when region == :us and qty > 1000,  do: :us_wholesale_pricing
    route :retail     when region == :us,                 do: :us_retail_pricing
    route :intl       when region != :us,                 do: :international_pricing
    route :default,                                       do: :standard_pricing
  end
end
```

**How it maps to primitives**:
- **Ordered list of Conditions**: each route is a condition; evaluation stops at first match
- **Step per branch**: route target is a step or named component
- The key primitive gap is *mutual exclusion* — today, multiple rules can fire for the same input. A router guarantees exactly one branch activates.

**Why a component**: BPMN's exclusive gateway is the most common workflow pattern after sequence. Users coming from Step Functions or Camunda expect this. Today you can approximate it with rules + guards that are manually made mutually exclusive, but that's error-prone.

**Runtime coupling**: None — purely graph-level routing with a special activation strategy.

**Implementation note**: This may require a new Invokable behavior (ordered-exclusive evaluation) or could be done as a chain of Rules where each successive condition is AND'd with the negation of all prior conditions. The latter is purely compositional but generates O(n²) conditions.

---

### 4. Pipeline

**Inspired by**: Elixir `|>`, Unix pipes, Broadway pipelines, functional composition  
**Domain**: ETL, data transformation, any linear processing chain

**What it does**: Syntactic sugar for a linear chain of steps where each step's output feeds the next. Today this requires nested tuples in the workflow DSL which is awkward for long chains.

**Canonical use case — text processing pipeline**:

```elixir
pipeline = Runic.pipeline name: :text_processor do
  step :tokenize,   fn text -> String.split(text) end
  step :lowercase,  fn words -> Enum.map(words, &String.downcase/1) end
  step :filter,     fn words -> Enum.reject(words, &(&1 in ~w(the a an))) end
  step :count,      fn words -> length(words) end
end
```

This is equivalent to:

```elixir
Runic.workflow(
  name: :text_processor,
  steps: [
    {Runic.step(&tokenize/1, name: :tokenize),
     [{Runic.step(&lowercase/1, name: :lowercase),
       [{Runic.step(&filter/1, name: :filter),
         [Runic.step(&count/1, name: :count)]}]}]}
  ]
)
```

**How it maps to primitives**: Pure sugar — generates a chain of Steps connected sequentially. No new Invokable. The nesting depth is eliminated.

**Why a component**: The nested tuple syntax is Runic's most common ergonomic complaint for linear flows. A pipeline macro would make the 80% case (linear chain) as clean as `|>` piping.

**Runtime coupling**: None.

---

### 5. Approval Gate / Human Task

**Inspired by**: BPMN User Task, Camunda human tasks, Temporal signals, Inngest `waitForEvent`  
**Domain**: Business process automation, compliance, content moderation, expense approvals

**What it does**: Pauses workflow execution at a designated point and waits for an external signal (human approval, webhook callback, manual input). The workflow is durable — it persists its state and resumes when the signal arrives.

**Canonical use case — expense approval workflow**:

```elixir
gate = Runic.approval_gate name: :manager_approval do
  prompt fn expense -> 
    %{
      message: "Approve expense #{expense.id} for $#{expense.amount}?",
      assignee: expense.manager_email,
      options: [:approve, :reject, :escalate]
    }
  end

  on :approve do
    fn expense, %{approved_by: approver} -> 
      %{expense | status: :approved, approved_by: approver}
    end
  end

  on :reject do
    fn expense, %{reason: reason} -> 
      %{expense | status: :rejected, rejection_reason: reason}
    end
  end

  on :escalate do
    fn expense, _ -> 
      %{expense | status: :escalated, assignee: expense.director_email}
    end
  end

  timeout_hours 48
  on_timeout fn expense -> %{expense | status: :auto_escalated} end
end
```

**How it maps to primitives**:
- **Accumulator**: holds gate state `%{status: :pending | :resolved, prompt: nil, resolution: nil}`
- **Step (prompt generator)**: produces the prompt/notification payload as a fact (consumed by external system)
- **Rules (resolution handlers)**: each `on` clause is a Rule gated on `state_of(:gate).status == :pending` that matches the resolution signal
- **Runner integration**: the Runner checkpoints the workflow when the gate is reached and resumes it when `Runner.signal/3` is called with the resolution

**Why a component**: Human-in-the-loop is the defining feature of business process engines. It's why Camunda and Temporal exist. The pattern is well-defined (pause → persist → signal → resume) but requires careful Runner integration.

**Runtime coupling**: High — requires Runner support for durable waiting, signal delivery, and timeout scheduling. This is the most Runner-coupled candidate.

---

### 6. Batch Window

**Inspired by**: Apache Flink windows, Spark Structured Streaming, Broadway batching, GenStage demand  
**Domain**: Stream processing, event aggregation, IoT data collection, log processing

**What it does**: Collects incoming facts into a buffer and releases them as a batch when a window condition is met (count threshold, time window, or custom predicate).

**Canonical use case — batch inserts for efficiency**:

```elixir
window = Runic.batch_window name: :db_batcher do
  max_size 100
  max_wait_ms 5_000
  flush fn batch -> Repo.insert_all(Event, batch) end
end
```

**Tumbling time window for metrics aggregation**:

```elixir
window = Runic.batch_window name: :metrics_agg do
  window_ms 60_000    # 1-minute tumbling window
  flush fn events ->
    %{
      count: length(events),
      avg: Enum.sum(events) / length(events),
      max: Enum.max(events)
    }
  end
end
```

**How it maps to primitives**:
- **Accumulator**: holds `%{buffer: [], count: 0, window_start: timestamp}`
- **Rule (flush trigger)**: condition checks count >= max_size OR time elapsed >= max_wait_ms
- **Step (flush)**: processes the batch, resets the accumulator

**Why a component**: Batching is the bread and butter of data engineering. GenStage/Broadway handle this at the process level, but a workflow-level batch window enables composition with other Runic components without leaving the dataflow model.

**Runtime coupling**: Medium — time-based windows need external timer events. Count-based windows are self-contained.

---

### 7. Retry Scope

**Inspired by**: Temporal activity retries, BPMN error boundary events, Polly retry policies  
**Domain**: Integration workflows, API calls, any step that can transiently fail

**What it does**: Wraps one or more steps in a retry boundary with configurable backoff, max attempts, and error classification. Unlike scheduler policies (which operate at the Runner layer), a retry scope is a graph-level component that makes retry logic visible and composable.

**Canonical use case — resilient API call with classified retries**:

```elixir
scope = Runic.retry_scope name: :api_call do
  max_attempts 5
  backoff :exponential, base_ms: 100, max_ms: 10_000

  retryable fn
    {:error, :timeout} -> true
    {:error, :rate_limited} -> true
    {:error, :server_error} -> true
    _ -> false
  end

  do: &ExternalAPI.fetch_data/1

  on_exhausted fn input, last_error -> 
    {:fallback, input, last_error} 
  end
end
```

**How it maps to primitives**:
- **Accumulator**: holds `%{attempts: 0, last_error: nil, status: :pending}`
- **Step (work)**: the actual function to retry
- **Rule (retry decision)**: if work failed and `retryable` matches and attempts < max, re-invoke
- **Step (backoff)**: computes delay (could emit a `:delay` fact for Runner scheduling)
- **Step (exhausted)**: produces fallback value when retries are exhausted

**Relationship to SchedulerPolicy**: Scheduler policies are runtime configuration that the Runner applies externally. A retry scope is a first-class graph component — it appears in `to_mermaid()`, its sub-components are addressable, and its retry state is part of the workflow's fact history. They serve different levels: policies for operational tuning, scopes for domain-level retry semantics.

**Runtime coupling**: Low-Medium — immediate retries are self-contained. Backoff delays need Runner timer support for durable waits.

---

### 8. Constraint / Validation Gate

**Inspired by**: JSON Schema, Ecto changesets, contract programming, BPMN business rules  
**Domain**: Data validation, API input sanitization, compliance checks, data quality pipelines

**What it does**: Validates an input against a set of constraints (type checks, range validations, required fields, cross-field rules). Produces either the validated input (pass-through) or a structured error. Can be used as a gate before expensive processing.

**Canonical use case — order validation before processing**:

```elixir
gate = Runic.constraint name: :order_validator do
  require_fields [:customer_id, :items, :shipping_address]
  
  check :has_items, fn order -> length(order.items) > 0 end,
    message: "Order must contain at least one item"
  
  check :valid_total, fn order -> 
    Enum.sum(Enum.map(order.items, & &1.price)) > 0
  end,
    message: "Order total must be positive"
  
  check :valid_address, fn order ->
    order.shipping_address.zip =~ ~r/^\d{5}(-\d{4})?$/
  end,
    message: "Invalid ZIP code format"

  on_valid fn order -> {:validated, order} end
  on_invalid fn order, errors -> {:validation_failed, order.id, errors} end
end
```

**How it maps to primitives**:
- **Multiple Conditions**: one per `check` clause
- **Conjunction**: all checks must pass for valid path
- **Step (on_valid)**: passes input through on success
- **Step (on_invalid)**: collects failed check names/messages into error struct

**Why a component**: Validation is everywhere but assembling multi-check gates with error collection by hand is tedious. A named constraint component also enables reuse — the same validator can be shared across workflows.

**Runtime coupling**: None — purely graph-level.

---

### 9. Blackboard

**Inspired by**: Blackboard architecture (AI), Shared data spaces, Linda tuple spaces, Rete working memory  
**Domain**: Multi-agent systems, expert systems, collaborative problem solving, game AI

**What it does**: A shared, typed key-value store that multiple components can read from and write to. Unlike accumulators (which are private to their component), a blackboard is explicitly shared — any component can reference `blackboard(:name).key` via meta_refs.

**Canonical use case — medical diagnosis expert system**:

```elixir
bb = Runic.blackboard name: :patient_record do
  field :symptoms,    default: []
  field :vitals,      default: %{}
  field :risk_score,  default: 0
  field :diagnosis,   default: nil
  field :confidence,  default: 0.0
end

# Rules can read and write to the blackboard
symptom_analyzer = Runic.rule name: :fever_check do
  given(symptom: s)
  where s == :high_fever and blackboard(:patient_record).risk_score < 5
  then fn _ -> {:update_blackboard, :patient_record, :risk_score, 3} end
end

diagnosis_rule = Runic.rule name: :flu_diagnosis do
  given(_: _)
  where :high_fever in blackboard(:patient_record).symptoms 
    and blackboard(:patient_record).vitals.temperature > 101
    and blackboard(:patient_record).risk_score >= 3
  then fn _ -> {:update_blackboard, :patient_record, :diagnosis, :influenza} end
end
```

**How it maps to primitives**:
- **Accumulator**: the blackboard is an accumulator with a map-merge reducer
- **meta_ref edges**: `blackboard(:name)` is sugar for `state_of(:name)` — no new resolution mechanism needed
- **Convention**: blackboard updates are facts that feed back into the accumulator

The key difference from a plain accumulator is the **multi-writer, named-field** convention. The blackboard provides:
1. Schema declaration with defaults
2. A standard update protocol (`:update_blackboard` facts)
3. Typed field access in meta_refs

**Why a component**: Expert systems and multi-agent architectures revolve around shared state. The blackboard pattern gives this a name and a schema. It's thin sugar over an accumulator, but the naming convention and field access pattern make it significantly more readable in complex rule systems.

**Runtime coupling**: None — purely graph-level.

---

### 10. RuleSet / Priority Group

**Inspired by**: Drools rule groups, CLIPS salience, OPS5 conflict resolution, decision tables  
**Domain**: Expert systems, business rules engines, policy evaluation, configuration-driven logic

**What it does**: Groups rules with explicit priority ordering and conflict resolution strategies. When multiple rules match, the strategy determines which fire: all (default Runic behavior), first-match (like Router), highest-priority, or custom agenda.

**Canonical use case — insurance pricing rules with priority**:

```elixir
ruleset = Runic.ruleset name: :pricing_rules do
  strategy :highest_priority   # :all | :first_match | :highest_priority

  rule :employee_discount, priority: 100 do
    given(policy: %{holder_type: :employee})
    then fn %{policy: p} -> {:discount, p, 0.25} end
  end

  rule :loyalty_discount, priority: 50 do
    given(policy: %{years_active: y})
    where y > 5
    then fn %{policy: p} -> {:discount, p, 0.10} end
  end

  rule :new_customer, priority: 10 do
    given(policy: %{years_active: 0})
    then fn %{policy: p} -> {:surcharge, p, 0.05} end
  end
end
```

**Decision table variant**:

```elixir
ruleset = Runic.decision_table name: :shipping_rules do
  # Columns: input pattern fields → output
  # Rows evaluated top-to-bottom, first match wins
  input [:region, :weight_kg, :priority]
  
  row [:us, w, :express]  when w < 5,   output: {:fedex_express, 15.99}
  row [:us, w, :express]  when w >= 5,  output: {:fedex_freight, 29.99}
  row [:us, _, :standard],              output: {:usps_ground, 5.99}
  row [:eu, _, :express],               output: {:dhl_express, 24.99}
  row [:eu, _, _],                      output: {:dhl_standard, 12.99}
  row [_, _, _],                        output: {:international, 34.99}
end
```

**How it maps to primitives**:
- **Rules**: each entry is a standard Rule
- **Conflict resolution**: a wrapper component that evaluates all rules but filters results based on strategy (requires ordered evaluation or post-filtering)
- **Priority metadata**: stored on the component edge properties

**Why a component**: Rule priority and conflict resolution are the core value proposition of dedicated rule engines. Runic already has rules — adding grouping and conflict resolution makes it a viable alternative to Drools/Clara for business logic.

**Runtime coupling**: None — the conflict resolution strategy is applied during the plan/prepare phase.

---

### 11. Event Router / Content-Based Router

**Inspired by**: Enterprise Integration Patterns (Hohpe & Woolf), Apache Camel, RabbitMQ topic routing, Kafka Streams  
**Domain**: Event-driven architectures, message routing, microservice orchestration

**What it does**: Routes incoming events to different workflow branches based on event type, content patterns, or header matching. Unlike Router (#3) which is data-driven, the Event Router specifically handles the pattern of dispatching domain events to handlers — similar to how ProcessManager's `on` blocks work, but as a standalone reusable component.

**Canonical use case — domain event dispatcher**:

```elixir
router = Runic.event_router name: :order_events do
  on {:order_created, _},     to: :new_order_handler
  on {:order_updated, _},     to: :update_handler  
  on {:payment_received, _},  to: :payment_handler
  on {:order_cancelled, _},   to: [:cancellation_handler, :refund_handler]  # fan-out
  
  unmatched :dead_letter   # or :drop
end
```

**With content-based routing**:

```elixir
router = Runic.event_router name: :notification_router do
  on %{priority: :critical}, to: :pager_duty
  on %{priority: :high},     to: :slack_alert
  on %{channel: :email},     to: :email_sender
  on %{channel: :sms},       to: :sms_sender
  default to: :log_only
end
```

**How it maps to primitives**:
- **Rules**: each route is a Rule (condition matches pattern, reaction passes to target)
- **Fan-out**: multi-target routes use FanOut
- **Dead letter**: a catch-all Rule with lowest priority

**Why a component**: Event routing is the most common pattern in event-driven systems. Making it a named component (rather than manually wiring N rules) improves readability and enables the `unmatched` / dead-letter pattern cleanly.

**Runtime coupling**: None.

---

### 12. Cron / Schedule Trigger

**Inspired by**: Airflow DAG schedules, cron, Oban, Temporal schedules, Kubernetes CronJobs  
**Domain**: Scheduled jobs, periodic data processing, recurring reports

**What it does**: Declares that a workflow (or sub-graph) should be triggered on a schedule. The trigger itself is metadata — the Runner or an external scheduler reads it and invokes the workflow at the appropriate times.

**Canonical use case — daily report generation**:

```elixir
trigger = Runic.schedule name: :daily_report do
  cron "0 6 * * *"             # 6 AM daily
  timezone "America/New_York"
  input fn -> %{date: Date.utc_today() |> Date.add(-1)} end
  
  # Overlap policy: what if previous run is still going?
  overlap :skip                 # :skip | :queue | :cancel_previous
end
```

**How it maps to primitives**: This is **metadata only** — no new Invokable needed. The schedule declaration is stored on the workflow struct and read by the Runner's scheduler. The workflow itself is unchanged.

```elixir
# The Runner reads schedule metadata:
Workflow.schedules(workflow) 
# => [%{name: :daily_report, cron: "0 6 * * *", ...}]
```

**Why a component**: Every workflow engine needs scheduling. Declaring it as part of the workflow definition (rather than external config) keeps the workflow self-describing. But the actual scheduling is always external.

**Runtime coupling**: High — entirely Runner-dependent. The component is just a declaration.

---

### 13. Cache / Memo

**Inspired by**: Dagster asset materialization, memoization, HTTP caching, Spark persist/cache  
**Domain**: Expensive computations, API call deduplication, incremental processing

**What it does**: Wraps a step with a content-addressed cache. If the same input (by hash) has been computed before, returns the cached result without re-executing. Cache eviction is time-based or size-based.

**Canonical use case — expensive API call deduplication**:

```elixir
cached = Runic.cache name: :geocode do
  work &GeocodingService.lookup/1
  ttl_seconds 86_400           # cache for 24 hours
  key fn address -> address.zip end  # cache key extraction
end
```

**How it maps to primitives**:
- **Accumulator**: holds the cache map `%{key => {value, inserted_at}}`
- **Rule (cache hit)**: if `state_of(:cache)[key]` exists and not expired, emit cached value
- **Step (cache miss)**: invoke the work function, update the accumulator

**Why a component**: Caching is universal but the wiring (check → hit/miss branching → update) is tedious. Content-addressable hashing aligns naturally with Runic's fact hashing.

**Runtime coupling**: Low — TTL expiration can be lazy (check on access) or active (Runner sweep).

---

### 14. Data Asset / Materialization

**Inspired by**: Dagster Software-Defined Assets, dbt models, data lineage tools  
**Domain**: Data engineering, analytics pipelines, ML feature engineering

**What it does**: Declares a named, versioned data artifact produced by a computation. Assets track their lineage (which upstream assets they depend on), support incremental materialization, and can be "observed" to trigger downstream processing when they change.

**Canonical use case — analytics pipeline**:

```elixir
raw_events = Runic.asset name: :raw_events do
  source fn -> EventStore.fetch_since(context(:last_checkpoint)) end
  partitioned_by :date
end

user_sessions = Runic.asset name: :user_sessions do
  depends_on [:raw_events]
  compute fn %{raw_events: events} ->
    events
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {uid, events} -> sessionize(uid, events) end)
  end
  partitioned_by :date
end

daily_metrics = Runic.asset name: :daily_metrics do
  depends_on [:user_sessions]
  compute fn %{user_sessions: sessions} ->
    %{
      dau: sessions |> Enum.map(& &1.user_id) |> Enum.uniq() |> length(),
      avg_session_length: avg(sessions, & &1.duration)
    }
  end
end
```

**How it maps to primitives**:
- **Step**: each asset's `compute` is a step
- **Workflow structure**: `depends_on` creates edges between asset steps
- **Accumulator**: optional, for incremental materialization state (checkpoints, last-materialized partition)
- **Store integration**: materialized values are persisted via the Runner Store

**Why a component**: The data engineering world is moving toward asset-oriented pipelines (Dagster's core thesis). Assets give workflows a **declarative** flavor — describe what should exist, not how to compute it. The lineage tracking and incremental materialization are valuable composition patterns.

**Runtime coupling**: High — materialization scheduling, partition tracking, and lineage metadata are Runner concerns.

---

### 15. Feedback Controller

**Inspired by**: Control theory (PID controllers), cybernetics, thermostat pattern, auto-scaling  
**Domain**: IoT, process control, adaptive systems, auto-scaling, resource management

**What it does**: Implements a feedback loop where the output of a system is measured, compared to a setpoint, and the error drives a corrective action. The classic PID (Proportional-Integral-Derivative) controller is the archetype.

**Canonical use case — auto-scaling worker pool**:

```elixir
controller = Runic.controller name: :pool_scaler do
  setpoint fn -> context(:target_latency_ms) end    # 200ms target
  measure fn -> MetricsStore.avg_latency(:last_60s) end
  
  # PID gains
  proportional 0.5
  integral 0.1
  derivative 0.05
  
  # Output bounds
  output_range 1..50
  
  actuate fn worker_count -> 
    WorkerPool.resize(worker_count) 
  end
end
```

**How it maps to primitives**:
- **Accumulator**: holds controller state `%{integral_sum: 0, last_error: 0, last_output: 0}`
- **Step (measure)**: reads the process variable
- **Step (compute)**: calculates PID output from error, integral, derivative
- **Step (actuate)**: applies the corrective action

**Why a component**: Feedback control is a fundamental systems pattern. It's conceptually simple but getting the accumulator + measurement + actuation wiring right is subtle. The PID math is well-defined and reusable.

**Runtime coupling**: Medium — the control loop needs periodic invocation (timer-driven), but the computation itself is pure.

---

### 16. SubWorkflow / Call Activity

**Inspired by**: BPMN Call Activity, Temporal child workflows, Step Functions nested state machines  
**Domain**: Workflow decomposition, reusable sub-processes, hierarchical composition

**What it does**: Invokes another workflow as a single logical step within a parent workflow. The child workflow runs to completion (or failure) and its result is returned as a single fact to the parent.

**Canonical use case — order processing with reusable validation sub-workflow**:

```elixir
validation_wf = Runic.workflow(
  name: :address_validation,
  steps: [
    {Runic.step(&normalize_address/1, name: :normalize),
     [Runic.step(&verify_with_usps/1, name: :verify)]}
  ]
)

sub = Runic.sub_workflow name: :validate_address do
  workflow validation_wf
  input fn order -> order.shipping_address end
  output fn result -> {:address_validated, result} end
  
  on_failure fn error -> {:address_invalid, error} end
  timeout_ms 30_000
end
```

**How it maps to primitives**:
- **Step**: the sub-workflow invocation is conceptually a step — input in, output out
- **Internally**: the step's work function calls `Workflow.react_until_satisfied/2` on the child workflow
- **Runner integration**: for durable sub-workflows, the Runner starts a child Worker

**Why a component**: Workflow decomposition is essential for managing complexity. Today you can manually invoke a workflow inside a step, but making it a named component enables: (1) the child's lifecycle is tracked, (2) timeout/failure handling is declarative, (3) the Runner can manage the child independently for durability.

**Runtime coupling**: Medium-High — simple (inline execution) is self-contained, but durable child workflows need Runner coordination.

---

## Priority Matrix

Assessed on demand, primitive gap, and implementation complexity:

| # | Component | Demand | Gap | Complexity | Sugar-only? | Priority |
|---|-----------|--------|-----|------------|-------------|----------|
| 4 | Pipeline | Very High | High | Low | Yes | **P0** |
| 3 | Router | High | Medium | Low-Medium | Mostly | **P0** |
| 8 | Constraint | High | Medium | Low | Yes | **P1** |
| 1 | Circuit Breaker | High | High | Medium | Yes | **P1** |
| 7 | Retry Scope | High | Low (overlaps policies) | Medium | Yes | **P1** |
| 10 | RuleSet | High | Medium | Medium | Yes | **P1** |
| 9 | Blackboard | Medium | Low (thin over Accumulator) | Low | Yes | **P2** |
| 6 | Batch Window | Medium | Medium | Medium | Mostly | **P2** |
| 13 | Cache/Memo | Medium | Medium | Low | Yes | **P2** |
| 11 | Event Router | Medium | Low (overlaps PM/Router) | Low | Yes | **P2** |
| 16 | SubWorkflow | Medium | Medium | Medium | Mostly | **P2** |
| 5 | Approval Gate | Medium | High | High | No | **P3** |
| 2 | Sensor | Medium | High | Medium | Mostly | **P3** |
| 12 | Cron/Schedule | Medium | N/A (metadata) | Low | N/A | **P3** |
| 14 | Data Asset | Low-Medium | High | High | No | **P3** |
| 15 | Feedback Controller | Niche | Medium | Medium | Yes | **P3** |

**P0**: High impact, low effort — should be next.  
**P1**: High impact, moderate effort — strong candidates for the next development cycle.  
**P2**: Useful but either thin sugar or medium-effort. Good candidates when a concrete use case demands them.  
**P3**: Valuable but either niche, highly Runner-coupled, or large scope. Defer until foundational work is done.

---

## Themes & Groupings

The candidates cluster into natural families:

### Control Flow Components (Router, Pipeline, SubWorkflow)
These improve workflow ergonomics for common graph shapes. Pipeline and Router are the highest-impact low-effort candidates. They require no new Invokable types and make Runic more approachable for users coming from linear-pipeline or decision-tree backgrounds.

### Resilience Components (Circuit Breaker, Retry Scope, Cache)
These address reliability in integration workflows. They overlap with SchedulerPolicy but operate at the graph level — visible in diagrams, addressable as sub-components, with state tracked in the fact history. The distinction is: policies are operational knobs; resilience components are domain-level decisions.

### Rule Engine Components (RuleSet, Constraint, Blackboard)
These push Runic closer to being a general-purpose business rules engine. RuleSet (with conflict resolution) is the most impactful — it's the missing piece for users comparing Runic to Drools or Clara. Blackboard enables expert-system architectures. Constraint provides the validation gate pattern that BPMN users expect.

### Data Engineering Components (Batch Window, Sensor, Data Asset, Cron)
These address the Airflow/Dagster audience. They're valuable but most require Runner-level support for timers, polling, and materialization scheduling. Batch Window is the most self-contained.

### External Integration Components (Approval Gate, Sensor, Schedule)
These are fundamentally about waiting for external input. They require durable state and external signal mechanisms — the Runner must support `signal/3` and durable timers. Approval Gate is the highest-value item here (it's why BPMN exists), but it's also the most Runner-coupled.

---

## What Should NOT Be a Component

Some patterns are better served by existing primitives or Runner-layer features:

| Pattern | Why Not a Component | Better Approach |
|---------|-------------------|-----------------|
| **Retry with backoff** (simple) | Already handled by SchedulerPolicy | `Workflow.add_scheduler_policy(:step, %{max_retries: 3})` |
| **Timeout** | Already in SchedulerPolicy | `%{timeout_ms: 30_000}` |
| **Logging / Audit** | Cross-cutting concern, not a node | Runner hooks, telemetry events |
| **Error handling** | Already in the Invokable protocol (error facts) | Pattern match on error facts in downstream rules |
| **Parallel execution** | Already in Workflow.react_until_satisfied | `async: true, max_concurrency: 8` |
| **Conditional execution** | Already Rule + Condition | Don't re-invent what rules do |
| **State snapshots** | Runner Store concern | `Runic.Runner.Store` behaviour |
| **Metrics / Monitoring** | Observability, not workflow logic | Telemetry + hooks |

The guiding principle: **components model domain logic patterns; infrastructure concerns belong in the Runner, Store, or Executor layers.**

---

## Open Questions

1. **Router mutual exclusion**: Can ordered-exclusive evaluation be implemented purely as compositional sugar (negating prior conditions), or does it need an Invokable-level `evaluate_first_match` strategy? The sugar approach generates O(n²) conditions — acceptable for small route tables but potentially expensive for decision tables with hundreds of rows.

2. **Pipeline vs workflow sugar**: Should Pipeline be a first-class component (with its own struct, Component impl, sub-component access) or just a macro that expands to the nested-tuple workflow syntax? The latter is simpler but loses addressability.

3. **Retry Scope vs SchedulerPolicy boundary**: When should retry logic live in the graph vs the Runner? Proposed rule: if the retry decision depends on domain data (e.g., "retry if the error is retryable AND the order isn't cancelled"), it's a graph component. If it's operational ("retry 3 times with exponential backoff"), it's a policy.

4. **Blackboard vs explicit dataflow**: The blackboard pattern (shared mutable state) is philosophically at odds with Runic's pure-dataflow model. Is the convenience worth the conceptual tension? Alternative: stay with explicit state_of() references to named accumulators, which achieves the same thing without introducing a "shared" mental model.

5. **Approval Gate external interface**: What does the signal API look like? Strawman: `Runner.signal(runner, workflow_id, {:gate_name, :approve, %{approved_by: "alice"}})`. Does this need a general-purpose signal mechanism, or is it specific to approval gates?

6. **Data Asset incremental materialization**: How does partition tracking interact with the workflow graph? Is a partition a separate workflow run, or does the asset component manage partitions internally via its accumulator state?

7. **Component composition depth**: With 10+ component types, does the mental model become too complex? Should we cap at "components that can be explained in one sentence" and relegate complex patterns to guides showing manual primitive composition?
