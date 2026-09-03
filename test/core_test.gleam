import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import symphony
import symphony/codex
import symphony/config
import symphony/domain.{
  AgentConfig, BlockerRef, CodexConfig, Config, HooksConfig, Issue,
  TrackerConfig,
}
import symphony/orchestrator
import symphony/prompt
import symphony/runtime
import symphony/tracker
import symphony/tracker/file
import symphony/tracker_factory
import symphony/workflow
import symphony/workspace

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn workflow_and_config_test() {
  let root = test_dir("workflow")
  let path = runtime.join(root, "WORKFLOW.md")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "---\ntracker:\n  kind: file\n  provider:\n    path: issues.json\n  active_states: [Todo]\n  terminal_states: [Done]\npolling:\n  interval_ms: 25\nworkspace:\n  root: workspaces\n---\nWork on {{issue.identifier}}\n",
    )
  let loaded = workflow.load(path) |> should.be_ok
  should.equal(loaded.prompt_template, "Work on {{issue.identifier}}")
  let effective = config.from_workflow(loaded) |> should.be_ok
  should.equal(effective.polling_interval_ms, 25)
  should.equal(effective.workspace_root, runtime.join(root, "workspaces"))
  should.equal(effective.agent.max_turns, 20)
  let _ = runtime.remove_tree(root)
}

pub fn cli_workflow_path_selection_test() {
  should.equal(symphony.workflow_path([]), Ok("./WORKFLOW.md"))
  should.equal(symphony.workflow_path(["custom.md"]), Ok("custom.md"))
  symphony.workflow_path(["one", "two"]) |> should.be_error
}

pub fn invalid_per_state_concurrency_entries_are_ignored_test() {
  let root = test_dir("per_state")
  let path = runtime.join(root, "WORKFLOW.md")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "---\ntracker:\n  kind: file\n  provider:\n    path: issues.json\n  active_states: [Todo]\n  terminal_states: [Done]\nagent:\n  max_concurrent_agents_by_state:\n    Todo: invalid\n    In Progress: 2\n---\nWork\n",
    )
  let effective =
    workflow.load(path)
    |> should.be_ok
    |> config.from_workflow
    |> should.be_ok
  should.equal(effective.agent.max_concurrent_agents_by_state, [
    #("in progress", 2),
  ])
  let _ = runtime.remove_tree(root)
}

pub fn malformed_front_matter_test() {
  let root = test_dir("bad_workflow")
  let path = runtime.join(root, "WORKFLOW.md")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(to: path, contents: "---\ntracker:\n  kind: file\n")
  workflow.load(path) |> should.be_error
  let _ = runtime.remove_tree(root)
}

pub fn workflow_error_surface_and_path_expansion_test() {
  let root = test_dir("workflow_errors")
  let path = runtime.join(root, "WORKFLOW.md")
  workflow.load(path) |> should.be_error
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(to: path, contents: "---\n- not\n- a-map\n---\nWork")
  workflow.load(path) |> should.be_error
  let assert Ok(_) =
    simplifile.write(to: path, contents: "---\ntracker: [\n---\nWork")
  workflow.load(path) |> should.be_error
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "---\ntracker:\n  kind: unsupported\n  provider:\n    custom: preserved\n  active_states: [Todo]\n  terminal_states: [Done]\nworkspace:\n  root: ~/symphony-test\nextension:\n  value: ignored\n---\nWork",
    )
  let loaded = workflow.load(path) |> should.be_ok
  let effective = config.from_workflow(loaded) |> should.be_ok
  should.equal(
    effective.workspace_root,
    runtime.join(runtime.home(), "symphony-test"),
  )
  tracker_factory.create(effective.tracker, root) |> should.be_error
  let _ = runtime.remove_tree(root)
}

pub fn strict_prompt_and_iteration_test() {
  let issue = issue("A-1", "Todo", ["bug", "ready"], 2)
  prompt.render(
    "{{issue.identifier}} {{#each issue.labels}}{{.}} {{/each}}attempt={{attempt}}",
    issue,
    Some(3),
  )
  |> should.equal(Ok("A-1 bug ready attempt=3"))
  prompt.render("{{unknown}}", issue, None) |> should.be_error
}

pub fn workspace_safety_and_hooks_test() {
  let root = test_dir("workspace")
  let config =
    test_config(
      root,
      HooksConfig(Some("printf x >> created"), None, None, None, 1000),
    )
  should.not_equal(workspace.key("A/B"), workspace.key("A?B"))
  should.equal(workspace.key("ABC-123"), "ABC-123")
  let first = workspace.create(config, "A/B") |> should.be_ok
  should.be_true(first.created_now)
  let second = workspace.create(config, "A/B") |> should.be_ok
  should.be_false(second.created_now)
  simplifile.read(runtime.join(first.path, "created")) |> should.equal(Ok("x"))
  workspace.remove(config, "A/B", fn(_) { Nil }) |> should.equal(Ok(Nil))
  simplifile.exists(first.path, follow_links: False) |> should.equal(Ok(False))
  let _ = runtime.remove_tree(root)
}

pub fn hook_deadline_and_cleanup_warning_test() {
  let root = test_dir("hook_deadline")
  let warnings = process.new_subject()
  let config =
    test_config(
      root,
      HooksConfig(None, None, None, Some("printf warning >&2; exit 7"), 100),
    )
  let assert Ok(_) = simplifile.create_directory_all(root)
  runtime.run_hook(
    "for i in 1 2 3 4 5; do printf x; sleep 0.05; done",
    root,
    100,
  )
  |> should.be_error
  let _ = workspace.create(config, "WARN-1") |> should.be_ok
  workspace.remove(config, "WARN-1", fn(error) { process.send(warnings, error) })
  |> should.equal(Ok(Nil))
  process.receive(warnings, 100) |> should.be_ok
  let _ = runtime.remove_tree(root)
}

pub fn workspace_rejects_unsafe_paths_and_hook_failures_test() {
  let root = test_dir("workspace_failures")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let failing_create =
    test_config(root, HooksConfig(Some("exit 1"), None, None, None, 1000))
  workspace.create(failing_create, "CREATE-1") |> should.be_error

  let failing_attempt =
    test_config(
      root,
      HooksConfig(None, Some("exit 2"), Some("exit 3"), None, 1000),
    )
  let work = workspace.create(failing_attempt, "RUN-1") |> should.be_ok
  workspace.before_run(failing_attempt, work) |> should.be_error
  workspace.after_run(failing_attempt, work) |> should.be_error

  workspace.create(failing_attempt, "..") |> should.be_error
  let assert Ok(_) =
    simplifile.write(
      to: runtime.join(root, "FILE-1"),
      contents: "not a directory",
    )
  workspace.create(failing_attempt, "FILE-1") |> should.be_error
  let _ = runtime.remove_tree(root)
}

pub fn file_tracker_boundary_test() {
  let root = test_dir("tracker")
  let path = runtime.join(root, "issues.json")
  let provider =
    dynamic.properties([
      #(dynamic.string("path"), dynamic.string(path)),
    ])
  let config = TrackerConfig("file", provider, [], ["Todo"], ["Done"])
  let adapter = file.new(config, root) |> should.be_ok
  tracker.fetch_issues_by_states(adapter, []) |> should.equal(Ok([]))
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "[{\"id\":\"1\",\"identifier\":\"T-1\",\"title\":\"Task\",\"state\":\"Todo\",\"labels\":[\" Ready \",\"READY\"],\"dispatchable\":true,\"priority\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}]",
    )
  let issues =
    tracker.fetch_issues_by_states(adapter, [" todo "]) |> should.be_ok
  let fetched = issues |> list.first |> should.be_ok
  should.equal(fetched.labels, ["ready"])
  should.equal(fetched.priority, Some(1))
  tracker.fetch_issues_by_ids(adapter, ["1"]) |> should.equal(Ok(issues))
  let _ = runtime.remove_tree(root)
}

pub fn file_tracker_rejects_ambiguous_identity_and_normalizes_native_ref_test() {
  let root = test_dir("tracker_identity")
  let path = runtime.join(root, "issues.json")
  let provider =
    dynamic.properties([
      #(dynamic.string("path"), dynamic.string(path)),
    ])
  let config = TrackerConfig("file", provider, [], ["Todo"], ["Done"])
  let adapter = file.new(config, root) |> should.be_ok
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "[{\"id\":\"1\",\"identifier\":\"T-1\",\"title\":\"Task\",\"state\":\"Todo\",\"dispatchable\":true,\"native_ref\":\"not-an-object\"}]",
    )
  let issues = tracker.fetch_issues_by_ids(adapter, ["1"]) |> should.be_ok
  let fetched = issues |> list.first |> should.be_ok
  should.equal(fetched.native_ref, None)
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "[{\"id\":\"1\",\"identifier\":\"DUP-1\",\"title\":\"First\",\"state\":\"Todo\",\"dispatchable\":true},{\"id\":\"2\",\"identifier\":\"DUP-1\",\"title\":\"Second\",\"state\":\"Todo\",\"dispatchable\":true}]",
    )
  tracker.fetch_issues_by_states(adapter, ["Todo"]) |> should.be_error
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "[{\"id\":\"1\",\"identifier\":\"T-1\",\"title\":\"First\",\"state\":\"Todo\",\"dispatchable\":true},{\"id\":\"1\",\"identifier\":\"T-2\",\"title\":\"Second\",\"state\":\"Todo\",\"dispatchable\":true}]",
    )
  tracker.fetch_issues_by_ids(adapter, ["1"]) |> should.be_error
  let _ = runtime.remove_tree(root)
}

pub fn scheduling_rules_test() {
  let later = issue("T-2", "Todo", [], 2)
  let first = issue("T-1", "Todo", [], 1)
  orchestrator.sort_issues([later, first]) |> should.equal([first, later])
  should.equal(orchestrator.retry_delay(1, 300_000), 10_000)
  should.equal(orchestrator.retry_delay(6, 300_000), 300_000)
  let tracker_config =
    TrackerConfig("file", dynamic.properties([]), ["ready"], ["Todo"], ["Done"])
  should.be_false(orchestrator.issue_routable(first, tracker_config))
  should.equal(
    orchestrator.usage_delta(codex.Usage(3, 2, 5), codex.Usage(8, 4, 12)),
    codex.Usage(5, 2, 7),
  )
  should.equal(
    orchestrator.usage_delta(codex.Usage(8, 4, 12), codex.Usage(3, 2, 5)),
    codex.Usage(0, 0, 0),
  )
}

pub fn codex_jsonl_protocol_test() {
  let root = test_dir("codex")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let fixture = runtime.absolute_path("test/fixtures/fake_codex.py")
  let config =
    CodexConfig(
      "python3 " <> fixture,
      dynamic.string("never"),
      "workspace-write",
      dynamic.string("workspace-write"),
      2000,
      2000,
      2000,
    )
  let events = process.new_subject()
  let session = codex.start(config, root, []) |> should.be_ok
  let session =
    codex.run_turn(session, "Do the work", fn(event) {
      process.send(events, event)
    })
    |> should.be_ok
  let first = process.receive(events, 100) |> should.be_ok
  should.equal(first.event, "session_started")
  let usage_event = process.receive(events, 100) |> should.be_ok
  should.equal(usage_event.usage, Some(codex.Usage(3, 2, 5)))
  let completed = process.receive(events, 100) |> should.be_ok
  should.equal(completed.event, "turn_completed")
  codex.stop(session)
  let _ = runtime.remove_tree(root)
}

pub fn codex_filters_secrets_and_enforces_startup_deadline_test() {
  let root = test_dir("codex_security")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let fixture = runtime.absolute_path("test/fixtures/fake_codex.py")
  putenv("SYMPHONY_TEST_SECRET", "sensitive")
  let session =
    codex.start(
      codex_config(
        "python3 " <> fixture <> " check-secret SYMPHONY_TEST_SECRET",
        1000,
      ),
      root,
      ["SYMPHONY_TEST_SECRET"],
    )
    |> should.be_ok
  codex.stop(session)
  unsetenv("SYMPHONY_TEST_SECRET")
  codex.start(
    codex_config("python3 " <> fixture <> " startup-noise", 100),
    root,
    [],
  )
  |> should.be_error
  let _ = runtime.remove_tree(root)
}

pub fn codex_interactive_request_policies_test() {
  let root = test_dir("codex_requests")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let fixture = runtime.absolute_path("test/fixtures/fake_codex.py")
  assert_declined_approval(root, fixture, "command-approval")
  assert_declined_approval(root, fixture, "file-approval")
  let permission_response = runtime.join(root, "permission-response")
  let permission_session =
    codex.start(
      codex_config(
        "python3 " <> fixture <> " permission " <> permission_response,
        1000,
      ),
      root,
      [],
    )
    |> should.be_ok
  codex.run_turn(permission_session, "Work", fn(_) { Nil })
  |> should.be_error
  wait_for_file(permission_response, 20)
  simplifile.read(permission_response)
  |> should.be_ok
  |> string.contains("\"error\"")
  |> should.be_true
  codex.stop(permission_session)

  let input_response = runtime.join(root, "input-response")
  let input_session =
    codex.start(
      codex_config(
        "python3 " <> fixture <> " user-input " <> input_response,
        1000,
      ),
      root,
      [],
    )
    |> should.be_ok
  codex.run_turn(input_session, "Work", fn(_) { Nil }) |> should.be_error
  wait_for_file(input_response, 20)
  codex.stop(input_session)

  let tool_response = runtime.join(root, "tool-response")
  let tool_session =
    codex.start(
      codex_config(
        "python3 " <> fixture <> " unsupported-tool " <> tool_response,
        1000,
      ),
      root,
      [],
    )
    |> should.be_ok
  codex.run_turn(tool_session, "Work", fn(_) { Nil }) |> should.be_ok
  wait_for_file(tool_response, 20)
  codex.stop(tool_session)
  let _ = runtime.remove_tree(root)
}

pub fn codex_turn_timeout_and_port_exit_test() {
  let root = test_dir("codex_turn_failures")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let fixture = runtime.absolute_path("test/fixtures/fake_codex.py")
  let silent_session =
    codex.start(
      CodexConfig(
        "python3 " <> fixture <> " turn-silent",
        dynamic.string("never"),
        "workspace-write",
        dynamic.string("workspace-write"),
        100,
        1000,
        1000,
      ),
      root,
      [],
    )
    |> should.be_ok
  codex.run_turn(silent_session, "Work", fn(_) { Nil }) |> should.be_error
  codex.stop(silent_session)

  let exit_session =
    codex.start(
      codex_config("python3 " <> fixture <> " turn-exit", 1000),
      root,
      [],
    )
    |> should.be_ok
  codex.run_turn(exit_session, "Work", fn(_) { Nil }) |> should.be_error
  codex.stop(exit_session)
  let _ = runtime.remove_tree(root)
}

pub fn terminal_reconciliation_runs_cleanup_hooks_test() {
  let root = test_dir("terminal_cleanup")
  let workflow_path = runtime.join(root, "WORKFLOW.md")
  let issues_path = runtime.join(root, "issues.json")
  let started_path = runtime.join(root, "started")
  let after_run_path = runtime.join(root, "after-run")
  let before_remove_path = runtime.join(root, "before-remove")
  let fixture = runtime.absolute_path("test/fixtures/fake_codex.py")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(to: issues_path, contents: issue_json("Todo"))
  let assert Ok(_) =
    simplifile.write(
      to: workflow_path,
      contents: integration_workflow(
        root,
        "python3 " <> fixture <> " hang " <> started_path,
        "Initial prompt",
        "  after_run: \"printf ran > "
          <> after_run_path
          <> "\"\n"
          <> "  before_remove: \"printf ran > "
          <> before_remove_path
          <> "\"\n",
      ),
    )
  let service =
    process.spawn_unlinked(fn() {
      let _ = orchestrator.run(workflow_path)
      Nil
    })
  wait_for_file(started_path, 80)
  let assert Ok(_) =
    simplifile.write(to: issues_path, contents: issue_json("Done"))
  wait_for_file(after_run_path, 80)
  wait_for_file(before_remove_path, 80)
  wait_for_absence(runtime.join(root, "workspaces/T-1"), 80)
  process.kill(service)
  let _ = runtime.remove_tree(root)
}

pub fn inactive_and_stalled_reconciliation_preserve_workspaces_test() {
  let fixture = runtime.absolute_path("test/fixtures/fake_codex.py")
  let inactive_root = test_dir("inactive_cleanup")
  let inactive_workflow = runtime.join(inactive_root, "WORKFLOW.md")
  let inactive_issues = runtime.join(inactive_root, "issues.json")
  let inactive_started = runtime.join(inactive_root, "started")
  let inactive_after_run = runtime.join(inactive_root, "after-run")
  let assert Ok(_) = simplifile.create_directory_all(inactive_root)
  let assert Ok(_) =
    simplifile.write(to: inactive_issues, contents: issue_json("Todo"))
  let assert Ok(_) =
    simplifile.write(
      to: inactive_workflow,
      contents: integration_workflow(
        inactive_root,
        "python3 " <> fixture <> " hang " <> inactive_started,
        "Work",
        "  after_run: \"printf ran > " <> inactive_after_run <> "\"\n",
      ),
    )
  let inactive_service =
    process.spawn_unlinked(fn() {
      let _ = orchestrator.run(inactive_workflow)
      Nil
    })
  wait_for_file(inactive_started, 80)
  let assert Ok(_) =
    simplifile.write(to: inactive_issues, contents: issue_json("Paused"))
  wait_for_file(inactive_after_run, 80)
  simplifile.exists(
    runtime.join(inactive_root, "workspaces/T-1"),
    follow_links: False,
  )
  |> should.equal(Ok(True))
  process.kill(inactive_service)
  let _ = runtime.remove_tree(inactive_root)

  let stalled_root = test_dir("stalled_cleanup")
  let stalled_workflow = runtime.join(stalled_root, "WORKFLOW.md")
  let stalled_issues = runtime.join(stalled_root, "issues.json")
  let stalled_after_run = runtime.join(stalled_root, "after-run")
  let assert Ok(_) = simplifile.create_directory_all(stalled_root)
  let assert Ok(_) =
    simplifile.write(to: stalled_issues, contents: issue_json("Todo"))
  let stalled_source =
    integration_workflow(
      stalled_root,
      "python3 " <> fixture <> " turn-silent",
      "Work",
      "  after_run: \"printf ran > " <> stalled_after_run <> "\"\n",
    )
    |> string.replace("stall_timeout_ms: 5000", "stall_timeout_ms: 100")
  let assert Ok(_) =
    simplifile.write(to: stalled_workflow, contents: stalled_source)
  let stalled_service =
    process.spawn_unlinked(fn() {
      let _ = orchestrator.run(stalled_workflow)
      Nil
    })
  wait_for_file(stalled_after_run, 80)
  simplifile.exists(
    runtime.join(stalled_root, "workspaces/T-1"),
    follow_links: False,
  )
  |> should.equal(Ok(True))
  process.kill(stalled_service)
  let _ = runtime.remove_tree(stalled_root)
}

pub fn workflow_reload_keeps_last_good_then_applies_valid_change_test() {
  let root = test_dir("reload")
  let workflow_path = runtime.join(root, "WORKFLOW.md")
  let issues_path = runtime.join(root, "issues.json")
  let prompts_path = runtime.join(root, "prompts")
  let fixture = runtime.absolute_path("test/fixtures/fake_codex.py")
  let command = "python3 " <> fixture <> " record " <> prompts_path
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(to: issues_path, contents: issue_json("Todo"))
  let assert Ok(_) =
    simplifile.write(
      to: workflow_path,
      contents: integration_workflow(root, command, "Initial prompt", ""),
    )
  let service =
    process.spawn_unlinked(fn() {
      let _ = orchestrator.run(workflow_path)
      Nil
    })
  let _ = wait_for_lines(prompts_path, 1, 120)
  let assert Ok(_) =
    simplifile.write(to: workflow_path, contents: "---\ntracker:\n")
  let prompts = wait_for_lines(prompts_path, 2, 120)
  should.be_true(string.starts_with(prompts, "Initial prompt\nInitial prompt\n"))
  let assert Ok(_) =
    simplifile.write(
      to: workflow_path,
      contents: integration_workflow(root, command, "Reloaded prompt", ""),
    )
  wait_for_lines(prompts_path, 3, 120)
  |> string.contains("Reloaded prompt")
  |> should.be_true
  process.kill(service)
  let _ = runtime.remove_tree(root)
}

fn issue(
  identifier: String,
  state: String,
  labels: List(String),
  priority: Int,
) -> domain.Issue {
  Issue(
    id: identifier,
    native_ref: None,
    identifier: identifier,
    title: "Task " <> identifier,
    description: None,
    priority: Some(priority),
    state: state,
    branch_name: None,
    url: None,
    assignee_id: None,
    labels: labels,
    blocked_by: [BlockerRef(None, None, None)],
    dispatchable: True,
    created_at: Some(priority),
    updated_at: None,
  )
}

fn test_config(root: String, hooks: domain.HooksConfig) -> domain.Config {
  Config(
    tracker: TrackerConfig("file", dynamic.properties([]), [], ["Todo"], [
      "Done",
    ]),
    polling_interval_ms: 30_000,
    workspace_root: root,
    hooks: hooks,
    agent: AgentConfig(2, 2, 300_000, []),
    codex: CodexConfig(
      "codex app-server",
      dynamic.string("never"),
      "workspace-write",
      dynamic.string("workspace-write"),
      1000,
      1000,
      1000,
    ),
  )
}

fn codex_config(command: String, read_timeout_ms: Int) -> domain.CodexConfig {
  CodexConfig(
    command,
    dynamic.string("never"),
    "workspace-write",
    dynamic.string("workspace-write"),
    1000,
    read_timeout_ms,
    1000,
  )
}

fn assert_declined_approval(
  root: String,
  fixture: String,
  mode: String,
) -> Nil {
  let response_path = runtime.join(root, mode <> "-response")
  let session =
    codex.start(
      codex_config(
        "python3 " <> fixture <> " " <> mode <> " " <> response_path,
        1000,
      ),
      root,
      [],
    )
    |> should.be_ok
  codex.run_turn(session, "Work", fn(_) { Nil }) |> should.be_ok
  wait_for_file(response_path, 20)
  simplifile.read(response_path)
  |> should.be_ok
  |> string.contains("\"decision\":\"decline\"")
  |> should.be_true
  codex.stop(session)
}

fn issue_json(state: String) -> String {
  "[{\"id\":\"1\",\"identifier\":\"T-1\",\"title\":\"Task\",\"state\":\""
  <> state
  <> "\",\"dispatchable\":true}]"
}

fn integration_workflow(
  root: String,
  command: String,
  prompt: String,
  extra_hooks: String,
) -> String {
  "---\ntracker:\n  kind: file\n  provider:\n    path: issues.json\n  active_states: [Todo]\n  terminal_states: [Done]\npolling:\n  interval_ms: 100\nworkspace:\n  root: "
  <> runtime.join(root, "workspaces")
  <> "\nhooks:\n  timeout_ms: 1000\n"
  <> extra_hooks
  <> "agent:\n  max_concurrent_agents: 1\n  max_turns: 1\ncodex:\n  command: "
  <> command
  <> "\n  read_timeout_ms: 1000\n  turn_timeout_ms: 1000\n  stall_timeout_ms: 5000\n---\n"
  <> prompt
  <> "\n"
}

fn wait_for_file(path: String, attempts: Int) -> Nil {
  case simplifile.exists(path, follow_links: False), attempts > 0 {
    Ok(True), _ -> Nil
    _, True -> {
      runtime.sleep(25)
      wait_for_file(path, attempts - 1)
    }
    _, False -> {
      let message = "timed out waiting for " <> path
      panic as message
    }
  }
}

fn wait_for_absence(path: String, attempts: Int) -> Nil {
  case simplifile.exists(path, follow_links: False), attempts > 0 {
    Ok(False), _ -> Nil
    _, True -> {
      runtime.sleep(25)
      wait_for_absence(path, attempts - 1)
    }
    _, False -> {
      let message = "timed out waiting for removal of " <> path
      panic as message
    }
  }
}

fn wait_for_lines(path: String, expected: Int, attempts: Int) -> String {
  let contents = simplifile.read(path) |> result.unwrap("")
  let lines =
    contents
    |> string.split("\n")
    |> list.filter(fn(line) { line != "" })
    |> list.length
  case lines >= expected, attempts > 0 {
    True, _ -> contents
    False, True -> {
      runtime.sleep(25)
      wait_for_lines(path, expected, attempts - 1)
    }
    False, False -> panic as "timed out waiting for prompt records"
  }
}

@external(erlang, "test_ffi", "putenv")
fn putenv(name: String, value: String) -> Nil

@external(erlang, "test_ffi", "unsetenv")
fn unsetenv(name: String) -> Nil

fn test_dir(name: String) -> String {
  runtime.join(
    runtime.temp_dir(),
    "symphony_gleam_" <> name <> "_" <> int.to_string(runtime.now_ms()),
  )
}
