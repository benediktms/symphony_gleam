import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import symphony/domain.{
  type AgentConfig, type CodexConfig, type Config, type HooksConfig,
  type TrackerConfig, type Workflow, AgentConfig, CodexConfig, Config,
  HooksConfig, InvalidConfig, TrackerConfig, Workflow,
}
import symphony/runtime

pub fn from_workflow(
  workflow: Workflow,
) -> Result(Config, domain.ServiceError) {
  let Workflow(config: raw, directory:, ..) = workflow
  use tracker_raw <- result.try(required_section(raw, "tracker"))
  let polling_raw = optional_section(raw, "polling")
  let workspace_raw = optional_section(raw, "workspace")
  let hooks_raw = optional_section(raw, "hooks")
  let agent_raw = optional_section(raw, "agent")
  let codex_raw = optional_section(raw, "codex")
  use tracker <- result.try(decode_config(
    tracker_raw,
    tracker_decoder(),
    "tracker",
  ))
  use polling <- result.try(decode_config(
    polling_raw,
    polling_decoder(),
    "polling",
  ))
  use workspace <- result.try(decode_config(
    workspace_raw,
    workspace_decoder(),
    "workspace",
  ))
  use hooks <- result.try(decode_config(hooks_raw, hooks_decoder(), "hooks"))
  use agent <- result.try(decode_config(agent_raw, agent_decoder(), "agent"))
  use codex <- result.try(decode_config(codex_raw, codex_decoder(), "codex"))
  use workspace_root <- result.try(resolve_path(workspace, directory))

  case validate(tracker, polling, hooks, agent, codex) {
    Ok(Nil) ->
      Ok(Config(
        tracker: tracker,
        polling_interval_ms: polling,
        workspace_root: workspace_root,
        hooks: hooks,
        agent: agent,
        codex: codex,
      ))
    Error(message) -> Error(InvalidConfig(message))
  }
}

fn required_section(
  raw: dynamic.Dynamic,
  name: String,
) -> Result(dynamic.Dynamic, domain.ServiceError) {
  let decoder = {
    use section <- decode.field(name, decode.dynamic)
    decode.success(section)
  }
  decode_config(raw, decoder, name)
}

fn optional_section(raw: dynamic.Dynamic, name: String) -> dynamic.Dynamic {
  let empty = dynamic.properties([])
  let decoder = {
    use section <- decode.optional_field(name, empty, decode.dynamic)
    decode.success(section)
  }
  decode.run(raw, decoder) |> result.unwrap(empty)
}

fn decode_config(
  raw: dynamic.Dynamic,
  decoder: decode.Decoder(a),
  name: String,
) -> Result(a, domain.ServiceError) {
  decode.run(raw, decoder)
  |> result.map_error(fn(errors) {
    InvalidConfig(name <> ": " <> string.inspect(errors))
  })
}

fn tracker_decoder() -> decode.Decoder(TrackerConfig) {
  use kind <- decode.field("kind", decode.string)
  use provider <- decode.optional_field(
    "provider",
    dynamic.properties([]),
    decode.dynamic,
  )
  use required_labels <- decode.optional_field(
    "required_labels",
    [],
    decode.list(decode.string),
  )
  use active_states <- decode.field("active_states", decode.list(decode.string))
  use terminal_states <- decode.field(
    "terminal_states",
    decode.list(decode.string),
  )
  decode.success(TrackerConfig(
    kind: kind,
    provider: provider,
    required_labels: list.map(required_labels, domain.normalize),
    active_states: active_states,
    terminal_states: terminal_states,
  ))
}

fn polling_decoder() -> decode.Decoder(Int) {
  use interval <- decode.optional_field("interval_ms", 30_000, decode.int)
  decode.success(interval)
}

fn workspace_decoder() -> decode.Decoder(String) {
  use root <- decode.optional_field(
    "root",
    runtime.join(runtime.temp_dir(), "symphony_workspaces"),
    decode.string,
  )
  decode.success(root)
}

fn hooks_decoder() -> decode.Decoder(HooksConfig) {
  use after_create <- decode.optional_field(
    "after_create",
    None,
    decode.optional(decode.string),
  )
  use before_run <- decode.optional_field(
    "before_run",
    None,
    decode.optional(decode.string),
  )
  use after_run <- decode.optional_field(
    "after_run",
    None,
    decode.optional(decode.string),
  )
  use before_remove <- decode.optional_field(
    "before_remove",
    None,
    decode.optional(decode.string),
  )
  use timeout_ms <- decode.optional_field("timeout_ms", 60_000, decode.int)
  decode.success(HooksConfig(
    after_create,
    before_run,
    after_run,
    before_remove,
    timeout_ms,
  ))
}

fn agent_decoder() -> decode.Decoder(AgentConfig) {
  use max_concurrent <- decode.optional_field(
    "max_concurrent_agents",
    10,
    decode.int,
  )
  use max_turns <- decode.optional_field("max_turns", 20, decode.int)
  use max_backoff <- decode.optional_field(
    "max_retry_backoff_ms",
    300_000,
    decode.int,
  )
  use per_state <- decode.optional_field(
    "max_concurrent_agents_by_state",
    dict.new(),
    decode.dict(decode.string, decode.dynamic),
  )
  let per_state =
    per_state
    |> dict.to_list
    |> list.filter_map(fn(entry) {
      case entry, decode.run(entry.1, decode.int) {
        #(state, _), Ok(limit) if limit > 0 ->
          Ok(#(domain.normalize(state), limit))
        _, _ -> Error(Nil)
      }
    })
  decode.success(AgentConfig(max_concurrent, max_turns, max_backoff, per_state))
}

fn codex_decoder() -> decode.Decoder(CodexConfig) {
  use command <- decode.optional_field(
    "command",
    "codex app-server",
    decode.string,
  )
  use approval <- decode.optional_field(
    "approval_policy",
    dynamic.string("never"),
    decode.dynamic,
  )
  use thread_sandbox <- decode.optional_field(
    "thread_sandbox",
    "workspace-write",
    decode.string,
  )
  use turn_sandbox <- decode.optional_field(
    "turn_sandbox_policy",
    dynamic.string("workspace-write"),
    decode.dynamic,
  )
  use turn_timeout <- decode.optional_field(
    "turn_timeout_ms",
    3_600_000,
    decode.int,
  )
  use read_timeout <- decode.optional_field("read_timeout_ms", 5000, decode.int)
  use stall_timeout <- decode.optional_field(
    "stall_timeout_ms",
    300_000,
    decode.int,
  )
  decode.success(CodexConfig(
    command,
    approval,
    thread_sandbox,
    turn_sandbox,
    turn_timeout,
    read_timeout,
    stall_timeout,
  ))
}

fn resolve_path(
  path: String,
  relative_to: String,
) -> Result(String, domain.ServiceError) {
  let expanded = case
    string.starts_with(path, "$"),
    string.drop_start(path, 1)
  {
    True, variable ->
      case runtime.getenv(variable) {
        Ok(value) if value != "" -> Ok(value)
        _ ->
          Error(InvalidConfig(
            "environment variable " <> variable <> " is missing",
          ))
      }
    False, _ ->
      case path {
        "~" -> Ok(runtime.home())
        "~/" <> rest -> Ok(runtime.join(runtime.home(), rest))
        _ -> Ok(path)
      }
  }
  use expanded <- result.try(expanded)
  let absolute = case string.starts_with(expanded, "/") {
    True -> runtime.absolute_path(expanded)
    False -> runtime.absolute_path(runtime.join(relative_to, expanded))
  }
  Ok(absolute)
}

fn validate(
  tracker: TrackerConfig,
  polling: Int,
  hooks: HooksConfig,
  agent: AgentConfig,
  codex: CodexConfig,
) -> Result(Nil, String) {
  let TrackerConfig(kind:, active_states:, terminal_states:, ..) = tracker
  let HooksConfig(timeout_ms:, ..) = hooks
  let AgentConfig(max_concurrent_agents:, max_turns:, max_retry_backoff_ms:, ..) =
    agent
  let CodexConfig(command:, turn_timeout_ms:, read_timeout_ms:, ..) = codex
  case
    string.trim(kind) == "",
    active_states,
    terminal_states,
    polling > 0,
    timeout_ms > 0,
    max_concurrent_agents > 0,
    max_turns > 0,
    max_retry_backoff_ms > 0,
    string.trim(command) == "",
    turn_timeout_ms > 0,
    read_timeout_ms > 0
  {
    True, _, _, _, _, _, _, _, _, _, _ -> Error("tracker.kind is required")
    _, [], _, _, _, _, _, _, _, _, _ ->
      Error("tracker.active_states must not be empty")
    _, _, [], _, _, _, _, _, _, _, _ ->
      Error("tracker.terminal_states must not be empty")
    _, _, _, False, _, _, _, _, _, _, _ ->
      Error("polling.interval_ms must be positive")
    _, _, _, _, False, _, _, _, _, _, _ ->
      Error("hooks.timeout_ms must be positive")
    _, _, _, _, _, False, _, _, _, _, _ ->
      Error("agent.max_concurrent_agents must be positive")
    _, _, _, _, _, _, False, _, _, _, _ ->
      Error("agent.max_turns must be positive")
    _, _, _, _, _, _, _, False, _, _, _ ->
      Error("agent.max_retry_backoff_ms must be positive")
    _, _, _, _, _, _, _, _, True, _, _ ->
      Error("codex.command must not be empty")
    _, _, _, _, _, _, _, _, _, False, _ ->
      Error("codex.turn_timeout_ms must be positive")
    _, _, _, _, _, _, _, _, _, _, False ->
      Error("codex.read_timeout_ms must be positive")
    _, _, _, _, _, _, _, _, _, _, _ -> Ok(Nil)
  }
}
