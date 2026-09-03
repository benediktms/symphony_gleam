import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import gleam/string

pub type BlockerRef {
  BlockerRef(
    id: Option(String),
    identifier: Option(String),
    state: Option(String),
  )
}

pub type Issue {
  Issue(
    id: String,
    native_ref: Option(Dynamic),
    identifier: String,
    title: String,
    description: Option(String),
    priority: Option(Int),
    state: String,
    branch_name: Option(String),
    url: Option(String),
    assignee_id: Option(String),
    labels: List(String),
    blocked_by: List(BlockerRef),
    dispatchable: Bool,
    created_at: Option(Int),
    updated_at: Option(Int),
  )
}

pub type Workflow {
  Workflow(
    config: Dynamic,
    prompt_template: String,
    path: String,
    directory: String,
  )
}

pub type TrackerConfig {
  TrackerConfig(
    kind: String,
    provider: Dynamic,
    required_labels: List(String),
    active_states: List(String),
    terminal_states: List(String),
  )
}

pub type HooksConfig {
  HooksConfig(
    after_create: Option(String),
    before_run: Option(String),
    after_run: Option(String),
    before_remove: Option(String),
    timeout_ms: Int,
  )
}

pub type AgentConfig {
  AgentConfig(
    max_concurrent_agents: Int,
    max_turns: Int,
    max_retry_backoff_ms: Int,
    max_concurrent_agents_by_state: List(#(String, Int)),
  )
}

pub type CodexConfig {
  CodexConfig(
    command: String,
    approval_policy: Dynamic,
    thread_sandbox: String,
    turn_sandbox_policy: Dynamic,
    turn_timeout_ms: Int,
    read_timeout_ms: Int,
    stall_timeout_ms: Int,
  )
}

pub type Config {
  Config(
    tracker: TrackerConfig,
    polling_interval_ms: Int,
    workspace_root: String,
    hooks: HooksConfig,
    agent: AgentConfig,
    codex: CodexConfig,
  )
}

pub type ServiceError {
  MissingWorkflowFile(String)
  WorkflowParseError(String)
  WorkflowFrontMatterNotAMap
  InvalidConfig(String)
  UnsupportedTrackerKind(String)
  TrackerError(category: String, message: String)
  WorkspaceError(String)
  TemplateParseError(String)
  TemplateRenderError(String)
  CodexError(category: String, message: String)
}

pub fn normalize(value: String) -> String {
  value |> string.trim |> string.lowercase
}
