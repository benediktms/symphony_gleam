---
tracker:
  kind: file
  provider:
    path: issues.json
  required_labels: [symphony]
  active_states: [Todo, In Progress]
  terminal_states: [Done, Cancelled]

polling:
  interval_ms: 30000

workspace:
  root: .symphony/workspaces

hooks:
  after_create: |
    git clone --local --branch main /Users/benedikt.schnatterbeck/code/beholder .
  timeout_ms: 60000

agent:
  max_concurrent_agents: 1
  max_turns: 8
  max_retry_backoff_ms: 300000

codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: false
---
Work on {{issue.identifier}}: {{issue.title}}.

{{issue.description}}

This is a local Symphony trial against the Beholder repository. Read the repository instructions
and current architecture before making decisions. Preserve existing contracts and avoid speculative
abstractions. Keep work strictly inside this ticket's scope. Leave the workspace in a reviewable
state and run the smallest relevant checks. The file tracker is read-only to the agent, so do not
attempt to change ticket state; the operator will review the result and update `issues.json`.
