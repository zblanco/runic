defmodule Runic.Runner.Scheduler.Default.ContractComplianceTest do
  use Runic.Runner.Scheduler.ContractTest,
    scheduler: Runic.Runner.Scheduler.Default
end

defmodule Runic.Runner.Scheduler.ChainBatching.ContractComplianceTest do
  use Runic.Runner.Scheduler.ContractTest,
    scheduler: Runic.Runner.Scheduler.ChainBatching,
    opts: [min_chain_length: 2]
end

defmodule Runic.Runner.Scheduler.FlowBatch.ContractComplianceTest do
  use Runic.Runner.Scheduler.ContractTest,
    scheduler: Runic.Runner.Scheduler.FlowBatch,
    opts: [min_chain_length: 2, min_batch_size: 2]
end

defmodule Runic.Runner.Scheduler.Adaptive.ContractComplianceTest do
  use Runic.Runner.Scheduler.ContractTest,
    scheduler: Runic.Runner.Scheduler.Adaptive
end
