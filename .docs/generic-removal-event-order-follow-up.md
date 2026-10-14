# Follow-up: generic component removal event order

The focused issue #35 review found a pre-existing generic removal replay defect.
It is separate from Batch removal and is not fixed by issue #35.

`Workflow.do_remove_component/3` stores its event with
`workflow.build_log ++ [event]`. `Workflow.build_log/1` reverses this stored list.
The generic ComponentRemoved event therefore replays before its ComponentAdded
and has no effect. The removed component appears again after build replay.
Batch removal stores its event newest first and replays in the correct order.

Reproduce with an authored `add -> double -> finish` Step workflow:

```elixir
removed = Workflow.remove_component(workflow, :double)
log = Workflow.build_log(removed)
# log begins with ComponentRemoved(:double), before ComponentAdded(:double)
rebuilt = Workflow.from_log(log)
Workflow.get_component(rebuilt, :double)
# The removed component is present.
```

A separate fix should store `[event | workflow.build_log]` for generic removal
and test both build-log and event reconstruction, including a mixed log with
Batch removal. Keep that fix independent of the issue #35 rewire helper, which
preserves existing flow and public component connection behavior.
