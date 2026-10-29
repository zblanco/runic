# Owner execution memory benchmarks

These benchmarks measure memory copied from a workflow owner into execution
tasks. Run each command in a fresh BEAM instance so one scenario does not retain
memory for the next scenario.

The legacy engine works on Runic `main` and records the problem. The owner
engine requires the owner-local dispatch implementation. A benchmark stops with
a clear error when `--engine owner` is not available.

## Policy execution

This probe executes one Runnable several times. Its causal context retains a
large list that the Action does not use.

```sh
mix run bench/owner_execution/policy.exs --engine legacy
mix run bench/owner_execution/policy.exs --engine owner
```

Defaults: 1,000,000 retained integers and 6 attempts. Use `--retained` and
`--attempts` to change them.

## Managed execution

This probe runs the same small Step several times under `Runic.Runner`. A hook
captures a large retained list.

```sh
mix run bench/owner_execution/managed.exs --engine legacy
mix run bench/owner_execution/managed.exs --engine owner
```

Defaults: 1,000,000 retained integers and 6 executions. Use `--retained` and
`--attempts` to change them.

## Wide preparation

This probe creates a wide ready frontier, starts only the configured number of
workers, and measures memory before releasing them.

```sh
mix run bench/owner_execution/preparation.exs --engine legacy
mix run bench/owner_execution/preparation.exs --engine owner
mix run bench/owner_execution/preparation.exs --engine owner --transform
```

Defaults: 3,000 ready Steps and concurrency 8. Use `--width` and
`--concurrency` to change them. `--transform` installs an identity
`transform_runnables` hook, which requires the complete frontier.

## Output

Each probe prints elapsed time and baseline, peak, peak increase, and final
values for total, process, binary, and ETS memory. The sampler reads
`:erlang.memory/0` every 5 milliseconds. Category peaks can occur in different
samples. These values are BEAM VM memory, not operating-system RSS.
