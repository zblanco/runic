defmodule Runic.Workflow.InvocationTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow

  alias Runic.Workflow.{
    CallContract,
    CausalContext,
    Fact,
    Invocation,
    Invokable,
    Runnable,
    Step
  }

  describe "call contract compilation" do
    test "compiles ordinary authored arities without a user invocation option" do
      zero = Step.new(work: fn -> :ready end)
      single = Step.new(work: fn input -> input end)

      positional =
        Step.new(
          work: fn left, right -> left + right end,
          inputs: [left: [type: :integer], right: [type: :integer]]
        )

      assert %CallContract{style: :zero_arity, authored_arity: 0, input_order: []} =
               zero.call_contract

      assert %CallContract{style: :single_input, authored_arity: 1, input_order: [:in]} =
               single.call_contract

      assert %CallContract{
               style: :positional,
               authored_arity: 2,
               input_order: [:left, :right]
             } = positional.call_contract

      refute Map.has_key?(positional, :invocation)
    end

    test "compiles context/1 as input and context from macro metadata" do
      step = Runic.step(fn input -> input + context(:offset) end, name: :adjust)

      assert %CallContract{
               version: 1,
               style: :input_and_context,
               authored_arity: 1,
               compiled_arity: 2,
               input_order: [:in],
               binding_refs: [%{kind: :context, target: :offset}]
             } = step.call_contract
    end

    test "infers a deterministic current contract for a pre-contract step struct" do
      step =
        Step.new(
          work: fn left, right -> left + right end,
          inputs: [left: [type: :integer], right: [type: :integer]]
        )

      old_step = Map.delete(step, :call_contract)

      assert %CallContract{version: 1, style: :positional, input_order: [:left, :right]} =
               CallContract.for_step(old_step)

      invocation =
        old_step
        |> CallContract.for_step()
        |> Invocation.prepare([2, 3], CausalContext.new(run_context: %{ignored: true}))

      assert Invocation.call(invocation, old_step.work) == 5

      workflow = Workflow.new() |> Workflow.add(old_step)
      fact = Fact.new(value: [2, 3])

      assert {:ok, %Runnable{invocation: %Invocation{}} = runnable} =
               Invokable.prepare(old_step, workflow, fact)

      assert %Runnable{status: :completed, result: %Fact{value: 5}} =
               Invokable.execute(old_step, runnable)
    end
  end

  describe "prepared invocation envelope" do
    test "keeps the domain fact intact while exposing ordered and named bindings" do
      step =
        Step.new(
          work: fn left, right -> left + right end,
          name: :sum,
          inputs: [left: [type: :integer], right: [type: :integer]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{sum: %{request_id: "request-1"}})

      fact = Fact.new(value: [4, 7])

      assert {:ok, %Runnable{invocation: %Invocation{} = invocation}} =
               Invokable.prepare(step, workflow, fact)

      assert invocation.value == [4, 7]
      assert invocation.arguments == [4, 7]
      assert invocation.bindings.inputs == %{left: 4, right: 7}
      assert invocation.context.runtime == %{request_id: "request-1"}
      assert invocation.context.effective == %{request_id: "request-1"}
      assert invocation.contract.style == :positional
      assert invocation |> :erlang.term_to_binary() |> :erlang.binary_to_term() == invocation
    end

    test "context expressions receive merged context without changing the fact value" do
      step = Runic.step(fn input -> {input, context(:model)} end, name: :call_model)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{
          _global: %{request_id: "request-1"},
          call_model: %{model: "model-1"}
        })

      fact = Fact.new(value: %{prompt: "hello"})
      {:ok, runnable} = Invokable.prepare(step, workflow, fact)

      assert runnable.invocation.value == %{prompt: "hello"}
      assert runnable.invocation.arguments == [%{prompt: "hello"}]

      assert runnable.invocation.context.effective == %{
               model: "model-1",
               request_id: "request-1"
             }

      assert %Runnable{status: :completed, result: %Fact{value: result}} =
               Invokable.execute(step, runnable)

      assert result == {%{prompt: "hello"}, "model-1"}
    end
  end
end
