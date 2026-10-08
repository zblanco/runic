defmodule Runic.IdentityTest do
  use ExUnit.Case, async: true

  alias Runic.Identity
  alias Runic.Identity.{Canonical, CanonicalError, IntegrityError, Preimage}
  alias Runic.Workflow.{CausalContext, Fact, FanOut, Invokable, Runnable}

  describe "canonical encoding v1" do
    test "has frozen primitive and collection vectors" do
      assert hex(Canonical.encode!(nil)) == "00"
      assert hex(Canonical.encode!(42)) == "1000000000000000023432"
      assert hex(Canonical.encode!(1.5)) == "113ff8000000000000"
      assert hex(Canonical.encode!("hi")) == "2000000000000000026869"
      assert hex(Canonical.encode!(:hi)) == "2100000000000000026869"

      assert hex(Canonical.encode!([1, :a])) ==
               "300000000000000002000000000000000a10000000000000000131" <>
                 "000000000000000a21000000000000000161"

      assert hex(Canonical.encode!({1, :a})) ==
               "310000000000000002000000000000000a10000000000000000131" <>
                 "000000000000000a21000000000000000161"
    end

    test "sorts maps by canonical key bytes" do
      first = Map.new([{:b, 2}, {:a, 1}])
      second = Map.new([{:a, 1}, {:b, 2}])

      assert Canonical.encode!(first) == Canonical.encode!(second)
      assert Identity.digest(:payload, first) == Identity.digest(:payload, second)
    end

    test "keeps logical types distinct" do
      encodings = Enum.map([:value, "value", [:value], {:value}], &Canonical.encode!/1)

      assert Enum.uniq(encodings) == encodings
    end

    test "projects registered Range values without accepting arbitrary structs" do
      assert is_binary(Canonical.encode!(1..3))

      assert_raise CanonicalError, ~r/unsupported .*URI value/, fn ->
        Canonical.encode!(URI.parse("https://runic.dev"))
      end
    end

    test "rejects process-local and executable terms with a useful path" do
      assert_raise CanonicalError, ~r/at \$\[:work\].*unsupported function/, fn ->
        Canonical.encode!(%{work: fn -> :ok end})
      end

      assert_raise CanonicalError, ~r/unsupported pid/, fn ->
        Canonical.encode!(self())
      end
    end

    test "enforces configured limits" do
      assert_raise CanonicalError, ~r/depth limit exceeded/, fn ->
        Canonical.encode!([[[1]]], max_depth: 1)
      end

      assert_raise CanonicalError, ~r/byte_size limit exceeded/, fn ->
        Canonical.encode!("too large", max_bytes: 4)
      end

      assert_raise CanonicalError, ~r/item_count limit exceeded/, fn ->
        Canonical.encode!([1, 2, 3], max_items: 2)
      end
    end
  end

  describe "typed SHA-256 identities" do
    test "freezes the preimage frame and payload digest" do
      canonical =
        Canonical.encode!(%{codec: :runic_canonical, schema_version: 1, value: %{a: 1, b: 2}})

      identity = Identity.digest_bytes(:payload, canonical)

      assert binary_part(Preimage.frame_v1(:payload, canonical), 0, 20) ==
               <<"runic-id", 0, 1::unsigned-16, 7::unsigned-16, "payload">>

      assert Identity.to_string(identity) ==
               "runic:sha256:v1:payload:" <>
                 "21205882d75b9c3a549850de3b90d8347acfd5b648858d1256ad64883511b90c"

      assert hex(Identity.to_binary(identity)) ==
               "01000100077061796c6f6164" <>
                 "21205882d75b9c3a549850de3b90d8347acfd5b648858d1256ad64883511b90c"
    end

    test "domain-separates equal identity documents" do
      document = %{value: 42}

      refute Identity.digest(:payload, document) == Identity.digest(:fact_content, document)
    end

    test "projects component semantics without occurrence names or compiled functions" do
      first = Runic.Workflow.Step.new(name: :first, work: &Function.identity/1)
      second = Runic.Workflow.Step.new(name: :second, work: &Function.identity/1)

      assert Identity.project(:component_definition, first) ==
               Identity.project(:component_definition, second)
    end

    test "projects external function bindings as portable MFA data" do
      closure =
        Runic.Closure.new(
          quote(do: fn values -> mapper.(values) end),
          %{mapper: &Enum.sum/1},
          nil
        )

      assert %Identity{domain: :component_definition} =
               Identity.project(:component_definition, closure)
    end

    test "builds a workflow artifact identity from static topology" do
      step = Runic.Workflow.Step.new(name: :identity, work: &Function.identity/1)
      workflow = Runic.Workflow.new(:artifact) |> Runic.Workflow.add(step)
      with_context = Runic.Workflow.put_run_context(workflow, %{identity: %{secret: "runtime"}})

      assert %Identity{domain: :workflow_artifact} = artifact = Runic.Component.hash(workflow)
      assert Runic.Component.hash(with_context) == artifact
    end

    test "verifies content and returns a typed integrity error" do
      expected = Identity.digest(:payload, %{value: :expected})

      assert :ok = Identity.verify(expected, %{value: :expected})

      assert {:error, %IntegrityError{expected: ^expected}} =
               Identity.verify(expected, %{value: :different})
    end
  end

  describe "content and occurrence identities" do
    test "a Fact separates payload, causal content, and graph occurrence" do
      fact = Fact.new(value: %{answer: 42})

      assert %Identity{domain: :payload} = fact.payload_digest
      assert %Identity{domain: :fact_content} = fact.content_digest
      assert %Identity{domain: :fact_occurrence} = fact.id
      assert fact.hash == fact.id
    end

    test "equal fan-out payloads share payload identity but keep distinct occurrences" do
      fan_out = %FanOut{
        name: :fan_out,
        hash: Identity.digest(:component_definition, %{kind: :fan_out})
      }

      input = Fact.new(value: [:same, :same])
      context = CausalContext.new(node_hash: fan_out.hash, input_fact: input)

      executed =
        fan_out
        |> Runnable.new(input, context)
        |> then(&Invokable.execute(fan_out, &1))

      [first, second] = executed.result

      assert first.payload_digest == second.payload_digest
      refute first.content_digest == second.content_digest
      refute first.id == second.id
      assert first.causal_ancestry.output_index == 0
      assert second.causal_ancestry.output_index == 1
    end

    test "attempt identity changes while activation identity remains stable" do
      step = Runic.Workflow.Step.new(name: :identity, work: &Function.identity/1)
      fact = Fact.new(value: :input)
      runnable = Runnable.new(step, fact, CausalContext.new())

      retry = Runnable.for_attempt(runnable, 1)

      assert retry.activation_id == runnable.activation_id
      refute retry.attempt_id == runnable.attempt_id
      assert retry.attempt_number == 1
    end
  end

  defp hex(binary), do: Base.encode16(binary, case: :lower)
end
