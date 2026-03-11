defmodule Runic.RuleContextTest do
  use ExUnit.Case

  require Runic
  alias Runic.Workflow

  describe "rule(fn ... end) with context/1" do
    test "guarded fn rule with context/1 in body" do
      rule =
        Runic.rule(fn input when is_binary(input) ->
          model = context(:model)
          "processed #{input} with #{model}"
        end)

      wf = Runic.transmute(rule)
      wf = Workflow.put_run_context(wf, %{_global: %{model: "gpt-4"}})

      result =
        wf
        |> Workflow.plan_eagerly("hello")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      assert result == "processed hello with gpt-4"
    end

    test "context value can be changed without rebuilding the rule" do
      rule =
        Runic.rule(fn input when is_binary(input) ->
          model = context(:model)
          "using #{model}"
        end)

      wf = Runic.transmute(rule)

      result_a =
        wf
        |> Workflow.put_run_context(%{_global: %{model: "gpt-4"}})
        |> Workflow.plan_eagerly("x")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      result_b =
        wf
        |> Workflow.put_run_context(%{_global: %{model: "claude-3"}})
        |> Workflow.plan_eagerly("x")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      assert result_a == "using gpt-4"
      assert result_b == "using claude-3"
    end
  end

  describe "context/1 in guard position of fn-form rules" do
    test "context/1 in guard position of fn rule raises compile error" do
      assert_raise CompileError, ~r/context\/1.*cannot be used in guard/, fn ->
        Code.compile_quoted(
          quote do
            require Runic

            Runic.rule(fn input when input > context(:threshold) ->
              input
            end)
          end
        )
      end
    end

    test "context/1 in guard position of fn rule with opts raises compile error" do
      assert_raise CompileError, ~r/context\/1.*cannot be used in guard/, fn ->
        Code.compile_quoted(
          quote do
            require Runic

            Runic.rule(
              fn input when input > context(:threshold) ->
                input
              end,
              name: "bad_rule"
            )
          end
        )
      end
    end
  end

  describe "rule(fn ... end, opts) with context/1" do
    test "named fn rule with context/1 in body" do
      rule =
        Runic.rule(
          fn input when is_binary(input) ->
            model = context(:model)
            "processed #{input} with #{model}"
          end,
          name: "test_rule"
        )

      wf = Runic.transmute(rule)
      wf = Workflow.put_run_context(wf, %{_global: %{model: "claude-3"}})

      # required_context_keys reports the reaction step's meta refs
      keys = Workflow.required_context_keys(wf)
      flat_keys = Map.values(keys) |> List.flatten() |> Keyword.keys()
      assert :model in flat_keys

      result =
        wf
        |> Workflow.plan_eagerly("hello")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      assert result == "processed hello with claude-3"
    end
  end

  describe "rule(condition: ..., reaction: ...) with context/1" do
    test "condition/reaction rule with context/1 in reaction" do
      rule =
        Runic.rule(
          condition: fn input when is_binary(input) -> true end,
          reaction: fn input ->
            model = context(:model)
            "mock response for #{input} using #{model}"
          end,
          name: "test_cr_rule"
        )

      wf = Runic.transmute(rule)
      wf = Workflow.put_run_context(wf, %{_global: %{model: "gpt-4"}})

      result =
        wf
        |> Workflow.plan_eagerly("hello")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      assert result == "mock response for hello using gpt-4"
    end

    test "condition/reaction rule with context/1 in condition" do
      rule =
        Runic.rule(
          condition: fn input when is_binary(input) ->
            threshold = context(:min_length)
            String.length(input) >= threshold
          end,
          reaction: fn input ->
            "ok: #{input}"
          end,
          name: "test_cond_ctx"
        )

      wf = Runic.transmute(rule)
      wf = Workflow.put_run_context(wf, %{_global: %{min_length: 3}})

      # The condition's meta_refs are on the Condition vertex
      condition_vertex =
        wf.graph.vertices
        |> Map.values()
        |> Enum.find(&is_struct(&1, Runic.Workflow.Condition))

      assert length(condition_vertex.meta_refs) == 1
      assert hd(condition_vertex.meta_refs).context_key == :min_length

      # "hi" too short (length 2 < 3)
      result_short =
        wf
        |> Workflow.plan_eagerly("hi")
        |> Workflow.react()
        |> Workflow.raw_productions()

      assert result_short == []

      # "hello" long enough (length 5 >= 3)
      result_long =
        wf
        |> Workflow.plan_eagerly("hello")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      assert result_long == "ok: hello"
    end

    test "condition/reaction rule with context/1 in both" do
      rule =
        Runic.rule(
          condition: fn input when is_binary(input) ->
            threshold = context(:min_length)
            String.length(input) >= threshold
          end,
          reaction: fn input ->
            model = context(:model)
            "#{model}: #{input}"
          end,
          name: "test_both"
        )

      wf = Runic.transmute(rule)
      wf = Workflow.put_run_context(wf, %{_global: %{model: "gpt-4", min_length: 3}})

      # "hi" too short
      result_short =
        wf
        |> Workflow.plan_eagerly("hi")
        |> Workflow.react()
        |> Workflow.raw_productions()

      assert result_short == []

      # "hello" long enough
      result_long =
        wf
        |> Workflow.plan_eagerly("hello")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      assert result_long == "gpt-4: hello"
    end

    test "context with default value in rule" do
      rule =
        Runic.rule(
          condition: fn input when is_binary(input) -> true end,
          reaction: fn input ->
            model = context(:model, default: "default-model")
            "#{model}: #{input}"
          end,
          name: "test_default"
        )

      wf = Runic.transmute(rule)

      # Without setting context — should use default
      result =
        wf
        |> Workflow.plan_eagerly("hello")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      assert result == "default-model: hello"

      # With explicit context — should override default
      result_override =
        wf
        |> Workflow.put_run_context(%{_global: %{model: "gpt-4"}})
        |> Workflow.plan_eagerly("hello")
        |> Workflow.react()
        |> Workflow.raw_productions()
        |> List.first()

      assert result_override == "gpt-4: hello"
    end
  end
end
