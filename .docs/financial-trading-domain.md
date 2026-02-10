# Runic for Multi-Agent Financial Trading Systems

## Executive Summary

This document explores applying Runic's workflow orchestration capabilities to private fund financial trading, with particular focus on multi-agent LLM systems inspired by the TradingAgents framework (Xiao et al., 2024). We examine how Runic's existing primitives map to trading domain concepts and propose new components tailored for high-frequency decision making, risk management, and agent coordination.

## Domain Overview: Private Fund Trading

### The Trading Firm Model

Modern quantitative trading firms operate as coordinated systems of specialized roles:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          TRADING FIRM                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                      DATA INGESTION                              │   │
│  │  Market Data │ News Feeds │ Social Sentiment │ Economic Data    │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│                              ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                      ANALYST TEAM                                │   │
│  │  Fundamental │ Technical │ Sentiment │ News │ Macro             │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│                              ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                     RESEARCH TEAM                                │   │
│  │         Bull Researcher  ◄──► Debate ◄──►  Bear Researcher      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│                              ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                      TRADER AGENTS                               │   │
│  │  Aggressive │ Moderate │ Conservative │ Momentum │ Mean-Revert  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│                              ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                   RISK MANAGEMENT                                │   │
│  │   Position Limits │ Drawdown Guards │ Correlation │ Liquidity   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│                              ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    FUND MANAGER                                  │   │
│  │              Final Approval │ Execution                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Requirements

1. **Real-time data processing**: Market data streams at millisecond granularity
2. **Multi-signal fusion**: Combining technical, fundamental, and sentiment signals
3. **Adversarial reasoning**: Bull vs. Bear perspective debate
4. **Risk constraints**: Hard limits on positions, drawdown, and exposure
5. **Audit trails**: Full explainability for regulatory compliance
6. **Dynamic strategy adaptation**: Runtime modification of trading logic

## Mapping Runic Primitives to Trading

### Facts as Market Events

In Runic, inputs are **Facts**—immutable data flowing through the workflow. In trading:

```elixir
# Market data events as Facts
%Fact{value: %MarketTick{symbol: "AAPL", price: 178.50, volume: 1200, timestamp: ~U[...]}}
%Fact{value: %NewsEvent{headline: "Apple announces...", sentiment: 0.72, source: :reuters}}
%Fact{value: %OrderFill{order_id: "123", filled_qty: 100, fill_price: 178.48}}

# Agent outputs as Facts
%Fact{value: %AnalystReport{agent: :technical, signal: :bullish, confidence: 0.85}}
%Fact{value: %TradeRecommendation{action: :buy, symbol: "AAPL", size: 500, rationale: "..."}}
%Fact{value: %RiskAssessment{approved: true, adjusted_size: 400, notes: "..."}}
```

### Steps as Agent Actions

Each agent or computation is a **Step**:

```elixir
require Runic
import Runic

# Technical analyst agent
technical_analyst = step(
  name: :technical_analyst,
  work: fn %MarketData{} = data ->
    indicators = calculate_indicators(data)
    llm_analysis = TechnicalAgent.analyze(data, indicators)
    
    %AnalystReport{
      agent: :technical,
      signal: llm_analysis.signal,
      confidence: llm_analysis.confidence,
      indicators: indicators,
      reasoning: llm_analysis.chain_of_thought
    }
  end
)

# Sentiment analyst agent
sentiment_analyst = step(
  name: :sentiment_analyst,
  work: fn %{news: news, social: social} ->
    sentiment_scores = SentimentAgent.analyze(news, social)
    
    %AnalystReport{
      agent: :sentiment,
      signal: sentiment_scores.overall_signal,
      confidence: sentiment_scores.confidence,
      sources: sentiment_scores.source_breakdown
    }
  end
)
```

### Rules as Trading Logic

**Rules** express conditional trading logic:

```elixir
# Current rule syntax
trading_signal_rule = rule(
  name: :momentum_breakout,
  condition: fn %AnalystReport{signal: signal, confidence: conf} ->
    signal == :bullish and conf > 0.8
  end,
  reaction: fn report ->
    %TradeSignal{
      direction: :long,
      strength: report.confidence,
      source_agent: report.agent
    }
  end
)

# With proposed explicit DSL (from rule-dsl-plan.md)
rule name: :risk_adjusted_entry do
  given report: %AnalystReport{signal: :bullish},
        portfolio: _
  
  when report.confidence > 0.75
   and state_of(:portfolio_accumulator).cash_available > 10_000
   and state_of(:risk_monitor).current_drawdown < 0.05
   and not step_ran?(:position_opened_today, report.symbol)
  
  then fn %{report: report} ->
    %TradeRecommendation{
      action: :buy,
      symbol: report.symbol,
      size: calculate_position_size(report),
      rationale: report.reasoning
    }
  end
end
```

### Accumulators as Portfolio State

**Accumulators** maintain running state—perfect for portfolio tracking:

```elixir
# Portfolio state accumulator
portfolio_state = state_machine(
  name: :portfolio_accumulator,
  init: %Portfolio{
    positions: %{},
    cash: 1_000_000,
    total_value: 1_000_000,
    daily_pnl: 0,
    max_drawdown: 0
  },
  
  reducer: fn
    %Portfolio{} = state, %OrderFill{} = fill ->
      update_portfolio_with_fill(state, fill)
    
    %Portfolio{} = state, %MarketTick{} = tick ->
      mark_to_market(state, tick)
    
    %Portfolio{} = state, %DailyReset{} ->
      reset_daily_metrics(state)
  end,
  
  reactors: [
    fn %Portfolio{current_drawdown: dd} when dd > 0.10 ->
      %RiskAlert{type: :max_drawdown_breach, value: dd}
    end,
    
    fn %Portfolio{positions: positions} ->
      concentration = max_position_concentration(positions)
      if concentration > 0.25 do
        %RiskAlert{type: :concentration_warning, value: concentration}
      end
    end
  ]
)
```

### Fan-Out/Fan-In for Parallel Analysis

The **Analyst Team** pattern maps perfectly to Runic's parallel execution:

```elixir
analyst_team_workflow = workflow(
  name: :analyst_team,
  steps: [
    # Fan-out: Market data goes to all analysts in parallel
    {step(&prepare_market_context/1), [map([
      step(name: :fundamental_analyst, work: &FundamentalAgent.analyze/1),
      step(name: :technical_analyst, work: &TechnicalAgent.analyze/1),
      step(name: :sentiment_analyst, work: &SentimentAgent.analyze/1),
      step(name: :news_analyst, work: &NewsAgent.analyze/1),
      step(name: :macro_analyst, work: &MacroAgent.analyze/1)
    ])}
  ]
)

# joins all reports before proceeding
analyst_team_workflow = 
  add(
    step(name: :analyst_consensus, fn reports ->
    %AnalystConsensus{
        reports: reports,
        aggregated_signal: aggregate_signals(reports),
        confidence: weighted_confidence(reports)
      }
    end),
    to: [:fundamental_analyst, :technical_analyst, :sentiment_analyst, 
           :news_analyst, :macro_analyst]
  )
```

## Multi-Agent LLM Architecture with Runic

### The TradingAgents Pattern

Based on the TradingAgents paper, we model the multi-agent system as a Runic workflow:

```elixir
defmodule TradingFirm do
  use Runic.Rules  # Proposed module for rule collections
  
  def build_workflow(config) do
    workflow(name: :trading_firm)
    |> add_data_ingestion_layer()
    |> add_analyst_team()
    |> add_research_debate()
    |> add_trader_agents()
    |> add_risk_management()
    |> add_fund_manager()
  end
  
  defp add_analyst_team(wrk) do
    wrk
    |> add(step(&prepare_context/1), to: :market_data_normalized)
    |> add(analyst_agent(:fundamental, FundamentalPrompts), to: :prepare_context)
    |> add(analyst_agent(:technical, TechnicalPrompts), to: :prepare_context)
    |> add(analyst_agent(:sentiment, SentimentPrompts), to: :prepare_context)
    |> add(analyst_agent(:news, NewsPrompts), to: :prepare_context)
  end
  
  defp add_research_debate(wrk) do
    # Join analyst reports, then spawn bull/bear debate
    wrk
    |> add(join(name: :analyst_reports, inputs: analyst_names()), to: analyst_names())
    |> add(debate_workflow(:bull_bear_debate), to: :analyst_reports)
  end
  
  defp add_trader_agents(wrk) do
    wrk
    |> add(trader_agent(:aggressive, risk_tolerance: :high), to: :bull_bear_debate)
    |> add(trader_agent(:moderate, risk_tolerance: :medium), to: :bull_bear_debate)
    |> add(trader_agent(:conservative, risk_tolerance: :low), to: :bull_bear_debate)
    |> add(join(name: :trader_consensus, inputs: [:aggressive, :moderate, :conservative]), 
           to: [:aggressive, :moderate, :conservative])
  end
end
```

### Debate Workflow Pattern

The **adversarial debate** between Bull and Bear researchers is a novel pattern:

```elixir
defmodule DebateWorkflow do
  @doc """
  Creates a multi-round debate workflow between opposing perspectives.
  
  Each round:
  1. Bull researcher makes argument based on analyst reports + previous debate
  2. Bear researcher counters with opposing view
  3. Moderator evaluates if consensus reached or more rounds needed
  """
  def debate_workflow(name, opts \\ []) do
    max_rounds = Keyword.get(opts, :max_rounds, 3)
    
    workflow(name: name)
    |> add(debate_accumulator(max_rounds))
    |> add(bull_researcher_step(), to: :debate_state)
    |> add(bear_researcher_step(), to: :bull_argument)
    |> add(moderator_step(), to: :bear_argument)
  end
  
  defp debate_accumulator(max_rounds) do
    state_machine(
      name: :debate_state,
      init: %DebateState{
        round: 0,
        max_rounds: max_rounds,
        history: [],
        consensus: nil,
        status: :in_progress
      },
      
      reducer: fn
        %DebateState{round: r, max_rounds: max} = state, %Argument{} = arg 
        when r < max ->
          %{state | 
            round: r + 1,
            history: state.history ++ [arg]
          }
        
        %DebateState{} = state, %ModeratorDecision{consensus: true} = decision ->
          %{state | 
            status: :concluded,
            consensus: decision.conclusion
          }
        
        %DebateState{round: r, max_rounds: max} = state, %ModeratorDecision{} 
        when r >= max ->
          %{state | status: :max_rounds_reached}
      end,
      
      reactors: [
        fn %DebateState{status: :concluded, consensus: consensus} ->
          %DebateConclusion{winner: consensus.perspective, reasoning: consensus.summary}
        end
      ]
    )
  end
end
```

### Agent as Step with LLM Backend

```elixir
defmodule AgentStep do
  @doc """
  Creates a Runic step backed by an LLM agent with ReAct-style reasoning.
  """
  def agent_step(name, opts) do
    role = Keyword.fetch!(opts, :role)
    system_prompt = Keyword.fetch!(opts, :system_prompt)
    tools = Keyword.get(opts, :tools, [])
    model = Keyword.get(opts, :model, "gpt-4")
    
    step(
      name: name,
      work: fn context ->
        messages = build_messages(system_prompt, context)
        
        # ReAct loop: Reasoning + Acting
        react_loop(messages, tools, model, max_iterations: 5)
      end
    )
  end
  
  defp react_loop(messages, tools, model, opts) do
    case LLM.chat(model, messages, tools: tools) do
      {:tool_call, tool_name, args} ->
        result = execute_tool(tool_name, args, tools)
        updated_messages = messages ++ [tool_result(tool_name, result)]
        react_loop(updated_messages, tools, model, opts)
      
      {:response, content} ->
        parse_structured_output(content)
    end
  end
end
```

## Proposed New Components for Trading

### 1. `Quorum` — Multi-Agent Voting

A new component for weighted voting across multiple agents:

```elixir
defmodule Runic.Workflow.Quorum do
  @moduledoc """
  A component that collects votes from multiple upstream agents and 
  produces a consensus decision based on configurable voting rules.
  """
  
  defstruct [
    :name,
    :voters,           # List of upstream component names
    :voting_rule,      # :majority | :unanimous | :weighted | custom fn
    :weights,          # Optional weight map for :weighted rule
    :timeout,          # Max wait time for all votes
    :quorum_threshold, # Minimum voters needed (e.g., 3 of 5)
    :hash
  ]
  
  def new(opts) do
    %__MODULE__{
      name: opts[:name],
      voters: opts[:voters],
      voting_rule: opts[:voting_rule] || :majority,
      weights: opts[:weights] || %{},
      timeout: opts[:timeout] || 5_000,
      quorum_threshold: opts[:quorum_threshold] || length(opts[:voters])
    }
  end
end

# Usage
trader_quorum = Quorum.new(
  name: :trader_vote,
  voters: [:aggressive_trader, :moderate_trader, :conservative_trader],
  voting_rule: :weighted,
  weights: %{
    aggressive_trader: 0.2,
    moderate_trader: 0.5,
    conservative_trader: 0.3
  },
  quorum_threshold: 2  # Need at least 2 traders to vote
)
```

### 2. `Circuit` — Trading Circuit Breaker

Halt processing when risk thresholds are breached:

```elixir
defmodule Runic.Workflow.Circuit do
  @moduledoc """
  A circuit breaker component that can halt downstream processing
  based on accumulated state or external signals.
  """
  
  defstruct [
    :name,
    :monitor,          # Component name to monitor
    :trip_condition,   # fn(state) -> boolean
    :reset_condition,  # fn(state) -> boolean
    :cooldown,         # Minimum time before reset allowed
    :on_trip,          # Optional callback/fact emission
    :status,           # :closed | :open | :half_open
    :hash
  ]
end

# Usage: Halt trading if drawdown exceeds limit
drawdown_circuit = Circuit.new(
  name: :drawdown_breaker,
  monitor: :portfolio_accumulator,
  trip_condition: fn portfolio ->
    portfolio.current_drawdown > 0.10  # 10% max drawdown
  end,
  reset_condition: fn portfolio ->
    portfolio.current_drawdown < 0.05  # Reset when recovered to 5%
  end,
  cooldown: :timer.hours(1),
  on_trip: fn portfolio ->
    %TradingHalted{
      reason: :max_drawdown,
      value: portfolio.current_drawdown,
      timestamp: DateTime.utc_now()
    }
  end
)
```

### 3. `Throttle` — Rate Limiting

Control order submission rate:

```elixir
defmodule Runic.Workflow.Throttle do
  @moduledoc """
  Rate limits fact flow through a component.
  Essential for order submission limits and API rate management.
  """
  
  defstruct [
    :name,
    :rate,             # {count, window} e.g., {100, :per_second}
    :burst,            # Allow burst above rate temporarily
    :overflow_policy,  # :drop | :queue | :backpressure
    :priority_fn,      # Optional fn to prioritize which facts pass
    :hash
  ]
end

# Limit order submissions
order_throttle = Throttle.new(
  name: :order_rate_limiter,
  rate: {10, :per_second},
  burst: 20,
  overflow_policy: :queue,
  priority_fn: fn order ->
    case order.type do
      :stop_loss -> 100    # Highest priority
      :take_profit -> 90
      :market -> 50
      :limit -> 10
    end
  end
)
```

### 4. `Window` — Time-Windowed Aggregation

Aggregate facts over time windows:

```elixir
defmodule Runic.Workflow.Window do
  @moduledoc """
  Collects facts over a time window and emits aggregated results.
  Essential for VWAP calculations, volume analysis, etc.
  """
  
  defstruct [
    :name,
    :window_type,      # :tumbling | :sliding | :session
    :duration,         # Window size
    :slide,            # For sliding windows, the slide interval
    :aggregator,       # fn([facts]) -> aggregated_fact
    :watermark,        # How long to wait for late facts
    :hash
  ]
end

# Calculate 5-minute VWAP
vwap_window = Window.new(
  name: :vwap_5min,
  window_type: :tumbling,
  duration: :timer.minutes(5),
  aggregator: fn ticks ->
    total_value = Enum.sum(for t <- ticks, do: t.price * t.volume)
    total_volume = Enum.sum(for t <- ticks, do: t.volume)
    
    %VWAP{
      value: total_value / total_volume,
      volume: total_volume,
      tick_count: length(ticks),
      window_end: DateTime.utc_now()
    }
  end
)
```

### 5. `Arbiter` — Conflict Resolution

Resolve conflicting signals from multiple sources:

```elixir
defmodule Runic.Workflow.Arbiter do
  @moduledoc """
  Resolves conflicts between multiple facts competing for the same decision.
  Implements various conflict resolution strategies.
  """
  
  defstruct [
    :name,
    :strategy,         # :priority | :recency | :confidence | :custom
    :priority_order,   # For :priority strategy
    :tie_breaker,      # fn when multiple facts have same priority
    :emit_conflicts,   # Whether to emit conflict events for audit
    :hash
  ]
end

# Resolve conflicting trade signals
signal_arbiter = Arbiter.new(
  name: :trade_signal_arbiter,
  strategy: :confidence,
  tie_breaker: fn signals ->
    # If same confidence, prefer the more conservative
    Enum.min_by(signals, fn s -> abs(s.recommended_size) end)
  end,
  emit_conflicts: true  # Emit for audit trail
)
```

### 6. `Saga` — Multi-Step Trade Execution

Coordinate complex multi-leg trades with compensation:

```elixir
defmodule Runic.Workflow.Saga do
  @moduledoc """
  Orchestrates multi-step transactions with rollback/compensation support.
  Essential for complex order types (spreads, pairs, baskets).
  """
  
  defstruct [
    :name,
    :steps,            # [{action_fn, compensation_fn}, ...]
    :isolation,        # :serializable | :read_committed
    :timeout,          # Overall saga timeout
    :on_complete,      # Success callback
    :on_compensate,    # Compensation triggered callback
    :hash
  ]
end

# Pairs trade execution saga
pairs_trade_saga = Saga.new(
  name: :pairs_trade,
  steps: [
    {&submit_short_leg/1, &cancel_short_leg/1},
    {&wait_for_short_fill/1, &close_short_position/1},
    {&submit_long_leg/1, &cancel_long_leg/1},
    {&wait_for_long_fill/1, &close_long_position/1}
  ],
  timeout: :timer.seconds(30),
  on_complete: fn result ->
    %PairsTradeExecuted{legs: result}
  end,
  on_compensate: fn {failed_step, reason, compensated} ->
    %PairsTradeRolledBack{
      failed_at: failed_step,
      reason: reason,
      compensated_steps: compensated
    }
  end
)
```

## Complete Trading Workflow Example

```elixir
defmodule QuantFund.TradingWorkflow do
  @moduledoc """
  Complete multi-agent trading workflow for a quantitative fund.
  """
  
  require Runic
  import Runic
  
  def build do
    workflow(name: :quant_fund_trading)
    |> build_data_layer()
    |> build_analysis_layer()
    |> build_research_layer()
    |> build_trading_layer()
    |> build_risk_layer()
    |> build_execution_layer()
  end
  
  # ═══════════════════════════════════════════════════════════════════
  # DATA INGESTION LAYER
  # ═══════════════════════════════════════════════════════════════════
  
  defp build_data_layer(wrk) do
    wrk
    # Real-time market data normalization
    |> add(step(name: :market_data_normalizer, work: &normalize_market_data/1))
    
    # Time-windowed aggregations
    |> add(Window.new(
      name: :vwap_1min,
      window_type: :tumbling,
      duration: :timer.minutes(1),
      aggregator: &calculate_vwap/1
    ), to: :market_data_normalizer)
    
    |> add(Window.new(
      name: :volume_profile,
      window_type: :sliding,
      duration: :timer.minutes(15),
      slide: :timer.minutes(1),
      aggregator: &calculate_volume_profile/1
    ), to: :market_data_normalizer)
    
    # News and sentiment streams
    |> add(step(name: :news_ingestion, work: &fetch_news/1))
    |> add(step(name: :social_ingestion, work: &fetch_social_sentiment/1))
  end
  
  # ═══════════════════════════════════════════════════════════════════
  # ANALYSIS LAYER (Parallel LLM Agents)
  # ═══════════════════════════════════════════════════════════════════
  
  defp build_analysis_layer(wrk) do
    # Prepare unified context for all analysts
    context_join = Join.new(
      name: :analyst_context,
      inputs: [:vwap_1min, :volume_profile, :news_ingestion, :social_ingestion]
    )
    
    wrk
    |> add(context_join, to: [:vwap_1min, :volume_profile, :news_ingestion, :social_ingestion])
    
    # Fan-out to parallel analyst agents
    |> add(analyst_agent(:fundamental, 
      system_prompt: FundamentalPrompts.system(),
      tools: [:financial_data, :sec_filings, :earnings_calendar]
    ), to: :analyst_context)
    
    |> add(analyst_agent(:technical,
      system_prompt: TechnicalPrompts.system(),
      tools: [:calculate_indicators, :pattern_recognition, :support_resistance]
    ), to: :analyst_context)
    
    |> add(analyst_agent(:sentiment,
      system_prompt: SentimentPrompts.system(),
      tools: [:news_sentiment, :social_sentiment, :options_flow]
    ), to: :analyst_context)
    
    |> add(analyst_agent(:macro,
      system_prompt: MacroPrompts.system(),
      tools: [:economic_calendar, :fed_watch, :sector_rotation]
    ), to: :analyst_context)
  end
  
  # ═══════════════════════════════════════════════════════════════════
  # RESEARCH LAYER (Adversarial Debate)
  # ═══════════════════════════════════════════════════════════════════
  
  defp build_research_layer(wrk) do
    # Join all analyst reports
    analyst_join = Join.new(
      name: :analyst_consensus,
      inputs: [:fundamental, :technical, :sentiment, :macro]
    )
    
    wrk
    |> add(analyst_join, to: [:fundamental, :technical, :sentiment, :macro])
    
    # Bull/Bear debate accumulator
    |> add(state_machine(
      name: :debate_state,
      init: %DebateState{round: 0, max_rounds: 3, history: []},
      reducer: &debate_reducer/2,
      reactors: [&emit_debate_conclusion/1]
    ), to: :analyst_consensus)
    
    # Bull researcher (optimistic perspective)
    |> add(agent_step(:bull_researcher,
      role: :researcher,
      perspective: :bullish,
      system_prompt: BullPrompts.system()
    ), to: :debate_state)
    
    # Bear researcher (pessimistic perspective)
    |> add(agent_step(:bear_researcher,
      role: :researcher,
      perspective: :bearish,
      system_prompt: BearPrompts.system()
    ), to: :bull_researcher)
    
    # Debate moderator
    |> add(agent_step(:debate_moderator,
      role: :moderator,
      system_prompt: ModeratorPrompts.system()
    ), to: :bear_researcher)
  end
  
  # ═══════════════════════════════════════════════════════════════════
  # TRADING LAYER (Multiple Trader Profiles)
  # ═══════════════════════════════════════════════════════════════════
  
  defp build_trading_layer(wrk) do
    wrk
    # Multiple trader agents with different risk profiles
    |> add(trader_agent(:aggressive_trader,
      risk_tolerance: :high,
      position_sizing: :kelly_full,
      system_prompt: AggressiveTraderPrompts.system()
    ), to: :debate_moderator)
    
    |> add(trader_agent(:moderate_trader,
      risk_tolerance: :medium,
      position_sizing: :kelly_half,
      system_prompt: ModerateTraderPrompts.system()
    ), to: :debate_moderator)
    
    |> add(trader_agent(:conservative_trader,
      risk_tolerance: :low,
      position_sizing: :fixed_fractional,
      system_prompt: ConservativeTraderPrompts.system()
    ), to: :debate_moderator)
    
    # Quorum voting on trade decisions
    |> add(Quorum.new(
      name: :trader_quorum,
      voters: [:aggressive_trader, :moderate_trader, :conservative_trader],
      voting_rule: :weighted,
      weights: %{
        aggressive_trader: 0.2,
        moderate_trader: 0.5,
        conservative_trader: 0.3
      }
    ), to: [:aggressive_trader, :moderate_trader, :conservative_trader])
  end
  
  # ═══════════════════════════════════════════════════════════════════
  # RISK MANAGEMENT LAYER
  # ═══════════════════════════════════════════════════════════════════
  
  defp build_risk_layer(wrk) do
    wrk
    # Portfolio state tracking
    |> add(state_machine(
      name: :portfolio_state,
      init: initial_portfolio(),
      reducer: &portfolio_reducer/2,
      reactors: [
        &check_drawdown_limit/1,
        &check_position_concentration/1,
        &check_daily_loss_limit/1
      ]
    ))
    
    # Circuit breaker for max drawdown
    |> add(Circuit.new(
      name: :drawdown_breaker,
      monitor: :portfolio_state,
      trip_condition: fn p -> p.current_drawdown > 0.10 end,
      reset_condition: fn p -> p.current_drawdown < 0.05 end,
      cooldown: :timer.hours(1)
    ), to: :portfolio_state)
    
    # Risk assessment rule using meta-conditions
    |> add(rule(
      name: :risk_gate,
      condition: fn %TradeRecommendation{} = rec ->
        # Only if circuit breaker is closed
        not Circuit.is_open?(:drawdown_breaker)
      end,
      reaction: fn rec ->
        portfolio = state_of(:portfolio_state)
        assess_trade_risk(rec, portfolio)
      end
    ), to: :trader_quorum)
    
    # Multi-perspective risk debate
    |> add(risk_debate_workflow(), to: :risk_gate)
  end
  
  # ═══════════════════════════════════════════════════════════════════
  # EXECUTION LAYER
  # ═══════════════════════════════════════════════════════════════════
  
  defp build_execution_layer(wrk) do
    wrk
    # Fund manager final approval
    |> add(agent_step(:fund_manager,
      role: :fund_manager,
      system_prompt: FundManagerPrompts.system()
    ), to: :risk_debate)
    
    # Order throttling
    |> add(Throttle.new(
      name: :order_throttle,
      rate: {5, :per_second},
      overflow_policy: :queue
    ), to: :fund_manager)
    
    # Order execution with saga for complex orders
    |> add(rule(
      name: :simple_order_execution,
      condition: fn %ApprovedTrade{order_type: type} -> type in [:market, :limit] end,
      reaction: &execute_simple_order/1
    ), to: :order_throttle)
    
    |> add(Saga.new(
      name: :pairs_trade_saga,
      steps: pairs_trade_steps(),
      timeout: :timer.seconds(30)
    ), to: :order_throttle)
    
    # Fill tracking and portfolio update
    |> add(step(name: :fill_processor, work: &process_fill/1), to: :simple_order_execution)
    |> add(step(name: :fill_processor, work: &process_fill/1), to: :pairs_trade_saga)
  end
  
  # ═══════════════════════════════════════════════════════════════════
  # HELPER FUNCTIONS
  # ═══════════════════════════════════════════════════════════════════
  
  defp analyst_agent(name, opts) do
    step(
      name: name,
      work: fn context ->
        AgentStep.run_react_agent(
          context,
          system_prompt: opts[:system_prompt],
          tools: opts[:tools] || [],
          model: opts[:model] || "gpt-4"
        )
      end
    )
  end
  
  defp trader_agent(name, opts) do
    step(
      name: name,
      work: fn %DebateConclusion{} = conclusion ->
        portfolio = state_of(:portfolio_state)
        
        TraderAgent.decide(
          conclusion,
          portfolio,
          risk_tolerance: opts[:risk_tolerance],
          position_sizing: opts[:position_sizing],
          system_prompt: opts[:system_prompt]
        )
      end
    )
  end
end
```

## Trading-Specific Meta-Conditions

### Extended Meta-Conditions for Trading

```elixir
# Position-aware conditions
rule do
  given signal: %TradeSignal{symbol: symbol}
  
  when position_of(symbol) == nil  # No existing position
   and state_of(:portfolio).cash > required_margin(signal)
   and not step_ran?(:order_submitted, {symbol, today()})
  
  then fn %{signal: signal} ->
    generate_entry_order(signal)
  end
end

# Time-based conditions
rule do
  given tick: %MarketTick{}
  
  when market_session() == :regular_hours
   and time_until_close() > minutes(15)
   and not within_blackout_window?()
  
  then fn %{tick: tick} ->
    process_for_trading(tick)
  end
end

# Cross-asset conditions
rule do
  given signal: %TradeSignal{symbol: "SPY"}
  
  when correlation_with("VIX", window: hours(1)) < -0.8
   and state_of(:vix_level) < 20
   and sector_momentum("Technology") > 0.5
  
  then fn %{signal: signal} ->
    %EnhancedSignal{signal | confidence_boost: 0.1}
  end
end
```

### Proposed Trading Meta-Condition Primitives

```elixir
# Position introspection
position_of(symbol)              # Current position in symbol
position_pnl(symbol)             # Unrealized P&L
position_age(symbol)             # How long position held
position_size_pct(symbol)        # Position as % of portfolio

# Market state
market_session()                 # :pre_market | :regular_hours | :after_hours
time_until_close()               # Duration until market close
trading_day()                    # Current trading day
is_trading_day?(date)            # Is this a trading day?

# Risk metrics
current_drawdown()               # Portfolio drawdown from peak
daily_pnl()                      # Today's P&L
var_utilization()                # Current VaR usage
margin_utilization()             # Margin usage %

# Order state
pending_orders_for(symbol)       # List of pending orders
order_state(order_id)            # Order status
fills_today(symbol)              # Today's fills for symbol

# Cross-asset
correlation_with(symbol, opts)   # Rolling correlation
beta_to(benchmark)               # Beta to benchmark
sector_exposure(sector)          # Exposure to sector
```

## Agent Communication Patterns

### Structured Reports (Not Just Messages)

Following the TradingAgents paper, agents communicate via structured documents:

```elixir
defmodule AnalystReport do
  @type t :: %__MODULE__{
    agent: atom(),
    symbol: String.t(),
    timestamp: DateTime.t(),
    signal: :bullish | :bearish | :neutral,
    confidence: float(),
    time_horizon: :intraday | :swing | :position,
    key_factors: [String.t()],
    risks: [String.t()],
    price_targets: %{
      bull_case: float(),
      base_case: float(),
      bear_case: float()
    },
    supporting_data: map(),
    reasoning_chain: [String.t()]  # Chain-of-thought for explainability
  }
end

defmodule TradeRecommendation do
  @type t :: %__MODULE__{
    action: :buy | :sell | :hold,
    symbol: String.t(),
    order_type: :market | :limit | :stop,
    size: integer(),
    limit_price: float() | nil,
    stop_loss: float(),
    take_profit: float(),
    time_in_force: :day | :gtc | :ioc,
    rationale: String.t(),
    source_reports: [reference()],
    risk_reward_ratio: float(),
    expected_slippage: float()
  }
end
```

### Debate Protocol

```elixir
defmodule DebateRound do
  defstruct [
    :round_number,
    :speaker,           # :bull | :bear
    :argument,          # The actual argument text
    :evidence,          # Supporting data points
    :counters_to,       # Which previous points this addresses
    :concessions,       # What the speaker concedes
    :confidence,        # Speaker's confidence in their position
    :key_points         # Extracted key points
  ]
end

defmodule DebateConclusion do
  defstruct [
    :winning_perspective,  # :bull | :bear | :mixed
    :consensus_signal,     # Aggregated signal
    :key_agreements,       # Points both sides agreed on
    :key_disagreements,    # Unresolved points
    :confidence,           # Overall confidence
    :recommended_position_size_adjustment  # Based on uncertainty
  ]
end
```

## Explainability and Audit Trail

### Fact Lineage for Regulatory Compliance

```elixir
defmodule Runic.Workflow.Fact do
  defstruct [
    :value,
    :hash,
    :timestamp,
    :generation,
    :parent_facts,      # Lineage tracking
    :producing_step,    # Which step created this
    :metadata           # Additional context
  ]
end

# Every trade decision carries full lineage
%TradeExecution{
  order_id: "ORD-123",
  lineage: %{
    market_data: ["tick-456", "tick-457", ...],
    analyst_reports: ["fundamental-789", "technical-012", ...],
    debate_rounds: ["round-1", "round-2", "round-3"],
    trader_votes: ["aggressive-vote", "moderate-vote", "conservative-vote"],
    risk_assessments: ["risk-assessment-345"],
    fund_manager_approval: "approval-678"
  },
  reasoning_chain: [
    "Technical analyst identified bullish divergence on RSI",
    "Fundamental analyst confirmed strong earnings guidance",
    "Bull researcher argued sector tailwinds outweigh macro concerns",
    "Bear researcher conceded short-term momentum but flagged valuation",
    "Moderator concluded bullish with reduced position size",
    "Risk team approved with stop-loss at -3%",
    "Fund manager approved execution"
  ]
}
```

## Performance Considerations

### Latency-Sensitive Components

```elixir
# Fast-path for time-critical decisions
defmodule FastPath do
  @doc """
  Bypass full workflow for latency-critical signals.
  Uses pre-compiled rules with minimal overhead.
  """
  def fast_rule(condition, action) do
    # Compile to optimized pattern match
    rule(
      priority: :critical,
      bypass_debate: true,
      max_latency_ms: 10,
      condition: condition,
      reaction: action
    )
  end
end

# Stop-loss triggers bypass normal workflow
fast_rule(
  fn %MarketTick{symbol: s, price: p} ->
    position = position_of(s)
    position && p < position.stop_loss
  end,
  fn tick ->
    %EmergencyExit{symbol: tick.symbol, reason: :stop_loss_triggered}
  end
)
```

### Async LLM Calls

```elixir
# LLM calls should not block critical path
defmodule AsyncAgent do
  def agent_step_async(name, opts) do
    step(
      name: name,
      async: true,
      timeout: opts[:timeout] || 30_000,
      work: fn context ->
        Task.async(fn ->
          AgentStep.run_react_agent(context, opts)
        end)
      end
    )
  end
end
```

## Future Extensions

### 1. Reinforcement Learning Integration

```elixir
# Agent that learns from trading outcomes
rl_trader = step(
  name: :rl_trader,
  work: fn context ->
    state = encode_market_state(context)
    action = RLModel.predict(state)
    
    # Store for training
    ExperienceBuffer.store(state, action)
    
    action
  end,
  after_hook: fn step, workflow, output_fact ->
    # Record outcome for RL training
    if match?(%OrderFill{}, output_fact.value) do
      reward = calculate_reward(output_fact.value)
      ExperienceBuffer.update_reward(step.name, reward)
    end
    workflow
  end
)
```

### 2. Backtesting Mode

```elixir
# Workflow that can run in simulation mode
defmodule BacktestWorkflow do
  def wrap_for_backtest(workflow, historical_data) do
    workflow
    |> replace_data_sources(historical_data)
    |> disable_real_execution()
    |> enable_simulation_fills()
    |> add_performance_tracking()
  end
end
```

### 3. Strategy Versioning

```elixir
# Track and compare strategy versions
defmodule StrategyVersion do
  defstruct [
    :version,
    :workflow_hash,
    :parameters,
    :performance_metrics,
    :deployed_at,
    :deprecated_at
  ]
end
```

## Conclusion

Runic's dataflow-based workflow model maps naturally to multi-agent trading systems:

| Trading Concept | Runic Primitive |
|-----------------|-----------------|
| Market events | Facts |
| Analyst agents | Steps with LLM backends |
| Trading rules | Rules with meta-conditions |
| Portfolio state | Accumulators/State machines |
| Parallel analysis | Fan-out/Fan-in |
| Agent consensus | Join + Quorum (proposed) |
| Risk limits | Circuit breakers (proposed) |
| Order rate limits | Throttle (proposed) |
| Complex trades | Saga (proposed) |

The proposed extensions—Quorum, Circuit, Throttle, Window, Arbiter, and Saga—address trading-specific needs while maintaining Runic's compositional philosophy. Combined with the explicit rule DSL and meta-conditions from `rule-dsl-plan.md`, this creates a powerful foundation for building sophisticated, explainable, multi-agent trading systems.
