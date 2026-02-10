# Runic Roguelite: A Dataflow-Driven ECS Game Architecture

A use case exploration using Runic for a top-down WASD roguelite RPG with rich combinatorial gameplay.

---

## Table of Contents

1. [Game Design Overview](#game-design-overview)
2. [Runic as ECS: Conceptual Mapping](#runic-as-ecs-conceptual-mapping)
3. [Core Game Dynamics & Combinatorics](#core-game-dynamics--combinatorics)
4. [Workflow Architecture](#workflow-architecture)
5. [Parallelism & Coordination Separation](#parallelism--coordination-separation)
6. [GenServer + Registry Game Instance Management](#genserver--registry-game-instance-management)
7. [Phase 2: Phoenix LiveView + PlayCanvas Frontend](#phase-2-phoenix-liveview--playcanvas-frontend)

---

## Game Design Overview

### The Core Loop

**Genre**: Top-down WASD fantasy roguelite with synergy-driven builds

**Core Fantasy**: Discover powerful ability combinations through experimentation

```
┌─────────────────────────────────────────────────────────────┐
│                    ROGUELITE GAME LOOP                      │
├─────────────────────────────────────────────────────────────┤
│  1. EXPLORE    →  Navigate procedural dungeon floors        │
│  2. COMBAT     →  Engage enemies using abilities            │
│  3. ACQUIRE    →  Collect runes, items, abilities           │
│  4. SYNERGIZE  →  Discover combinations & build power       │
│  5. PROGRESS   →  Clear floor → harder floor → boss         │
│  6. DEATH/WIN  →  Meta-progression unlocks → restart        │
└─────────────────────────────────────────────────────────────┘
```

### Combinatorial Design Pillars

1. **Rune System**: 8 base elements × 3 tiers = 24 runes, combinable into 276 unique pairs
2. **Ability Modifiers**: Each ability has 5 slots for modifier runes
3. **Synergy Tags**: Abilities and items have tags that unlock bonus effects when matched
4. **Stat Interactions**: Non-linear stat scaling (e.g., crit × crit_damage × attack_speed)

---

## Runic as ECS: Conceptual Mapping

Traditional ECS separates Entities, Components, and Systems. Runic provides a *dataflow-first* alternative:

| ECS Concept | Runic Equivalent | Description |
|-------------|------------------|-------------|
| **Entity** | `%Fact{value: entity_map}` | Entities are facts flowing through workflows |
| **Component** | Nested data in fact values | `%{position: {x, y}, health: 100, velocity: {0, 0}}` |
| **System** | `%Step{}`, `%Rule{}`, `%Accumulator{}` | Processing nodes in the workflow graph |
| **Query** | Workflow edges + Rules | Conditions determine which facts flow to which steps |
| **World** | `%Workflow{}` + memory graph | The workflow graph IS the world state |

### Key Insight: Facts as Entity State Snapshots

In Runic, entities don't "exist" as mutable objects. Instead, each game tick produces new `%Fact{}` values representing entity state. The workflow graph tracks causal history.

```elixir
# An entity is just data in a fact
%Fact{
  value: %{
    id: "player_1",
    kind: :player,
    position: {100.0, 200.0},
    velocity: {5.0, 0.0},
    health: %{current: 80, max: 100},
    abilities: [:fireball, :dash, :shield],
    runes: %{fire: 2, ice: 1},
    tags: [:burning, :hasted],
    inventory: [...]
  },
  ancestry: {producer_hash, parent_fact_hash}
}
```

---

## Core Game Dynamics & Combinatorics

### Rune System (Primary Combinatorial Driver)

```elixir
defmodule Roguelite.Runes do
  @elements [:fire, :ice, :lightning, :earth, :shadow, :light, :arcane, :nature]
  @tiers [:lesser, :greater, :prime]
  
  # 8 elements × 3 tiers = 24 base runes
  # C(24, 2) = 276 unique pairs for dual-rune synergies
  # Players can socket up to 5 runes per ability = massive build space
  
  def synergy_effect(:fire, :ice), do: {:steam, %{blind_chance: 0.2, damage_bonus: 1.15}}
  def synergy_effect(:lightning, :arcane), do: {:overcharge, %{chain_targets: 3, mana_cost: -0.25}}
  def synergy_effect(:shadow, :light), do: {:twilight, %{phase_shift: true, damage_type: :true}}
  def synergy_effect(:earth, :nature), do: {:overgrowth, %{regen: 5, armor: 20}}
  # ... 272 more combinations
  def synergy_effect(_, _), do: {:none, %{}}
end
```

### Ability System

```elixir
defmodule Roguelite.Ability do
  defstruct [
    :id,
    :name,
    :base_damage,
    :cooldown,
    :mana_cost,
    :tags,           # [:projectile, :aoe, :dot, :melee, :spell]
    :rune_slots,     # up to 5 socketed runes
    :modifiers       # computed from runes + synergies
  ]
end
```

### Tag Synergy System

```elixir
# Items and abilities share tags for synergy bonuses
defmodule Roguelite.TagSynergies do
  # If player has 3+ :fire tagged items/abilities, unlock bonus
  def tier_bonus(:fire, 3), do: %{burn_duration: 1.5, fire_damage: 1.2}
  def tier_bonus(:fire, 5), do: %{ignite_explosion: true, fire_damage: 1.5}
  
  def tier_bonus(:speed, 3), do: %{movement_speed: 1.2, attack_speed: 1.1}
  def tier_bonus(:speed, 5), do: %{haste_on_kill: 3.0, dodge_chance: 0.15}
end
```

---

## Workflow Architecture

### Core Game Workflows

The game uses **multiple specialized workflows** that can be evaluated independently or composed:

```elixir
defmodule Roguelite.Workflows do
  require Runic
  import Runic
  
  @doc """
  Input processing workflow - handles player commands.
  No coordination needed with other systems until output.
  """
  def input_workflow do
    workflow(
      name: :input_processing,
      steps: [
        step(&parse_input_command/1, name: :parse_input),
        {step(&validate_action/1, name: :validate_action),
          [
            rule(fn
              %{action: :move, direction: dir} when dir in [:up, :down, :left, :right] ->
                &apply_movement/1
            end, name: :movement_rule),
            rule(fn
              %{action: :use_ability, ability_id: id, target: _} ->
                &queue_ability_use/1
            end, name: :ability_rule),
            rule(fn
              %{action: :interact} ->
                &handle_interaction/1
            end, name: :interact_rule)
          ]}
      ]
    )
  end
  
  @doc """
  Physics workflow - position/velocity updates.
  Parallelizable per entity - no cross-entity dependencies.
  """
  def physics_workflow do
    workflow(
      name: :physics,
      steps: [
        # Fan out to process each entity independently
        Runic.fan_out(fn %{entities: entities} -> entities end, name: :entity_fan_out),
        step(&apply_velocity/1, name: :apply_velocity),
        step(&check_collisions/1, name: :check_collisions),
        step(&resolve_collisions/1, name: :resolve_collisions),
        Runic.fan_in(&merge_entity_states/1, name: :entity_fan_in)
      ]
    )
  end
  
  @doc """
  Combat workflow - damage calculation with synergy evaluation.
  This is where the combinatorial magic happens.
  """
  def combat_workflow do
    workflow(
      name: :combat,
      steps: [
        {step(&gather_combat_context/1, name: :combat_context),
          [
            # Parallel synergy evaluation
            step(&evaluate_rune_synergies/1, name: :rune_synergies),
            step(&evaluate_tag_synergies/1, name: :tag_synergies),
            step(&evaluate_stat_modifiers/1, name: :stat_modifiers)
          ]},
        # Join synergies back together
        Runic.join([:rune_synergies, :tag_synergies, :stat_modifiers],
          fn synergies -> merge_synergies(synergies) end,
          name: :synergy_join),
        step(&calculate_final_damage/1, name: :final_damage),
        step(&apply_damage/1, name: :apply_damage),
        step(&trigger_on_hit_effects/1, name: :on_hit_effects)
      ]
    )
  end
  
  @doc """
  Status effect workflow - handles DoTs, buffs, debuffs.
  Uses StateMachine for duration tracking.
  """
  def status_effect_workflow do
    workflow(
      name: :status_effects,
      steps: [
        step(&gather_active_effects/1, name: :gather_effects),
        Runic.fan_out(fn effects -> effects end, name: :effect_fan_out),
        # Each effect is a state machine
        state_machine(
          name: :effect_tick,
          init: fn -> %{remaining_ticks: 0, effect: nil} end,
          reducer: fn event, state ->
            case event do
              {:apply, effect, duration} ->
                %{state | effect: effect, remaining_ticks: duration}
              :tick ->
                %{state | remaining_ticks: state.remaining_ticks - 1}
              :remove ->
                %{state | remaining_ticks: 0, effect: nil}
            end
          end,
          reactors: [
            {fn state -> state.remaining_ticks <= 0 and state.effect != nil end,
             fn _state -> {:expired, :remove_effect} end}
          ]
        ),
        Runic.fan_in(&merge_effect_results/1, name: :effect_fan_in)
      ]
    )
  end
  
  @doc """
  AI workflow - enemy decision making.
  Parallelizable per enemy.
  """
  def ai_workflow do
    workflow(
      name: :ai,
      steps: [
        step(&gather_ai_entities/1, name: :gather_ai),
        Runic.fan_out(fn entities -> entities end, name: :ai_fan_out),
        rule(fn
          %{kind: :enemy, ai_state: :idle, player_distance: d} when d < 200 ->
            fn entity -> %{entity | ai_state: :aggressive, target: :player} end
        end, name: :aggro_rule),
        rule(fn
          %{kind: :enemy, ai_state: :aggressive, health_percent: hp} when hp < 0.2 ->
            fn entity -> %{entity | ai_state: :fleeing} end
        end, name: :flee_rule),
        step(&compute_ai_action/1, name: :compute_action),
        Runic.fan_in(&collect_ai_actions/1, name: :ai_fan_in)
      ]
    )
  end
  
  @doc """
  Loot/reward workflow - item generation with rune combinations.
  """  
  def loot_workflow do
    workflow(
      name: :loot,
      steps: [
        rule(fn
          %{event: :enemy_killed, enemy: enemy, player: player} ->
            &generate_loot_table/1
        end, name: :loot_trigger),
        step(&roll_loot/1, name: :roll_loot),
        {step(&generate_item/1, name: :generate_item),
          [
            step(&roll_rune_slots/1, name: :rune_slots),
            step(&roll_affixes/1, name: :affixes),
            step(&apply_player_luck/1, name: :luck_bonus)
          ]},
        Runic.join([:rune_slots, :affixes, :luck_bonus],
          &finalize_item/1,
          name: :item_join)
      ]
    )
  end
end
```

### Workflow Composition for Game Tick

```elixir
defmodule Roguelite.GameTick do
  alias Runic.Workflow
  
  @doc """
  Compose all workflows for a single game tick.
  Some workflows run in parallel, others in sequence.
  """
  def tick_workflow do
    # These can be composed or run independently
    input_wf = Roguelite.Workflows.input_workflow()
    physics_wf = Roguelite.Workflows.physics_workflow()
    combat_wf = Roguelite.Workflows.combat_workflow()
    status_wf = Roguelite.Workflows.status_effect_workflow()
    ai_wf = Roguelite.Workflows.ai_workflow()
    loot_wf = Roguelite.Workflows.loot_workflow()
    
    # Merge into a master workflow
    Workflow.new(name: :game_tick)
    |> Workflow.merge(input_wf)
    |> Workflow.merge(physics_wf)
    |> Workflow.merge(combat_wf)
    |> Workflow.merge(status_wf)
    |> Workflow.merge(ai_wf)
    |> Workflow.merge(loot_wf)
  end
end
```

---

## Parallelism & Coordination Separation

### Independent vs Coordinated Workflows

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PARALLELISM STRATEGY                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  FULLY PARALLEL (no coordination needed in same tick)                       │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐           │
│  │   Entity    │ │   Entity    │ │   Entity    │ │   Entity    │           │
│  │  Physics    │ │   Physics   │ │   Physics   │ │   Physics   │           │
│  │  (player)   │ │  (enemy_1)  │ │  (enemy_2)  │ │  (projectile)│          │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘           │
│                                                                             │
│  PARALLEL PER-ENTITY, SEQUENTIAL PHASES                                     │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │  Phase 1: Gather    →    Phase 2: Process   →   Phase 3: Apply │         │
│  │  (read state)            (parallel compute)     (write state)  │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  REQUIRES COORDINATION (evaluated serially or with locks)                   │
│  ┌─────────────────────────────────────────────────────────────────┐       │
│  │  • Collision resolution between entities                         │       │
│  │  • Shared resource access (treasure chests, spawn points)        │       │
│  │  • Global state mutations (score, floor progression)             │       │
│  └─────────────────────────────────────────────────────────────────┘       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Leveraging Runic's Three-Phase Model

```elixir
defmodule Roguelite.ParallelTick do
  alias Runic.Workflow
  alias Runic.Workflow.Invokable
  
  @doc """
  Execute a game tick with maximum parallelism.
  Uses Runic's prepare_for_dispatch for external scheduling.
  """
  def execute_tick(game_state) do
    workflow = game_state.workflow
    
    # Phase 1: Plan the tick
    workflow = Workflow.plan_eagerly(workflow, game_state)
    
    # Phase 2: Prepare and dispatch runnables
    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
    
    # Group runnables by parallelizability
    {parallel_runnables, serial_runnables} = 
      Enum.split_with(runnables, &parallelizable?/1)
    
    # Execute parallel work concurrently
    parallel_results =
      Task.async_stream(parallel_runnables, fn runnable ->
        Invokable.execute(runnable.node, runnable)
      end, max_concurrency: System.schedulers_online(), timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)
    
    # Apply parallel results
    workflow = Enum.reduce(parallel_results, workflow, &Workflow.apply_runnable(&2, &1))
    
    # Execute serial work sequentially
    workflow = Enum.reduce(serial_runnables, workflow, fn runnable, wf ->
      executed = Invokable.execute(runnable.node, runnable)
      Workflow.apply_runnable(wf, executed)
    end)
    
    # Continue until no more work
    if Workflow.is_runnable?(workflow) do
      execute_tick(%{game_state | workflow: workflow})
    else
      %{game_state | workflow: workflow}
    end
  end
  
  defp parallelizable?(%{node: %{name: name}}) do
    # Physics, AI per-entity, synergy calculations are parallelizable
    name in [:apply_velocity, :compute_ai_action, :rune_synergies, 
             :tag_synergies, :stat_modifiers]
  end
end
```

---

## GenServer + Registry Game Instance Management

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     GAME INSTANCE ARCHITECTURE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        Application Supervisor                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│            ┌───────────────────────┼───────────────────────┐               │
│            ▼                       ▼                       ▼               │
│  ┌─────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐  │
│  │  Roguelite      │   │  Roguelite.Game     │   │  Roguelite.Game     │  │
│  │  .GameRegistry  │   │  .InstanceSupervisor│   │  .MatchmakingServer │  │
│  │  (Registry)     │   │  (DynamicSupervisor)│   │  (GenServer)        │  │
│  └─────────────────┘   └─────────────────────┘   └─────────────────────┘  │
│            │                       │                                        │
│            │           ┌───────────┴───────────┐                           │
│            │           ▼                       ▼                           │
│            │   ┌─────────────────┐   ┌─────────────────┐                   │
│            └──▶│  GameInstance   │   │  GameInstance   │  ...              │
│                │  (GenServer)    │   │  (GenServer)    │                   │
│                │  game_id: "abc" │   │  game_id: "xyz" │                   │
│                │  workflow: ...  │   │  workflow: ...  │                   │
│                │  players: [...]│   │  players: [...]│                   │
│                └─────────────────┘   └─────────────────┘                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Implementation

```elixir
defmodule Roguelite.Application do
  use Application
  
  def start(_type, _args) do
    children = [
      # Registry for looking up game instances by ID
      {Registry, keys: :unique, name: Roguelite.GameRegistry},
      
      # Dynamic supervisor for game instances
      {DynamicSupervisor, 
        strategy: :one_for_one, 
        name: Roguelite.Game.InstanceSupervisor},
      
      # Matchmaking / lobby server
      Roguelite.Game.MatchmakingServer,
      
      # PubSub for game events
      {Phoenix.PubSub, name: Roguelite.PubSub}
    ]
    
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Roguelite.Game.Instance do
  use GenServer
  require Logger
  
  alias Runic.Workflow
  alias Roguelite.Workflows
  
  defstruct [
    :game_id,
    :workflow,
    :game_state,
    :players,
    :tick_rate,
    :tick_timer,
    :status
  ]
  
  @tick_rate_ms 16  # ~60 FPS
  
  # ============================================================================
  # Public API
  # ============================================================================
  
  def start_link(opts) do
    game_id = Keyword.fetch!(opts, :game_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(game_id))
  end
  
  def via_tuple(game_id) do
    {:via, Registry, {Roguelite.GameRegistry, game_id}}
  end
  
  def join(game_id, player_id) do
    GenServer.call(via_tuple(game_id), {:join, player_id})
  end
  
  def leave(game_id, player_id) do
    GenServer.cast(via_tuple(game_id), {:leave, player_id})
  end
  
  def player_input(game_id, player_id, input) do
    GenServer.cast(via_tuple(game_id), {:input, player_id, input})
  end
  
  def get_state(game_id) do
    GenServer.call(via_tuple(game_id), :get_state)
  end
  
  # ============================================================================
  # GenServer Callbacks
  # ============================================================================
  
  @impl true
  def init(opts) do
    game_id = Keyword.fetch!(opts, :game_id)
    seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000))
    
    # Initialize the game workflow
    workflow = build_game_workflow()
    
    # Initialize game state
    game_state = %{
      entities: %{},
      floor: 1,
      seed: seed,
      input_queue: [],
      events: [],
      dungeon: nil
    }
    
    state = %__MODULE__{
      game_id: game_id,
      workflow: workflow,
      game_state: game_state,
      players: %{},
      tick_rate: @tick_rate_ms,
      status: :waiting_for_players
    }
    
    Logger.info("Game instance #{game_id} started")
    
    {:ok, state}
  end
  
  @impl true
  def handle_call({:join, player_id}, _from, state) do
    player_entity = create_player_entity(player_id, state)
    
    new_players = Map.put(state.players, player_id, player_entity.id)
    new_entities = Map.put(state.game_state.entities, player_entity.id, player_entity)
    new_game_state = %{state.game_state | entities: new_entities}
    
    new_state = %{state | 
      players: new_players, 
      game_state: new_game_state
    }
    
    # Start game tick if this is the first player
    new_state = maybe_start_game(new_state)
    
    broadcast_state_update(new_state)
    
    {:reply, {:ok, player_entity.id}, new_state}
  end
  
  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.game_state, state}
  end
  
  @impl true
  def handle_cast({:input, player_id, input}, state) do
    input_event = %{
      player_id: player_id,
      input: input,
      timestamp: System.monotonic_time(:millisecond)
    }
    
    new_input_queue = state.game_state.input_queue ++ [input_event]
    new_game_state = %{state.game_state | input_queue: new_input_queue}
    
    {:noreply, %{state | game_state: new_game_state}}
  end
  
  @impl true
  def handle_cast({:leave, player_id}, state) do
    case Map.pop(state.players, player_id) do
      {nil, _} -> 
        {:noreply, state}
      
      {entity_id, new_players} ->
        new_entities = Map.delete(state.game_state.entities, entity_id)
        new_game_state = %{state.game_state | entities: new_entities}
        
        new_state = %{state | players: new_players, game_state: new_game_state}
        
        if map_size(new_players) == 0 do
          {:stop, :normal, new_state}
        else
          {:noreply, new_state}
        end
    end
  end
  
  @impl true
  def handle_info(:tick, state) do
    # Execute game tick using Runic workflow
    new_state = execute_game_tick(state)
    
    # Broadcast state to connected clients
    broadcast_state_update(new_state)
    
    # Schedule next tick
    schedule_tick(new_state.tick_rate)
    
    {:noreply, new_state}
  end
  
  # ============================================================================
  # Private Functions
  # ============================================================================
  
  defp build_game_workflow do
    # Compose all game workflows
    Roguelite.GameTick.tick_workflow()
  end
  
  defp execute_game_tick(state) do
    # Prepare workflow with current game state as input
    workflow = state.workflow
    tick_input = prepare_tick_input(state.game_state)
    
    # Plan and execute using parallel execution
    workflow = Workflow.plan_eagerly(workflow, tick_input)
    
    # Use parallel execution for maximum throughput
    workflow = Workflow.react_until_satisfied_parallel(workflow, tick_input,
      max_concurrency: System.schedulers_online()
    )
    
    # Extract new game state from productions
    new_game_state = extract_game_state(workflow, state.game_state)
    
    # Reset workflow for next tick (clear facts but keep structure)
    workflow = Workflow.new(name: :game_tick) |> then(&Workflow.merge(&1, build_game_workflow()))
    
    %{state | 
      workflow: workflow, 
      game_state: %{new_game_state | input_queue: [], events: []}
    }
  end
  
  defp prepare_tick_input(game_state) do
    %{
      entities: Map.values(game_state.entities),
      inputs: game_state.input_queue,
      floor: game_state.floor,
      dungeon: game_state.dungeon,
      delta_time: 1.0 / 60.0  # Fixed timestep
    }
  end
  
  defp extract_game_state(workflow, previous_state) do
    productions = Workflow.raw_productions(workflow)
    
    # Merge all entity updates
    updated_entities = 
      productions
      |> Enum.filter(&match?(%{kind: :entity_update}, &1))
      |> Enum.reduce(previous_state.entities, fn update, entities ->
        Map.put(entities, update.entity_id, update.entity)
      end)
    
    # Collect events for frontend
    events = 
      productions
      |> Enum.filter(&match?(%{kind: :game_event}, &1))
    
    %{previous_state | entities: updated_entities, events: events}
  end
  
  defp create_player_entity(player_id, state) do
    spawn_position = find_spawn_position(state)
    
    %{
      id: "player_#{player_id}",
      kind: :player,
      player_id: player_id,
      position: spawn_position,
      velocity: {0.0, 0.0},
      health: %{current: 100, max: 100},
      mana: %{current: 50, max: 50},
      abilities: [:basic_attack, :dash],
      runes: %{},
      tags: [],
      inventory: [],
      stats: %{
        attack: 10,
        defense: 5,
        speed: 100,
        crit_chance: 0.05,
        crit_damage: 1.5
      }
    }
  end
  
  defp find_spawn_position(_state) do
    # TODO: Implement spawn point logic
    {100.0, 100.0}
  end
  
  defp maybe_start_game(%{status: :waiting_for_players, players: players} = state) 
       when map_size(players) >= 1 do
    # Generate dungeon
    dungeon = Roguelite.Dungeon.generate(state.game_state.seed, state.game_state.floor)
    new_game_state = %{state.game_state | dungeon: dungeon}
    
    schedule_tick(state.tick_rate)
    %{state | status: :running, game_state: new_game_state}
  end
  defp maybe_start_game(state), do: state
  
  defp schedule_tick(tick_rate) do
    Process.send_after(self(), :tick, tick_rate)
  end
  
  defp broadcast_state_update(state) do
    Phoenix.PubSub.broadcast(
      Roguelite.PubSub,
      "game:#{state.game_id}",
      {:game_state, prepare_client_state(state)}
    )
  end
  
  defp prepare_client_state(state) do
    %{
      entities: state.game_state.entities,
      floor: state.game_state.floor,
      events: state.game_state.events
    }
  end
end

defmodule Roguelite.Game.InstanceSupervisor do
  @moduledoc """
  Manages dynamic game instance lifecycle.
  """
  
  def start_game(game_id, opts \\ []) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Roguelite.Game.Instance, Keyword.put(opts, :game_id, game_id)}
    )
  end
  
  def stop_game(game_id) do
    case Registry.lookup(Roguelite.GameRegistry, game_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
  
  def list_games do
    Registry.select(Roguelite.GameRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
```

---

## Phase 2: Phoenix LiveView + PlayCanvas Frontend

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          FRONTEND ARCHITECTURE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         Browser Client                               │   │
│  ├─────────────────────────────────────────────────────────────────────┤   │
│  │                                                                      │   │
│  │  ┌──────────────────────────────────────────────────────────────┐   │   │
│  │  │                   Phoenix LiveView Layer                      │   │   │
│  │  │  • Lobby / Matchmaking UI                                     │   │   │
│  │  │  • HUD (health, mana, inventory)                              │   │   │
│  │  │  • Menus, dialogs, tooltips                                   │   │   │
│  │  │  • Chat / Social features                                     │   │   │
│  │  └──────────────────────────────────────────────────────────────┘   │   │
│  │                            ▲                                         │   │
│  │                            │ LiveView Hooks                          │   │
│  │                            ▼                                         │   │
│  │  ┌──────────────────────────────────────────────────────────────┐   │   │
│  │  │                   PlayCanvas Engine Layer                     │   │   │
│  │  │  • 2D/3D top-down rendering                                   │   │   │
│  │  │  • Entity interpolation                                       │   │   │
│  │  │  • Particle effects, animations                               │   │   │
│  │  │  • Input capture (WASD, mouse)                                │   │   │
│  │  └──────────────────────────────────────────────────────────────┘   │   │
│  │                            ▲                                         │   │
│  │                            │ Phoenix Channel (WebSocket)             │   │
│  │                            ▼                                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         Elixir Server                                │   │
│  ├─────────────────────────────────────────────────────────────────────┤   │
│  │  Phoenix Endpoint                                                    │   │
│  │      │                                                               │   │
│  │      ├── LiveView (RogueliteWeb.GameLive)                           │   │
│  │      │       └── mount → subscribe to game PubSub                   │   │
│  │      │                                                               │   │
│  │      └── Channel (RogueliteWeb.GameChannel)                         │   │
│  │              ├── join → Roguelite.Game.Instance.join/2              │   │
│  │              ├── input → Roguelite.Game.Instance.player_input/3     │   │
│  │              └── broadcasts ← Phoenix.PubSub game updates           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Phoenix Channel for Real-time Game Communication

```elixir
defmodule RogueliteWeb.GameChannel do
  use Phoenix.Channel
  require Logger
  
  alias Roguelite.Game.Instance
  
  @impl true
  def join("game:" <> game_id, %{"player_id" => player_id}, socket) do
    case Instance.join(game_id, player_id) do
      {:ok, entity_id} ->
        # Subscribe to game updates
        Phoenix.PubSub.subscribe(Roguelite.PubSub, "game:#{game_id}")
        
        socket = socket
          |> assign(:game_id, game_id)
          |> assign(:player_id, player_id)
          |> assign(:entity_id, entity_id)
        
        # Send initial state
        initial_state = Instance.get_state(game_id)
        
        {:ok, %{entity_id: entity_id, state: initial_state}, socket}
      
      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end
  
  @impl true
  def handle_in("input", %{"type" => type} = payload, socket) do
    input = parse_input(type, payload)
    
    Instance.player_input(
      socket.assigns.game_id,
      socket.assigns.player_id,
      input
    )
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_in("ability", %{"ability_id" => ability_id, "target" => target}, socket) do
    input = %{
      action: :use_ability,
      ability_id: ability_id,
      target: parse_target(target)
    }
    
    Instance.player_input(
      socket.assigns.game_id,
      socket.assigns.player_id,
      input
    )
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_info({:game_state, state}, socket) do
    # Push state update to client
    push(socket, "state_update", %{
      entities: serialize_entities(state.entities),
      events: serialize_events(state.events)
    })
    
    {:noreply, socket}
  end
  
  @impl true
  def terminate(_reason, socket) do
    Instance.leave(socket.assigns.game_id, socket.assigns.player_id)
    :ok
  end
  
  # ============================================================================
  # Helpers
  # ============================================================================
  
  defp parse_input("move", %{"direction" => dir}) do
    %{action: :move, direction: String.to_existing_atom(dir)}
  end
  
  defp parse_input("stop", _) do
    %{action: :stop}
  end
  
  defp parse_input("interact", _) do
    %{action: :interact}
  end
  
  defp parse_target(%{"x" => x, "y" => y}), do: {x, y}
  defp parse_target(%{"entity_id" => id}), do: {:entity, id}
  defp parse_target(nil), do: nil
  
  defp serialize_entities(entities) do
    Map.new(entities, fn {id, entity} ->
      {id, %{
        id: entity.id,
        kind: entity.kind,
        position: %{x: elem(entity.position, 0), y: elem(entity.position, 1)},
        velocity: %{x: elem(entity.velocity, 0), y: elem(entity.velocity, 1)},
        health: entity.health,
        tags: entity.tags
      }}
    end)
  end
  
  defp serialize_events(events) do
    Enum.map(events, fn event ->
      %{
        type: event.type,
        data: event.data,
        timestamp: event.timestamp
      }
    end)
  end
end
```

### Phoenix LiveView for UI Layer

```elixir
defmodule RogueliteWeb.GameLive do
  use RogueliteWeb, :live_view
  
  alias Roguelite.Game.Instance
  alias Roguelite.Game.InstanceSupervisor
  
  @impl true
  def mount(%{"game_id" => game_id}, session, socket) do
    player_id = session["player_id"] || generate_player_id()
    
    if connected?(socket) do
      # Subscribe to game updates for HUD
      Phoenix.PubSub.subscribe(Roguelite.PubSub, "game:#{game_id}")
    end
    
    socket = socket
      |> assign(:game_id, game_id)
      |> assign(:player_id, player_id)
      |> assign(:game_state, nil)
      |> assign(:player_entity, nil)
      |> assign(:show_inventory, false)
      |> assign(:show_rune_menu, false)
    
    {:ok, socket}
  end
  
  @impl true
  def render(assigns) do
    ~H"""
    <div id="game-container" class="relative w-full h-screen bg-gray-900">
      <!-- PlayCanvas Canvas - Managed by Hook -->
      <canvas 
        id="playcanvas-game" 
        phx-hook="PlayCanvasGame"
        data-game-id={@game_id}
        data-player-id={@player_id}
        class="absolute inset-0 w-full h-full"
      />
      
      <!-- HUD Overlay (LiveView managed) -->
      <div class="absolute inset-0 pointer-events-none">
        <!-- Health/Mana Bars -->
        <.hud_bars :if={@player_entity} entity={@player_entity} />
        
        <!-- Ability Bar -->
        <.ability_bar :if={@player_entity} abilities={@player_entity.abilities} />
        
        <!-- Minimap -->
        <.minimap :if={@game_state} state={@game_state} />
        
        <!-- Floor indicator -->
        <div class="absolute top-4 left-4 text-white text-xl font-bold">
          Floor <%= @game_state && @game_state.floor || 1 %>
        </div>
      </div>
      
      <!-- Inventory Modal -->
      <.inventory_modal 
        :if={@show_inventory and @player_entity} 
        entity={@player_entity}
        on_close={JS.push("close_inventory")}
      />
      
      <!-- Rune Socketing Modal -->
      <.rune_menu
        :if={@show_rune_menu and @player_entity}
        entity={@player_entity}
        on_close={JS.push("close_rune_menu")}
      />
    </div>
    """
  end
  
  # ============================================================================
  # HUD Components
  # ============================================================================
  
  defp hud_bars(assigns) do
    ~H"""
    <div class="absolute bottom-4 left-4 pointer-events-auto">
      <!-- Health Bar -->
      <div class="w-64 h-6 bg-gray-800 rounded-full overflow-hidden mb-2">
        <div 
          class="h-full bg-gradient-to-r from-red-600 to-red-400 transition-all duration-200"
          style={"width: #{health_percent(@entity)}%"}
        />
        <span class="absolute inset-0 flex items-center justify-center text-white text-sm font-bold">
          <%= @entity.health.current %> / <%= @entity.health.max %>
        </span>
      </div>
      
      <!-- Mana Bar -->
      <div class="w-64 h-4 bg-gray-800 rounded-full overflow-hidden">
        <div 
          class="h-full bg-gradient-to-r from-blue-600 to-blue-400 transition-all duration-200"
          style={"width: #{mana_percent(@entity)}%"}
        />
      </div>
    </div>
    """
  end
  
  defp ability_bar(assigns) do
    ~H"""
    <div class="absolute bottom-4 left-1/2 transform -translate-x-1/2 pointer-events-auto">
      <div class="flex gap-2 bg-gray-800/80 p-2 rounded-lg">
        <%= for {ability, index} <- Enum.with_index(@abilities) do %>
          <.ability_slot ability={ability} hotkey={index + 1} />
        <% end %>
      </div>
    </div>
    """
  end
  
  defp ability_slot(assigns) do
    ~H"""
    <div class="relative w-16 h-16 bg-gray-700 rounded-lg border-2 border-gray-600 
                hover:border-yellow-400 cursor-pointer transition-all">
      <div class="absolute inset-0 flex items-center justify-center">
        <span class="text-white text-xs"><%= @ability %></span>
      </div>
      <div class="absolute -bottom-1 -right-1 bg-gray-900 text-yellow-400 
                  text-xs px-1 rounded font-bold">
        <%= @hotkey %>
      </div>
    </div>
    """
  end
  
  # ============================================================================
  # Event Handlers
  # ============================================================================
  
  @impl true
  def handle_info({:game_state, state}, socket) do
    player_entity = get_player_entity(state, socket.assigns.player_id)
    
    socket = socket
      |> assign(:game_state, state)
      |> assign(:player_entity, player_entity)
    
    {:noreply, socket}
  end
  
  @impl true
  def handle_event("toggle_inventory", _, socket) do
    {:noreply, assign(socket, :show_inventory, !socket.assigns.show_inventory)}
  end
  
  @impl true
  def handle_event("close_inventory", _, socket) do
    {:noreply, assign(socket, :show_inventory, false)}
  end
  
  @impl true  
  def handle_event("socket_rune", %{"ability_id" => ability_id, "rune_id" => rune_id, "slot" => slot}, socket) do
    # Send rune socketing command to game instance
    Instance.player_input(
      socket.assigns.game_id,
      socket.assigns.player_id,
      %{action: :socket_rune, ability_id: ability_id, rune_id: rune_id, slot: slot}
    )
    
    {:noreply, socket}
  end
  
  # ============================================================================
  # Helpers
  # ============================================================================
  
  defp health_percent(entity) do
    (entity.health.current / entity.health.max) * 100
  end
  
  defp mana_percent(entity) do
    (entity.mana.current / entity.mana.max) * 100
  end
  
  defp get_player_entity(state, player_id) do
    Enum.find(Map.values(state.entities), fn entity ->
      entity[:player_id] == player_id
    end)
  end
  
  defp generate_player_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```

### PlayCanvas LiveView Hook

```javascript
// assets/js/hooks/playcanvas_game.js

import * as pc from 'playcanvas';

const PlayCanvasGame = {
  mounted() {
    this.gameId = this.el.dataset.gameId;
    this.playerId = this.el.dataset.playerId;
    this.entities = new Map();
    this.inputState = { up: false, down: false, left: false, right: false };
    
    // Initialize PlayCanvas
    this.initPlayCanvas();
    
    // Connect to game channel
    this.connectChannel();
    
    // Setup input handlers
    this.setupInputHandlers();
  },
  
  initPlayCanvas() {
    // Create PlayCanvas application
    const canvas = this.el;
    
    this.app = new pc.Application(canvas, {
      mouse: new pc.Mouse(canvas),
      keyboard: new pc.Keyboard(window),
      touch: new pc.TouchDevice(canvas)
    });
    
    // Configure app
    this.app.setCanvasFillMode(pc.FILLMODE_FILL_WINDOW);
    this.app.setCanvasResolution(pc.RESOLUTION_AUTO);
    
    // Setup 2D camera for top-down view
    this.setupCamera();
    
    // Setup lighting
    this.setupLighting();
    
    // Create ground plane
    this.createGround();
    
    // Start the application
    this.app.start();
    
    // Register update loop
    this.app.on('update', (dt) => this.gameLoop(dt));
  },
  
  setupCamera() {
    const camera = new pc.Entity('camera');
    camera.addComponent('camera', {
      clearColor: new pc.Color(0.1, 0.1, 0.15),
      projection: pc.PROJECTION_ORTHOGRAPHIC,
      orthoHeight: 10
    });
    camera.setPosition(0, 20, 0);
    camera.setEulerAngles(-90, 0, 0);
    this.camera = camera;
    this.app.root.addChild(camera);
  },
  
  setupLighting() {
    const light = new pc.Entity('light');
    light.addComponent('light', {
      type: 'directional',
      color: new pc.Color(1, 0.95, 0.9),
      intensity: 1.2
    });
    light.setEulerAngles(45, 45, 0);
    this.app.root.addChild(light);
  },
  
  createGround() {
    const ground = new pc.Entity('ground');
    ground.addComponent('render', {
      type: 'plane'
    });
    ground.setLocalScale(50, 1, 50);
    
    const material = new pc.StandardMaterial();
    material.diffuse = new pc.Color(0.2, 0.2, 0.25);
    ground.render.meshInstances[0].material = material;
    
    this.app.root.addChild(ground);
  },
  
  connectChannel() {
    // Connect via Phoenix Channel
    const socket = new Phoenix.Socket("/socket", {
      params: { token: window.userToken }
    });
    socket.connect();
    
    this.channel = socket.channel(`game:${this.gameId}`, {
      player_id: this.playerId
    });
    
    this.channel.join()
      .receive("ok", (resp) => {
        console.log("Joined game successfully", resp);
        this.myEntityId = resp.entity_id;
        this.handleStateUpdate(resp.state);
      })
      .receive("error", (resp) => {
        console.error("Unable to join game", resp);
      });
    
    // Handle state updates from server
    this.channel.on("state_update", (payload) => {
      this.handleStateUpdate(payload);
    });
  },
  
  setupInputHandlers() {
    // WASD movement
    window.addEventListener('keydown', (e) => {
      switch(e.key.toLowerCase()) {
        case 'w': this.inputState.up = true; break;
        case 's': this.inputState.down = true; break;
        case 'a': this.inputState.left = true; break;
        case 'd': this.inputState.right = true; break;
        case '1': case '2': case '3': case '4': case '5':
          this.useAbility(parseInt(e.key) - 1);
          break;
        case 'i':
          // Toggle inventory via LiveView
          this.pushEvent("toggle_inventory", {});
          break;
      }
      this.sendMovementInput();
    });
    
    window.addEventListener('keyup', (e) => {
      switch(e.key.toLowerCase()) {
        case 'w': this.inputState.up = false; break;
        case 's': this.inputState.down = false; break;
        case 'a': this.inputState.left = false; break;
        case 'd': this.inputState.right = false; break;
      }
      this.sendMovementInput();
    });
    
    // Mouse for targeting
    this.el.addEventListener('click', (e) => {
      const worldPos = this.screenToWorld(e.clientX, e.clientY);
      this.targetPosition = worldPos;
    });
  },
  
  sendMovementInput() {
    const { up, down, left, right } = this.inputState;
    
    if (up && !down && !left && !right) {
      this.channel.push("input", { type: "move", direction: "up" });
    } else if (down && !up && !left && !right) {
      this.channel.push("input", { type: "move", direction: "down" });
    } else if (left && !right && !up && !down) {
      this.channel.push("input", { type: "move", direction: "left" });
    } else if (right && !left && !up && !down) {
      this.channel.push("input", { type: "move", direction: "right" });
    } else if (up && left) {
      // Diagonal movement - could be handled by server
      this.channel.push("input", { type: "move", direction: "up_left" });
    } else if (!up && !down && !left && !right) {
      this.channel.push("input", { type: "stop" });
    }
  },
  
  useAbility(index) {
    const abilities = this.getPlayerAbilities();
    if (abilities && abilities[index]) {
      this.channel.push("ability", {
        ability_id: abilities[index],
        target: this.targetPosition ? 
          { x: this.targetPosition.x, y: this.targetPosition.z } : null
      });
    }
  },
  
  handleStateUpdate(state) {
    // Update/create entities
    for (const [id, entityData] of Object.entries(state.entities)) {
      if (this.entities.has(id)) {
        // Update existing entity
        this.updateEntity(id, entityData);
      } else {
        // Create new entity
        this.createEntity(id, entityData);
      }
    }
    
    // Remove entities no longer in state
    for (const id of this.entities.keys()) {
      if (!state.entities[id]) {
        this.removeEntity(id);
      }
    }
    
    // Process events (damage numbers, effects, etc.)
    if (state.events) {
      for (const event of state.events) {
        this.handleGameEvent(event);
      }
    }
  },
  
  createEntity(id, data) {
    const entity = new pc.Entity(id);
    
    // Add visual based on entity kind
    const mesh = this.getMeshForKind(data.kind);
    entity.addComponent('render', { type: mesh });
    
    // Set initial position
    entity.setPosition(data.position.x / 10, 0.5, data.position.y / 10);
    
    // Store reference
    this.entities.set(id, {
      pcEntity: entity,
      serverState: data,
      interpolatedPos: { x: data.position.x, y: data.position.y }
    });
    
    this.app.root.addChild(entity);
    
    // Highlight player's own entity
    if (id === this.myEntityId) {
      this.setupPlayerIndicator(entity);
    }
  },
  
  updateEntity(id, data) {
    const entityRef = this.entities.get(id);
    if (!entityRef) return;
    
    // Store server state for interpolation
    entityRef.serverState = data;
  },
  
  removeEntity(id) {
    const entityRef = this.entities.get(id);
    if (entityRef) {
      entityRef.pcEntity.destroy();
      this.entities.delete(id);
    }
  },
  
  gameLoop(dt) {
    // Interpolate entity positions for smooth movement
    for (const [id, entityRef] of this.entities) {
      const target = entityRef.serverState.position;
      const current = entityRef.interpolatedPos;
      
      // Lerp towards server position
      const lerpFactor = Math.min(1, dt * 15);
      current.x += (target.x - current.x) * lerpFactor;
      current.y += (target.y - current.y) * lerpFactor;
      
      entityRef.pcEntity.setPosition(current.x / 10, 0.5, current.y / 10);
    }
    
    // Follow player with camera
    if (this.myEntityId && this.entities.has(this.myEntityId)) {
      const playerPos = this.entities.get(this.myEntityId).pcEntity.getPosition();
      this.camera.setPosition(playerPos.x, 20, playerPos.z);
    }
  },
  
  handleGameEvent(event) {
    switch(event.type) {
      case 'damage':
        this.showDamageNumber(event.data);
        break;
      case 'ability_used':
        this.playAbilityEffect(event.data);
        break;
      case 'item_drop':
        this.createLootDrop(event.data);
        break;
      case 'level_up':
        this.playLevelUpEffect(event.data);
        break;
    }
  },
  
  showDamageNumber(data) {
    // Create floating damage text
    // Could use HTML overlay or 3D text
    console.log(`Damage: ${data.amount} to ${data.target}`);
  },
  
  getMeshForKind(kind) {
    switch(kind) {
      case 'player': return 'capsule';
      case 'enemy': return 'sphere';
      case 'projectile': return 'sphere';
      case 'item': return 'box';
      default: return 'box';
    }
  },
  
  setupPlayerIndicator(entity) {
    // Add a subtle glow or marker under player
    const indicator = new pc.Entity('indicator');
    indicator.addComponent('render', { type: 'cylinder' });
    indicator.setLocalScale(1.5, 0.1, 1.5);
    indicator.setLocalPosition(0, -0.4, 0);
    
    const material = new pc.StandardMaterial();
    material.diffuse = new pc.Color(0.2, 0.6, 1.0);
    material.emissive = new pc.Color(0.1, 0.3, 0.5);
    material.opacity = 0.5;
    material.blendType = pc.BLEND_ADDITIVE;
    indicator.render.meshInstances[0].material = material;
    
    entity.addChild(indicator);
  },
  
  screenToWorld(screenX, screenY) {
    // Convert screen coordinates to world position
    const camera = this.camera.camera;
    const from = camera.screenToWorld(screenX, screenY, camera.nearClip);
    const to = camera.screenToWorld(screenX, screenY, camera.farClip);
    
    // Raycast to ground plane (y = 0)
    const t = -from.y / (to.y - from.y);
    return new pc.Vec3(
      from.x + t * (to.x - from.x),
      0,
      from.z + t * (to.z - from.z)
    );
  },
  
  destroyed() {
    if (this.channel) {
      this.channel.leave();
    }
    if (this.app) {
      this.app.destroy();
    }
  }
};

export default PlayCanvasGame;
```

### Hook Registration

```javascript
// assets/js/app.js

import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import PlayCanvasGame from "./hooks/playcanvas_game";

const Hooks = {
  PlayCanvasGame
};

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken }
});

liveSocket.connect();
```

### Router Configuration

```elixir
# lib/roguelite_web/router.ex

defmodule RogueliteWeb.Router do
  use RogueliteWeb, :router
  
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RogueliteWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :ensure_player_session
  end
  
  scope "/", RogueliteWeb do
    pipe_through :browser
    
    live "/", LobbyLive, :index
    live "/game/:game_id", GameLive, :show
  end
  
  defp ensure_player_session(conn, _opts) do
    case get_session(conn, "player_id") do
      nil ->
        player_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
        put_session(conn, "player_id", player_id)
      _ ->
        conn
    end
  end
end
```

---

## Summary

This architecture leverages Runic's unique strengths:

1. **Dataflow as ECS**: Entities are facts, systems are workflow steps/rules, and the graph tracks causality
2. **Parallel Execution**: Independent per-entity processing via `fan_out` + `fan_in` and `Task.async_stream`
3. **Combinatorial Depth**: Rune synergies, tag bonuses, and stat interactions create massive build space
4. **Process Isolation**: Each game instance is a supervised GenServer with its own workflow
5. **Clean Frontend Split**: LiveView handles UI/HUD, PlayCanvas handles rendering, Channel handles real-time sync

The roguelite loop naturally maps to Runic's reactive evaluation model - inputs flow through rules that trigger combat, effects, and loot generation, producing new facts that represent the evolving game state.

---

## Clarifying Questions for Implementation Planning

### Game Design & Mechanics

1. **Single-player or Multiplayer?**
   - Is this solo roguelite, co-op (2-4 players), or competitive?
   - If co-op: shared screen or networked? Do players share loot or compete for it?
   - _Answer:_

2. **Run Length & Pacing**
   - Target run duration? (15 min quick runs vs 1-2 hour epic runs)
   - How many floors per run? Boss frequency?
   - _Answer:_

3. **Death & Permadeath Model**
   - Full permadeath (lose everything) or partial (keep some currency/unlocks)?
   - Any revival mechanics (co-op revive, consumable respawn)?
   - _Answer:_

4. **Combat Feel & Timing**
   - Action-focused (Hades-like) or more tactical/slower (Slay the Spire pacing)?
   - Real-time or turn-based/pause-able?
   - Target actions-per-minute for skilled play?
   - _Answer:_

5. **Rune Acquisition & Socketing**
   - When can players socket runes? (Any time, only at shrines, between floors?)
   - Can runes be removed/swapped or are they permanent once socketed?
   - Rune inventory limit?
   - _Answer:_

6. **Ability Unlocking**
   - Start with 2 abilities and find more? Or choose loadout at run start?
   - Max abilities equippable at once?
   - _Answer:_

7. **Enemy Design Philosophy**
   - Few complex enemies or many simple enemy types?
   - Do enemies have the same rune/synergy system as players?
   - _Answer:_

### Meta-Progression (Between Runs)

8. **Persistent Unlocks**
   - What persists between runs? (Character unlocks, rune pool expansion, stat upgrades, cosmetics?)
   - Currency types (single meta-currency vs multiple)?
   - _Answer:_

9. **Character Classes/Archetypes**
   - Single character with build variety, or multiple distinct classes?
   - If classes: how many at launch? Different starting abilities/stats?
   - _Answer:_

10. **Achievement/Mastery System**
    - Unlock conditions for new runes/items? (Kill X enemies with fire, reach floor 10, etc.)
    - Difficulty scaling unlocks (Ascension levels like Slay the Spire)?
    - _Answer:_

### Technical & Scope

11. **Target Platform & Performance**
    - Web-only or native clients later?
    - Target device specs? (Mobile support?)
    - Acceptable latency for multiplayer? (< 50ms for action, < 200ms for tactical)
    - _Answer:_

12. **Persistence & Saves**
    - Can players save mid-run and resume later?
    - Where is game state persisted? (Postgres, ETS, Redis?)
    - Account system or anonymous play?
    - _Answer:_

13. **Dungeon Generation**
    - Pre-designed room templates with random connections, or fully procedural?
    - Room size/complexity? (Single screen vs scrolling areas)
    - Deterministic from seed (for replays/sharing)?
    - _Answer:_

14. **Entity Scale**
    - Max concurrent entities per game instance? (Enemies, projectiles, effects)
    - Target: 50? 200? 1000+?
    - _Answer:_

15. **Tick Rate & Input Model**
    - Fixed timestep (60 tick/s) or variable?
    - Client-side prediction for responsiveness, or authoritative server only?
    - Rollback netcode needed?
    - _Answer:_

### Art & Audio Direction

16. **Visual Style**
    - Pixel art, low-poly 3D, stylized 2D, realistic?
    - Reference games for art direction?
    - _Answer:_

17. **Camera Perspective**
    - Pure top-down (90°) or angled isometric (45°)?
    - Fixed camera or player-controlled rotation/zoom?
    - _Answer:_

18. **Asset Pipeline**
    - Placeholder art for MVP or need artist from start?
    - Audio: procedural/minimal or full soundtrack?
    - _Answer:_

### MVP & Prioritization

19. **MVP Scope**
    - What's the smallest playable slice? (1 character, 3 floors, 5 enemies, 8 runes?)
    - Core loop validation before full synergy system?
    - _Answer:_

20. **Development Phases**
    - Phase 1: Core combat + movement?
    - Phase 2: Rune system + synergies?
    - Phase 3: Meta-progression + persistence?
    - Phase 4: Multiplayer?
    - _Answer:_

21. **Runic as Showcase**
    - Is this game a showcase for Runic's capabilities, or Runic is incidental?
    - Are there specific Runic features we want to stress-test? (Hot workflow modification, distributed execution, etc.)
    - _Answer:_

22. **Timeline & Resources**
    - Target timeline for playable prototype?
    - Team size / who's building what?
    - _Answer:_

### Multiplayer-Specific (if applicable)

23. **Session Model**
    - Matchmaking with randoms or invite-only?
    - Drop-in/drop-out or locked sessions?
    - _Answer:_

24. **Shared State**
    - Shared resources (gold, health potions) or individual?
    - Friendly fire?
    - _Answer:_

25. **Scaling**
    - Target concurrent games? (10, 100, 1000+?)
    - Single node or distributed across cluster?
    - _Answer:_

---

*Fill in answers above to generate a prioritized implementation backlog.*
