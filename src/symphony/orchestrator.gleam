import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Eq, Gt, Lt}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import symphony/codex.{type AgentEvent, type Usage, AgentEvent, Usage}
import symphony/config
import symphony/domain.{
  type AgentConfig, type Config, type Issue, type ServiceError,
  type TrackerConfig, type Workflow, AgentConfig, Config, TrackerConfig,
  Workflow,
}
import symphony/prompt
import symphony/runtime
import symphony/tracker.{type Adapter}
import symphony/tracker_factory
import symphony/workflow
import symphony/workspace

type Running {
  Running(
    issue: Issue,
    pid: Pid,
    started_at_ms: Int,
    last_event_at_ms: Int,
    session_id: Option(String),
    codex_app_server_pid: String,
    last_event: String,
    input_tokens: Int,
    output_tokens: Int,
    total_tokens: Int,
    turn_count: Int,
    retry_attempt: Int,
  )
}

type RetryEntry {
  RetryEntry(
    issue_id: String,
    identifier: String,
    attempt: Int,
    due_at_ms: Int,
    error: Option(String),
  )
}

type Totals {
  Totals(
    input_tokens: Int,
    output_tokens: Int,
    total_tokens: Int,
    runtime_ms: Int,
  )
}

type State {
  State(
    workflow_path: String,
    workflow: Workflow,
    config: Config,
    tracker: Adapter,
    running: Dict(String, Running),
    claimed: Set(String),
    retrying: Dict(String, RetryEntry),
    completed: Set(String),
    totals: Totals,
    rate_limits: Option(Dynamic),
    messages: Subject(WorkerMessage),
  )
}

type WorkerMessage {
  AgentUpdate(issue_id: String, event: AgentEvent)
  WorkerFinished(issue_id: String, outcome: Result(Nil, ServiceError))
}

pub fn run(workflow_path: String) -> Result(Nil, ServiceError) {
  use loaded <- result.try(workflow.load(workflow_path))
  use effective <- result.try(config.from_workflow(loaded))
  let Workflow(directory:, ..) = loaded
  use adapter <- result.try(tracker_factory.create(effective.tracker, directory))
  let state =
    State(
      workflow_path: loaded.path,
      workflow: loaded,
      config: effective,
      tracker: adapter,
      running: dict.new(),
      claimed: set.new(),
      retrying: dict.new(),
      completed: set.new(),
      totals: Totals(0, 0, 0, 0),
      rate_limits: None,
      messages: process.new_subject(),
    )
  log("service_start completed workflow=" <> state.workflow_path)
  let state = startup_cleanup(state)
  loop(state, runtime.now_ms())
}

fn loop(state: State, next_tick_ms: Int) -> Result(Nil, ServiceError) {
  let state = drain_messages(state)
  let now = runtime.now_ms()
  let state = handle_due_retries(state, now)
  let #(state, next_tick_ms) = case now >= next_tick_ms {
    True -> {
      let state = tick(state)
      #(state, now + state.config.polling_interval_ms)
    }
    False -> #(state, next_tick_ms)
  }
  let wait_ms = next_wake_in(state, next_tick_ms)
  case process.receive(state.messages, wait_ms) {
    Ok(message) -> loop(handle_message(state, message), next_tick_ms)
    Error(_) -> loop(state, next_tick_ms)
  }
}

fn drain_messages(state: State) -> State {
  case process.receive(state.messages, 0) {
    Ok(message) -> drain_messages(handle_message(state, message))
    Error(_) -> state
  }
}

fn tick(state: State) -> State {
  let state = reload(state)
  let state = reconcile(state)
  case
    tracker.fetch_issues_by_states(
      state.tracker,
      state.config.tracker.active_states,
    )
  {
    Error(error) -> {
      log("tracker_poll failed reason=" <> string.inspect(error))
      state
    }
    Ok(issues) ->
      issues
      |> sort_issues
      |> list.fold(state, fn(state, issue) {
        case can_dispatch(state, issue, False) {
          True -> dispatch(state, issue, None)
          False -> state
        }
      })
  }
}

fn reload(state: State) -> State {
  let updated = {
    use loaded <- result.try(workflow.load(state.workflow_path))
    use effective <- result.try(config.from_workflow(loaded))
    let Workflow(directory:, ..) = loaded
    use adapter <- result.try(tracker_factory.create(
      effective.tracker,
      directory,
    ))
    Ok(#(loaded, effective, adapter))
  }
  case updated {
    Ok(#(loaded, effective, adapter)) ->
      State(..state, workflow: loaded, config: effective, tracker: adapter)
    Error(error) -> {
      log(
        "workflow_reload failed keeping_last_good=true reason="
        <> string.inspect(error),
      )
      state
    }
  }
}

fn startup_cleanup(state: State) -> State {
  case
    tracker.fetch_issues_by_states(
      state.tracker,
      state.config.tracker.terminal_states,
    )
  {
    Error(error) -> {
      log("startup_cleanup failed reason=" <> string.inspect(error))
      state
    }
    Ok(issues) -> {
      list.each(issues, fn(issue) { cleanup_workspace(state.config, issue) })
      state
    }
  }
}

fn reconcile(state: State) -> State {
  let now = runtime.now_ms()
  let Config(codex:, ..) = state.config
  let stalled =
    state.running
    |> dict.to_list
    |> list.filter_map(fn(entry) {
      let #(id, running) = entry
      case
        codex.stall_timeout_ms > 0
        && now - running.last_event_at_ms > codex.stall_timeout_ms
      {
        True -> Ok(id)
        False -> Error(Nil)
      }
    })
  let state =
    list.fold(stalled, state, fn(state, id) {
      case dict.get(state.running, id) {
        Error(_) -> state
        Ok(running) -> {
          process.kill(running.pid)
          log_issue(running.issue, "worker_stalled retrying=true")
          run_cancelled_after_run(state.config, running.issue)
          state
          |> finish_running(id)
          |> schedule_retry(
            running.issue,
            running.retry_attempt + 1,
            Some("stalled"),
            False,
          )
        }
      }
    })
  let dead =
    state.running
    |> dict.to_list
    |> list.filter_map(fn(entry) {
      case process.is_alive(entry.1.pid) {
        True -> Error(Nil)
        False -> Ok(entry.0)
      }
    })
  let state =
    list.fold(dead, state, fn(state, id) {
      case dict.get(state.running, id) {
        Error(_) -> state
        Ok(running) -> {
          log_issue(
            running.issue,
            "worker_exit failed retrying=true reason=unexpected_process_exit",
          )
          state
          |> finish_running(id)
          |> schedule_retry(
            running.issue,
            running.retry_attempt + 1,
            Some("unexpected process exit"),
            False,
          )
        }
      }
    })
  let ids = dict.keys(state.running)
  case tracker.fetch_issues_by_ids(state.tracker, ids) {
    Error(error) -> {
      case ids {
        [] -> Nil
        _ ->
          log(
            "reconcile failed workers_kept=true reason="
            <> string.inspect(error),
          )
      }
      state
    }
    Ok(refreshed) -> reconcile_snapshots(state, refreshed)
  }
}

fn reconcile_snapshots(state: State, refreshed: List(Issue)) -> State {
  let refreshed_by_id =
    refreshed |> list.map(fn(issue) { #(issue.id, issue) }) |> dict.from_list
  state.running
  |> dict.keys
  |> list.fold(state, fn(state, id) {
    case dict.get(state.running, id), dict.get(refreshed_by_id, id) {
      Error(_), _ -> state
      Ok(running), Error(_) ->
        stop_and_release(state, running, False, "issue_missing")
      Ok(running), Ok(issue) ->
        case
          is_terminal(issue, state.config.tracker),
          is_active(issue, state.config.tracker),
          issue_routable(issue, state.config.tracker)
        {
          True, _, _ ->
            stop_and_release(
              state,
              Running(..running, issue: issue),
              True,
              "terminal",
            )
          False, True, True ->
            State(
              ..state,
              running: dict.insert(
                state.running,
                id,
                Running(..running, issue: issue),
              ),
            )
          _, _, _ ->
            stop_and_release(
              state,
              Running(..running, issue: issue),
              False,
              "ineligible",
            )
        }
    }
  })
}

fn stop_and_release(
  state: State,
  running: Running,
  cleanup: Bool,
  reason: String,
) -> State {
  process.kill(running.pid)
  run_cancelled_after_run(state.config, running.issue)
  let state = finish_running(state, running.issue.id)
  let state =
    State(
      ..state,
      claimed: set.delete(state.claimed, running.issue.id),
      retrying: dict.delete(state.retrying, running.issue.id),
    )
  case cleanup {
    True -> cleanup_workspace(state.config, running.issue)
    False -> Nil
  }
  log_issue(running.issue, "worker_stopped reason=" <> reason)
  state
}

fn dispatch(state: State, issue: Issue, attempt: Option(Int)) -> State {
  let retry_attempt = attempt |> option.unwrap(0)
  let subject = state.messages
  let workflow = state.workflow
  let config = state.config
  let tracker = state.tracker
  let pid =
    process.spawn_unlinked(fn() {
      let outcome =
        run_attempt(issue, attempt, workflow, config, tracker, subject)
      process.send(subject, WorkerFinished(issue.id, outcome))
    })
  let now = runtime.now_ms()
  let running =
    Running(
      issue,
      pid,
      now,
      now,
      None,
      "",
      "starting",
      0,
      0,
      0,
      0,
      retry_attempt,
    )
  log_issue(
    issue,
    "dispatch completed attempt=" <> int.to_string(retry_attempt),
  )
  State(
    ..state,
    running: dict.insert(state.running, issue.id, running),
    claimed: set.insert(state.claimed, issue.id),
    retrying: dict.delete(state.retrying, issue.id),
  )
}

fn run_attempt(
  issue: Issue,
  attempt: Option(Int),
  workflow: Workflow,
  config: Config,
  tracker: Adapter,
  messages: Subject(WorkerMessage),
) -> Result(Nil, ServiceError) {
  use work <- result.try(workspace.create(config, issue.identifier))
  let outcome = {
    use _ <- result.try(workspace.validate_agent_cwd(config, work))
    use _ <- result.try(workspace.before_run(config, work))
    use first_prompt <- result.try(prompt.render(
      workflow.prompt_template,
      issue,
      attempt,
    ))
    use session <- result.try(codex.start(
      config.codex,
      work.path,
      tracker.secret_environment_names,
    ))
    let outcome =
      run_turns(session, issue, first_prompt, 1, config, tracker, messages)
    codex.stop(session)
    outcome
  }
  case workspace.after_run(config, work) {
    Error(error) ->
      log_issue(
        issue,
        "after_run failed ignored=true reason=" <> string.inspect(error),
      )
    Ok(_) -> Nil
  }
  outcome
}

fn run_turns(
  session: codex.Session,
  issue: Issue,
  turn_prompt: String,
  turn_number: Int,
  config: Config,
  tracker: Adapter,
  messages: Subject(WorkerMessage),
) -> Result(Nil, ServiceError) {
  use session <- result.try(
    codex.run_turn(session, turn_prompt, fn(event) {
      process.send(messages, AgentUpdate(issue.id, event))
    }),
  )
  use refreshed <- result.try(tracker.fetch_issues_by_ids(tracker, [issue.id]))
  case refreshed, turn_number >= config.agent.max_turns {
    [], _ -> Ok(Nil)
    [updated, ..], False ->
      case
        is_active(updated, config.tracker)
        && issue_routable(updated, config.tracker)
      {
        True ->
          run_turns(
            session,
            updated,
            "Continue working on the issue. Re-check its tracker state and complete the next useful step.",
            turn_number + 1,
            config,
            tracker,
            messages,
          )
        False -> Ok(Nil)
      }
    _, _ -> Ok(Nil)
  }
}

fn handle_message(state: State, message: WorkerMessage) -> State {
  case message {
    AgentUpdate(issue_id, event) -> handle_agent_update(state, issue_id, event)
    WorkerFinished(issue_id, outcome) ->
      case dict.get(state.running, issue_id) {
        Error(_) -> state
        Ok(running) -> {
          let state = finish_running(state, issue_id)
          case outcome {
            Ok(_) -> {
              log_issue(
                running.issue,
                "worker_exit completed continuation=true",
              )
              let state =
                State(..state, completed: set.insert(state.completed, issue_id))
              schedule_retry(state, running.issue, 1, None, True)
            }
            Error(error) -> {
              log_issue(
                running.issue,
                "worker_exit failed retrying=true reason="
                  <> string.inspect(error),
              )
              schedule_retry(
                state,
                running.issue,
                running.retry_attempt + 1,
                Some(string.inspect(error)),
                False,
              )
            }
          }
        }
      }
  }
}

fn handle_agent_update(
  state: State,
  issue_id: String,
  event: AgentEvent,
) -> State {
  case dict.get(state.running, issue_id) {
    Error(_) -> state
    Ok(running) -> {
      let AgentEvent(
        event:,
        timestamp_ms:,
        session_id:,
        codex_app_server_pid:,
        usage:,
        rate_limits:,
        ..,
      ) = event
      let #(input, output, total, totals) = case usage {
        None -> #(
          running.input_tokens,
          running.output_tokens,
          running.total_tokens,
          state.totals,
        )
        Some(Usage(new_input, new_output, new_total)) -> {
          let Totals(all_input, all_output, all_total, runtime_ms) =
            state.totals
          let Usage(delta_input, delta_output, delta_total) =
            usage_delta(
              Usage(
                running.input_tokens,
                running.output_tokens,
                running.total_tokens,
              ),
              Usage(new_input, new_output, new_total),
            )
          #(
            new_input,
            new_output,
            new_total,
            Totals(
              all_input + delta_input,
              all_output + delta_output,
              all_total + delta_total,
              runtime_ms,
            ),
          )
        }
      }
      let turn_count = case event == "session_started" {
        True -> running.turn_count + 1
        False -> running.turn_count
      }
      let running =
        Running(
          ..running,
          last_event_at_ms: timestamp_ms,
          session_id: case session_id {
            Some(_) -> session_id
            None -> running.session_id
          },
          codex_app_server_pid: codex_app_server_pid,
          last_event: event,
          input_tokens: input,
          output_tokens: output,
          total_tokens: total,
          turn_count: turn_count,
        )
      case session_id {
        Some(session_id) ->
          case event {
            "session_started" | "turn_completed" | "turn_failed" ->
              log_issue(
                running.issue,
                "session_id=" <> session_id <> " event=" <> event,
              )
            _ -> Nil
          }
        None -> Nil
      }
      State(
        ..state,
        running: dict.insert(state.running, issue_id, running),
        totals: totals,
        rate_limits: case rate_limits {
          Some(_) -> rate_limits
          None -> state.rate_limits
        },
      )
    }
  }
}

fn finish_running(state: State, issue_id: String) -> State {
  case dict.get(state.running, issue_id) {
    Error(_) -> state
    Ok(running) -> {
      let Totals(input, output, total, runtime_ms) = state.totals
      State(
        ..state,
        running: dict.delete(state.running, issue_id),
        totals: Totals(
          input,
          output,
          total,
          runtime_ms + runtime.now_ms() - running.started_at_ms,
        ),
      )
    }
  }
}

fn schedule_retry(
  state: State,
  issue: Issue,
  attempt: Int,
  error: Option(String),
  continuation: Bool,
) -> State {
  let delay = case continuation {
    True -> 1000
    False -> retry_delay(attempt, state.config.agent.max_retry_backoff_ms)
  }
  let entry =
    RetryEntry(
      issue.id,
      issue.identifier,
      attempt,
      runtime.now_ms() + delay,
      error,
    )
  State(
    ..state,
    retrying: dict.insert(state.retrying, issue.id, entry),
    claimed: set.insert(state.claimed, issue.id),
  )
}

fn handle_due_retries(state: State, now: Int) -> State {
  state.retrying
  |> dict.values
  |> list.filter(fn(entry) { entry.due_at_ms <= now })
  |> list.fold(state, handle_retry)
}

fn handle_retry(state: State, entry: RetryEntry) -> State {
  let state =
    State(..state, retrying: dict.delete(state.retrying, entry.issue_id))
  case tracker.fetch_issues_by_ids(state.tracker, [entry.issue_id]) {
    Error(error) ->
      reschedule_entry(
        state,
        entry,
        "retry refresh failed: " <> string.inspect(error),
      )
    Ok([]) -> release(state, entry.issue_id)
    Ok([issue, ..]) ->
      case is_terminal(issue, state.config.tracker) {
        True -> {
          cleanup_workspace(state.config, issue)
          release(state, issue.id)
        }
        False ->
          case can_dispatch(state, issue, True) {
            True -> dispatch(state, issue, Some(entry.attempt))
            False ->
              case
                is_active(issue, state.config.tracker)
                && issue_routable(issue, state.config.tracker)
              {
                True ->
                  reschedule_entry(
                    state,
                    entry,
                    "no available orchestrator slots",
                  )
                False -> release(state, issue.id)
              }
          }
      }
  }
}

fn reschedule_entry(state: State, entry: RetryEntry, error: String) -> State {
  let next =
    RetryEntry(
      ..entry,
      attempt: entry.attempt + 1,
      due_at_ms: runtime.now_ms()
        + retry_delay(
          entry.attempt + 1,
          state.config.agent.max_retry_backoff_ms,
        ),
      error: Some(error),
    )
  State(
    ..state,
    retrying: dict.insert(state.retrying, entry.issue_id, next),
    claimed: set.insert(state.claimed, entry.issue_id),
  )
}

fn release(state: State, issue_id: String) -> State {
  State(
    ..state,
    claimed: set.delete(state.claimed, issue_id),
    retrying: dict.delete(state.retrying, issue_id),
  )
}

fn can_dispatch(
  state: State,
  issue: Issue,
  ignore_existing_claim: Bool,
) -> Bool {
  let global_slots =
    state.config.agent.max_concurrent_agents - dict.size(state.running)
  let state_limit = per_state_limit(state.config.agent, issue.state)
  let state_running =
    state.running
    |> dict.values
    |> list.count(fn(running) {
      domain.normalize(running.issue.state) == domain.normalize(issue.state)
    })
  issue.id != ""
  && issue.identifier != ""
  && issue.title != ""
  && issue_routable(issue, state.config.tracker)
  && is_active(issue, state.config.tracker)
  && !is_terminal(issue, state.config.tracker)
  && !dict.has_key(state.running, issue.id)
  && { ignore_existing_claim || !set.contains(state.claimed, issue.id) }
  && global_slots > 0
  && state_running < state_limit
}

pub fn issue_routable(issue: Issue, config: TrackerConfig) -> Bool {
  let TrackerConfig(required_labels:, ..) = config
  issue.dispatchable
  && list.all(required_labels, fn(required) {
    list.contains(issue.labels, domain.normalize(required))
  })
}

fn is_active(issue: Issue, config: TrackerConfig) -> Bool {
  list.any(config.active_states, fn(state) {
    domain.normalize(state) == domain.normalize(issue.state)
  })
}

fn is_terminal(issue: Issue, config: TrackerConfig) -> Bool {
  list.any(config.terminal_states, fn(state) {
    domain.normalize(state) == domain.normalize(issue.state)
  })
}

fn per_state_limit(config: AgentConfig, state: String) -> Int {
  let AgentConfig(max_concurrent_agents:, max_concurrent_agents_by_state:, ..) =
    config
  max_concurrent_agents_by_state
  |> list.find(fn(entry) { entry.0 == domain.normalize(state) })
  |> result.map(fn(entry) { entry.1 })
  |> result.unwrap(max_concurrent_agents)
}

pub fn sort_issues(issues: List(Issue)) -> List(Issue) {
  list.sort(issues, compare_issues)
}

fn compare_issues(left: Issue, right: Issue) -> order.Order {
  case int.compare(priority_rank(left), priority_rank(right)) {
    Eq ->
      case compare_optional_time(left.created_at, right.created_at) {
        Eq -> string.compare(left.identifier, right.identifier)
        order -> order
      }
    order -> order
  }
}

fn priority_rank(issue: Issue) -> Int {
  case issue.priority {
    Some(value) if value >= 1 && value <= 4 -> value
    _ -> 5
  }
}

fn compare_optional_time(left: Option(Int), right: Option(Int)) -> order.Order {
  case left, right {
    Some(left), Some(right) -> int.compare(left, right)
    Some(_), None -> Lt
    None, Some(_) -> Gt
    None, None -> Eq
  }
}

pub fn retry_delay(attempt: Int, cap: Int) -> Int {
  retry_delay_loop(attempt, 10_000, cap)
}

pub fn usage_delta(previous: Usage, current: Usage) -> Usage {
  let Usage(previous_input, previous_output, previous_total) = previous
  let Usage(current_input, current_output, current_total) = current
  Usage(
    int.max(0, current_input - previous_input),
    int.max(0, current_output - previous_output),
    int.max(0, current_total - previous_total),
  )
}

fn retry_delay_loop(attempt: Int, current: Int, cap: Int) -> Int {
  case attempt <= 1 || current >= cap {
    True -> int.min(current, cap)
    False -> retry_delay_loop(attempt - 1, int.min(current * 2, cap), cap)
  }
}

fn next_wake_in(state: State, next_tick_ms: Int) -> Int {
  let retry_due =
    state.retrying
    |> dict.values
    |> list.map(fn(entry) { entry.due_at_ms })
    |> list.sort(int.compare)
    |> list.first
    |> result.unwrap(next_tick_ms)
  int.max(0, int.min(next_tick_ms, retry_due) - runtime.now_ms())
}

fn log(message: String) -> Nil {
  io.println("component=symphony " <> message)
}

fn log_issue(issue: Issue, message: String) -> Nil {
  log(
    "issue_id="
    <> issue.id
    <> " issue_identifier="
    <> issue.identifier
    <> " "
    <> message,
  )
}

fn run_cancelled_after_run(config: Config, issue: Issue) -> Nil {
  case workspace.after_run_for_issue(config, issue.identifier) {
    Ok(_) -> Nil
    Error(error) ->
      log_issue(
        issue,
        "after_run failed ignored=true reason=" <> string.inspect(error),
      )
  }
}

fn cleanup_workspace(config: Config, issue: Issue) -> Nil {
  case
    workspace.remove(config, issue.identifier, fn(error) {
      log_issue(
        issue,
        "before_remove failed ignored=true reason=" <> string.inspect(error),
      )
    })
  {
    Ok(_) -> log_issue(issue, "workspace_cleanup completed")
    Error(error) ->
      log_issue(
        issue,
        "workspace_cleanup failed reason=" <> string.inspect(error),
      )
  }
}
