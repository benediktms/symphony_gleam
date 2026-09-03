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
    git clone https://github.com/your-org/your-repo.git .
  timeout_ms: 60000

agent:
  max_concurrent_agents: 2
  max_turns: 20
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

Required labels:
{{#each issue.labels}}- {{.}}
{{/each}}

Use the tracker tooling available to you to move the issue to the workflow's handoff state when the work is ready.

