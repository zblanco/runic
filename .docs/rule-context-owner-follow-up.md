# Rule context owner follow-up

Runic has a known core context-name limitation. Validation lists an anonymous
Rule condition's keys under the Rule name. Runtime uses the condition's nil
name. Reaction Steps use generated names. Use `:_global` for Rule resources
until the owner-name contract is aligned. Global resources are available to
all components.

A separate core change must use one context owner-name resolver for declared
key validation, runtime reference resolution, and condition preparation. Define
how reaction Steps use the public Rule scope. Preserve global fallback and
component precedence.

The relevant code is in `lib/workflow.ex`, `lib/workflow/private.ex`, and
`lib/workflow/invokable.ex`. The Rule tests in `test/fact_boundaries_test.exs`
characterize this known limitation. Update them with the core fix. Use numeric
condition inputs so term order does not hide a missing resource. Also test
reaction resources, scoped/global overrides, defaults, and replay/resume.

See [Fact boundaries](../guides/fact-boundaries.md) for the current consumer
contract. This note records a follow-up; it does not change runtime behavior.
